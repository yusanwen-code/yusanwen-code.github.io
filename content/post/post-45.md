---
title: "GaussDB 与 MongoDB 在数据集服务中的选型与应用"
slug: "post-45"
date: 2025-07-24T10:30:00+08:00
draft: false
image: /images/post-45-cover.jpg
tags: ["GaussDB","MongoDB","选型"]
categories: ["数据库"]
description: "结构化元数据用 GaussDB，半结构化文档用 MongoDB，各司其职"
---

## 全塞 MySQL，两个问题都来了

数据集管理服务要管的东西很杂。一头是数据集本身，属性规整：所属团队、可见性、版本号、文件大小、创建时间、计费字段，全是结构化的。另一头是数据集下挂的文档解析结果，高度半结构化——不同来源的 PDF 抽出来的字段千差万别，有的带 DOI，有的带基金项目，有的带表格数据，schema 根本统一不了。

一开始我们图省事，全塞进 MySQL，解析结果用 JSON 列存。结果两个问题都来了：JSON 字段上的查询，要么扫表，要么得靠生成列建索引，写起来很别扭；解析任务又经常要回写嵌套很深的字段（比如某个 chunk 的 embedding 状态），行锁竞争明显。

于是我牵头做了一次存储选型。

## 两类数据，两个库

原则说白了就一条：让合适的数据库干合适的事。

GaussDB（华为系兼容 PostgreSQL 的关系库，客户侧有信创要求）存核心元数据：数据集、版本、文件、任务、团队配额、计费流水。这部分强一致、要事务、要复杂 JOIN，关系库是正解。

MongoDB 存文档解析结果和中间态：原始文本切片、chunk 元数据、抽取出来的实体和三元组、向量化任务的进度文档。schema 多变、写多读少、嵌套深，文档模型天然契合。

向量本身不进这两个库，走专用的向量库（Milvus 类），MongoDB 只存 chunk 到向量 ID 的映射。

![把数据按访问模式切给不同的存储](/images/post-45-storage-split.svg)

## 一边建外键，一边嵌文档

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

## 先说事务，再说三个坑

事务是我们第一个想清楚的点。MongoDB 4.0 以后支持多文档事务，但性能开销不小。跨库一致性我们没有追强一致：GaussDB 里的"数据集版本"是权威状态，MongoDB 里的解析进度只是附属状态。Mongo 写失败就靠 Temporal Worker 重试，最终一致即可，不值得为它引入分布式事务。

第一个坑是 GaussDB 的 PG 兼容性。绝大多数语法和 PG 14 一致，但某些扩展（比如 `pg_trgm`）客户环境里不一定装了。我们本来想在数据集名字上做模糊搜索，用 trigram 索引，最后改成把搜索字段同步到 ES，数据库只做精确过滤。

第二个坑是 MongoDB 的文档膨胀。Chunks 数组一直 append，单文档逼近 16MB 上限。后来把 chunk 拆成独立集合 `doc_chunks`，用 `doc_id` 关联，反而查询和并发更新都更顺。嵌套文档用着顺手，但会无限增长的数组要警惕。

第三个坑在连接池。Hertz 服务同时连两个库，初期 Mongo 池子开太大，连接数被打满。把 Mongo 的 `maxPoolSize` 压到 100，GaussDB 侧用 GORM 的 `SetMaxIdleConns/SetMaxOpenConns` 控制，再配合 KubeSphere 的资源限额，才稳下来。

## 后来

回头看，这两个库在这个服务里不是替代关系，是分工：强一致、要事务、要报表的核心元数据给 GaussDB；schema 多变、写多读少、嵌套深的解析中间态给 MongoDB。选型比的从来不是"哪个数据库更先进"，而是把数据按访问模式切开，让每一类数据落在它最舒服的存储里。

> 封面图：[Laenulfean / Flickr](https://www.flickr.com/photos/60359963@N00/5943132296) · CC BY-SA 2.0
