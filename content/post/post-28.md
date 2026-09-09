---
title: "MySQL + StarRocks 多数据源架构：数据仓库配置管理"
slug: "post-28"
date: 2024-11-01T10:30:00+08:00
draft: false
image: /images/post-28-cover.jpg
tags: ["StarRocks","MySQL","数仓"]
categories: ["数据"]
description: "交易型 MySQL 与分析型 StarRocks 的多数据源分工与同步"
---

## 一个库装不下两种负载

数据治理服务同时背两类数据访问。一类是在线交易：文件上传、元数据 CRUD、质量规则配置、任务状态流转，要低延迟、强事务，这是 MySQL 的主场。另一类是分析查询：按机构统计论文数量、按年份聚合发文趋势、质量规则的大表扫描，千万到亿级行的聚合，MySQL 跑到几十秒就受不了。

我们的解法是引入 StarRocks 做分析型数仓，MySQL 继续存权威交易数据，组成多数据源架构。要回答的是三个问题：代码里怎么清晰地路由查询，数据怎么从 MySQL 同步到 StarRocks，配置怎么统一管。

## 两个库，各干各的

- MySQL：所有在线读写，权威库。GORM 访问，库表结构走 migration 版本化。
- StarRocks：只跑 OLAP 查询，表模型按分析场景设计（主键模型做明细、聚合模型做汇总）。应用端用标准 `database/sql` + MySQL 驱动，StarRocks 协议兼容 MySQL。
- 同步：SeaTunnel 做 MySQL → StarRocks 的批量同步，按 updated_at 增量拉；实时性要求高的表（比如质量结果）走 Canal 订阅 binlog 写 StarRocks。
- 配置管理：各环境的数据源连接信息放配置中心，启动时构建 `*gorm.DB` 和 `*sql.DB` 两个单例，DAO 按职责显式依赖其中一个。

有一点是刻意选择的：没有用动态数据源切面（根据方法名前缀自动选库）那种魔法。每个 DAO 明确声明自己用哪个库，代码读起来啰嗦一点，但可预测。

![MySQL 与 StarRocks 多数据源：显式 DAO 依赖与两条同步链路](/images/post-28-multidatasource.svg)

## 两个数据源，显式注入

数据源初始化：

```go
func NewMySQL(cfg Config) (*gorm.DB, error) {
    dsn := fmt.Sprintf("%s:%s@tcp(%s)/%s?charset=utf8mb4&parseTime=true&loc=Local",
        cfg.MySQL.User, cfg.MySQL.Password, cfg.MySQL.Addr, cfg.MySQL.DB)
    db, err := gorm.Open(mysql.Open(dsn), &gorm.Config{})
    if err != nil {
        return nil, err
    }
    sqlDB, _ := db.DB()
    sqlDB.SetMaxOpenConns(100)
    sqlDB.SetMaxIdleConns(20)
    return db, nil
}

func NewStarRocks(cfg Config) (*sql.DB, error) {
    dsn := fmt.Sprintf("%s:%s@tcp(%s)/%s?charset=utf8mb4&parseTime=true",
        cfg.StarRocks.User, cfg.StarRocks.Password,
        cfg.StarRocks.Addr, cfg.StarRocks.DB)
    db, err := sql.Open("mysql", dsn)
    if err != nil {
        return nil, err
    }
    db.SetMaxOpenConns(50)
    return db, nil
}
```

分析 DAO 直接用 `*sql.DB`：

```go
type PaperStatDAO struct {
    sr *sql.DB
}

func (d *PaperStatDAO) YearTrend(ctx context.Context, tenantID int64) ([]YearCount, error) {
    rows, err := d.sr.QueryContext(ctx, `
        SELECT publish_year, COUNT(*) AS cnt
        FROM dwd_paper
        WHERE tenant_id = ? AND publish_year IS NOT NULL
        GROUP BY publish_year
        ORDER BY publish_year`, tenantID)
    if err != nil {
        return nil, err
    }
    defer rows.Close()

    var out []YearCount
    for rows.Next() {
        var y int
        var c int64
        if err := rows.Scan(&y, &c); err != nil {
            return nil, err
        }
        out = append(out, YearCount{Year: y, Count: c})
    }
    return out, nil
}
```

SeaTunnel 同步任务片段（HOCON 配置）：

```hocon
source {
  MySQL-CDC {
    base-url = "jdbc:mysql://mysql:3306/dataservice"
    table-names = ["dataservice.file_objects", "dataservice.paper_meta"]
    username = "seatunnel"
    password = "${mysql_password}"
  }
}
sink {
  StarRocks {
    node-urls = ["starrocks-fe:8030"]
    base-url = "jdbc:mysql://starrocks-fe:9030"
    database = "dwh"
    table = "dwd_paper"
    username = "root"
    password = "${sr_password}"
  }
}
```

## 容易出的几类事故

- 别在 StarRocks 上做高频点查和单行更新。它是批量向量化引擎，高并发小查询性能反而不如 MySQL，主键模型的 Update 也是异步合并的，不适合交易场景，两类负载要严格分开。
- 同步有延迟，秒级到分钟级不等，产品和运营必须知道「StarRocks 的数据不是实时的」。我们在分析页面上显示「数据更新于 X 分钟前」，把话说在前面。
- StarRocks 兼容 MySQL 协议，但 SQL 方言有差异：不支持外键、部分函数不同、DDL 语法也不一样。GORM 的 AutoMigrate 不能直接用在 StarRocks 上，建表语句单独维护。
- 多数据源最容易出的事故，就是「在事务里查了 StarRocks」或者「把分析 SQL 打到 MySQL」。代码评审时我们重点看 DAO 注入的是哪个 db，另外把 StarRocks 账号设成只读，误写也写不进去。
- SeaTunnel 的 MySQL-CDC 依赖 binlog 格式为 ROW，账号还要有 REPLICATION 权限，这些得提前和 DBA 沟通好。

## 后来

MySQL + StarRocks 的组合，说白了就是让专业的引擎干专业的事：MySQL 扛交易，StarRocks 扛分析。这套架构里管用的就几件事：职责划分清楚，依赖显式注入，同步链路可靠，数据延迟也不藏着掖着。配置收口之后，新增一个分析查询就是写一个走 StarRocks DAO 的方法，和在线业务互不干扰。

> 封面图：[U.S. Army Corps of Engineers Savannah District / Flickr](https://www.flickr.com/photos/45417428@N05/9296682182) · CC BY 2.0
