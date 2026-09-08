---
title: "MySQL 复杂查询优化：从 EXPLAIN 到索引重构"
slug: "post-53"
date: 2025-11-26T10:30:00+08:00
draft: false
image: /images/post-53-cover.jpg
tags: ["MySQL", "索引优化", "EXPLAIN"]
categories: ["数据库"]
description: "数据治理服务数据资产检索接口从 5 秒到百毫秒的优化过程"
---

## 一个 5 秒的检索接口

数据治理服务里有个数据资产检索页，支持按租户、数据集类型、更新时间区间、关键词多条件筛选。底表是几百万行的 `dataset` 表，还要 LEFT JOIN `owner` 表拿负责人名字。上线初期一个查询要 3 到 5 秒，ELK 里慢查询日志刷屏。我负责这次优化，目标定得比较克制：不改业务语义，把 P95 压到 500ms 以内。

## EXPLAIN 先说话

先跑 EXPLAIN 看执行计划，问题直接摆在脸上：`type=ALL` 的全表扫描，外加 `Using filesort`。几百万行先全扫一遍再排一次序，5 秒就是这么烧掉的。

我的思路分四块：为高频过滤条件建联合索引，让 WHERE 和 ORDER BY 走同一棵 B+Tree；`LIKE '%关键词%'` 这种模糊匹配 MySQL 帮不上忙，卸载给 ES；JOIN 只留必要的，被驱动表走主键；深翻页改成游标分页。

原始 GORM 查询长这样：

```go
func SearchDatasets(db *gorm.DB, tenantID uint, typ string, from, to time.Time) ([]Dataset, error) {
    var list []Dataset
    err := db.Table("dataset d").
        Select("d.*, o.name as owner_name").
        Joins("LEFT JOIN owner o ON o.id = d.owner_id").
        Where("d.tenant_id = ? AND d.type = ? AND d.updated_at BETWEEN ? AND ?",
            tenantID, typ, from, to).
        Order("d.updated_at DESC").
        Limit(20).Find(&list).Error
    return list, err
}
```

EXPLAIN 结果（简化）：

```
id  table  type   key    rows    Extra
1   d      ALL    NULL   820000  Using where; Using filesort
1   o      eq_ref PRIMARY 1
```

问题很清楚：dataset 表全表扫外加 filesort。加联合索引：

```sql
ALTER TABLE dataset
ADD INDEX idx_tenant_type_updated (tenant_id, type, updated_at);
```

优化后让 GORM 走这个索引：

```go
err := db.Table("dataset d FORCE INDEX (idx_tenant_type_updated)").
    Select("d.id, d.title, d.type, d.updated_at, d.owner_id, o.name as owner_name").
    Joins("LEFT JOIN owner o ON o.id = d.owner_id").
    Where("d.tenant_id = ? AND d.type = ? AND d.updated_at >= ? AND d.updated_at < ?",
        tenantID, typ, from, to).
    Order("d.updated_at DESC").
    Limit(20).Find(&list).Error
```

这里 FORCE INDEX 是有意的：统计信息不准的时候优化器会选错索引，干脆指定，不让它猜。

EXPLAIN 变成：

```
id  table  type   key                       rows   Extra
1   d      range  idx_tenant_type_updated   1200   Using index condition
1   o      eq_ref PRIMARY                   1
```

rows 从 820000 降到 1200，filesort 也消失了。

![一条查询怎么从全表扫描变成索引定位](/images/post-53-explain-index.svg)

## 六个坑

第一个要认的是最左前缀。联合索引 (tenant_id, type, updated_at) 必须 tenant_id 打头才用得上。如果业务里 type 会单独查而 tenant_id 不一定传，就得评估再建一个 (type, updated_at)，别指望一个索引通吃所有查询。

第二，范围列放最后。updated_at 用了 BETWEEN / >= 之后，排在它后面的索引列就没法再用于定位了。不过排序还能吃到这里，所以 ORDER BY 的方向要和索引一致。

第三，`LIKE '%xxx%'` 走不了 B+Tree，这个没得商量。我们把标题、摘要同步到 ES，MySQL 只承担结构化过滤。异构索引听着重，其实就是让两个引擎各干各擅长的。

第四，别 `SELECT *`。PDF 解析出来的大 content 字段单独放从表或对象存储，列表查询只取需要的列，回表开销小一大截。

第五，索引不是越多越好。dataset 写入频繁，每加一个索引，写放大就多一分。我们控制在 5 个以内，定期用 `pt-duplicate-key-checker` 清理冗余。

第六是深翻页。`LIMIT 100000, 20` 会老老实实扫完前 10 万行再扔掉，改成基于上一页最后一条的 `updated_at < ?` 游标分页，翻得再深，成本也不涨。

## 后来

回头看，EXPLAIN 是基本功，重点盯 `type`、`key`、`rows`、`Extra` 四列；索引设计要贴着真实的 WHERE 和 ORDER BY 来，不是凭感觉给每个字段撒一遍。模糊搜索交给 ES，MySQL 只干它最擅长的结构化查询——这套组合在数据治理服务里稳定扛住了日常的数据资产检索。

> 封面图：[David W. Siu / Flickr](https://www.flickr.com/photos/7400937@N07/5101688010) · CC BY 2.0
