---
title: "GaussDB 与 MongoDB 在数据集服务中的选型与应用"
date: 2025-07-24T10:30:00+08:00
draft: false
tags: ["GaussDB","MongoDB","选型"]
categories: ["数据库"]
description: "结构化元数据用 GaussDB，半结构化文档用 MongoDB，各司其职"
---

## 问题背景

数据集管理服务要管的东西很杂：数据集本身有严格的结构化属性（所属团队、可见性、版本号、文件大小、创建时间、计费字段），而一个数据集下挂的文档解析结果又是高度半结构化的——不同来源的 PDF 抽出来的字段千差万别，有的带 DOI，有的带基金项目，有的带表格数据，schema 根本统一不了。

一开始我们图简单，全塞进 MySQL，文档解析结果用 JSON 列存。结果两个问题：一是 JSON 字段上的查询要么扫表，要么得靠生成列建索引，写起来很别扭；二是解析任务经常要回写嵌套很深的字段（比如某个 chunk 的 embedding 状态），行锁竞争明显。于是我牵头做了一次存储选型。

## 方案设计

原则是"让合适的数据库干合适的事"：

- **GaussDB**（华为系兼容 PostgreSQL 的关系库，客户侧信创要求）存核心元数据：数据集、版本、文件、任务、团队配额、计费流水。这部分强一致、要事务、要复杂 JOIN，关系库是正解。
- **MongoDB** 存文档解析结果和中间态：原始文本切片、chunk 元数据、抽取出来的实体/三元组、向量化任务的进度文档。这些数据 schema 多变、写多读少、嵌套深，文档模型天然契合。
- 向量本身不放在这两个库里，而是走专用的向量库（Milvus 类），MongoDB 只存 chunk 到向量 ID 的映射。

## 关键代码

GORM 接 GaussDB 走的是 PostgreSQL 驱动，DSN 和 PG 几乎一致：

```go
import "gorm.io/driver/postgres"

dsn := "host=gaussdb.internal user=dataset password=*** port=5432 " +
       "dbname=dataset sslmode=disable TimeZone=Asia/Shanghai"
db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{
    Logger: logger.Default.LogMode(logger.Warn),
})
```

核心元数据模型严格建外键和唯一索引：

```go
type Dataset struct {
    ID          int64     `gorm:"primaryKey;autoIncrement:false"` // Snowflake
    TeamID      int64     `gorm:"not null;index:idx_team"`
    Name        string    `gorm:"size:128;not null"`
    Visibility  string    `gorm:"size:16;not null"` // private/team/public
    CurrentVer  int       `gorm:"not null;default:1"`
    Status      string    `gorm:"size:16;not null"`
    CreatedAt   time.Time
    UpdatedAt   time.Time
}

type DatasetVersion struct {
    ID        int64  `gorm:"primaryKey;autoIncrement:false"`
    DatasetID int64  `gorm:"uniqueIndex:idx_ds_ver"`
    Version   int    `gorm:"uniqueIndex:idx_ds_ver"`
    Manifest  string `gorm:"type:jsonb"` // 文件清单
    Comment   string `gorm:"size:512"`
}
```

新建数据集和版本是一个事务，保证不会出现"有数据集没版本"的中间态：

```go
err := db.Transaction(func(tx *gorm.DB) error {
    if err := tx.Create(&ds).Error; err != nil { return err }
    ver := DatasetVersion{DatasetID: ds.ID, Version: 1, Manifest: manifest}
    return tx.Create(&ver).Error
})
```

MongoDB 侧用官方驱动，文档结构按"一个源文档一个 Document"组织：

```go
type ParsedDoc struct {
    ID         primitive.ObjectID `bson:"_id,omitempty"`
    DatasetID  int64              `bson:"dataset_id"`
    FileKey    string             `bson:"file_key"`
    Chunks     []Chunk            `bson:"chunks"`
    Entities   []EntitySnapshot   `bson:"entities,omitempty"`
    Extras     bson.M             `bson:"extras,omitempty"` // 来源相关的杂项字段
    ParseState string             `bson:"parse_state"`
    UpdatedAt  time.Time          `bson:"updated_at"`
}

type Chunk struct {
    Ordinal int    `bson:"ordinal"`
    Text    string `bson:"text"`
    VecID   string `bson:"vec_id,omitempty"`
    Status  string `bson:"status"` // pending/vectorized/failed
}
```

更新某个 chunk 的向量化状态不需要拉回整文档，用位置运算符：

```go
filter := bson.M{
    "_id":            docID,
    "chunks.ordinal": ord,
}
update := bson.M{
    "$set": bson.M{
        "chunks.$.status": "vectorized",
        "chunks.$.vec_id": vecID,
        "updated_at":      time.Now(),
    },
}
_, err := coll.UpdateOne(ctx, filter, update)
```

## 踩坑与权衡

第一个权衡是事务。MongoDB 4.0 以后支持多文档事务，但性能开销不小。我们在跨库一致性上没有追求强一致：GaussDB 里的"数据集版本"作为权威状态，MongoDB 里的解析进度是附属状态。如果 Mongo 写入失败，靠 Temporal Worker 重试，最终一致即可，不为了强一致引入分布式事务。

第二个坑是 GaussDB 的 PG 兼容性。绝大多数语法和 PG 14 一致，但某些扩展（比如 `pg_trgm`）在客户环境里不一定装了。我们原本想在数据集名字上做模糊搜索用 trigram 索引，最后改成把搜索字段同步到 ES，数据库只做精确过滤。

第三个坑是 MongoDB 的文档膨胀。Chunks 数组一直 append，单文档逼近 16MB 上限。我们后来把 chunk 拆成独立集合 `doc_chunks`，通过 `doc_id` 关联，反而查询和并发更新都更顺。嵌套文档用着顺手，但要警惕无限增长的数组。

第四个是连接池配置。Hertz 服务同时连两个库，初期 Mongo 池子开太大，把连接数打满。我们把 Mongo 的 `maxPoolSize` 压到 100，GaussDB 侧用 GORM 的 `SetMaxIdleConns/SetMaxOpenConns` 控制，配合 KubeSphere 的资源限额，稳定下来。

## 小结

GaussDB 和 MongoDB 在数据集管理服务里不是替代关系，而是分工。强一致、要事务、要报表的核心元数据走 GaussDB；schema 多变、写多读少、嵌套深的解析中间态走 MongoDB。选型的关键不是"哪个数据库更先进"，而是把数据按访问模式切开，让每一类数据都落在它最舒服的存储里。
