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

## 问题背景

数据治理服务里有一个数据资产检索页，支持按租户、数据集类型、更新时间区间、关键词多条件筛选，底表是几百万行的 `dataset` 表，还 LEFT JOIN 了 `owner` 表。上线初期一个查询要 3 到 5 秒，ELK 里慢查询日志刷屏。我负责这次优化，目标是在不改业务语义的前提下把 P95 压到 500ms 以内。

## 方案设计

先用 EXPLAIN 看执行计划，定位 `type=ALL` 的全表扫描和 `Using filesort`。核心思路是：为高频过滤条件建联合索引，让 WHERE 和 ORDER BY 走同一棵 B+Tree；把 `LIKE '%关键词%'` 这种模糊匹配卸载到 ES；只在必要时 JOIN，且被驱动表走主键；深翻页改成游标分页。

## 关键代码

原始 GORM 查询：

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

EXPLAIN 变成：

```
id  table  type   key                       rows   Extra
1   d      range  idx_tenant_type_updated   1200   Using index condition
1   o      eq_ref PRIMARY                   1
```

## 踩坑与权衡

第一，联合索引遵循最左前缀。如果业务里 `type` 会单独查而 `tenant_id` 不一定传，就要评估是否再建一个 `(type, updated_at)`，别指望一个索引通吃所有查询。第二，范围列要放联合索引最后，`updated_at` 用了 `BETWEEN`/`>=` 之后，它后面的索引列就无法再用于定位，但排序仍能利用它，所以排序方向要和索引一致。第三，`LIKE '%xxx%'` 走不了 B+Tree 索引，我们把标题、摘要同步到 ES，MySQL 只承担结构化过滤，这是典型的异构索引思路。第四，不要 `SELECT *`，PDF 解析出的大 content 字段单独放从表或对象存储，列表查询只取需要的列，能显著减小回表开销。第五，索引不是越多越好，dataset 写入频繁，我们把索引数控制在 5 个以内，并定期用 `pt-duplicate-key-checker` 清理冗余索引。第六，`LIMIT 100000, 20` 会扫描前 10 万行，我们改成基于上一页最后一条的 `updated_at < ?` 游标分页。

## 小结

EXPLAIN 是基本功，重点看 `type`、`key`、`rows`、`Extra` 四列；索引设计要匹配真实的 WHERE 和 ORDER BY，而不是凭感觉给每个字段都加索引。把模糊搜索卸载到 ES、让 MySQL 干它最擅长的结构化查询，这个组合在数据治理服务里稳定扛住了日常数据资产检索。

> 封面图：[David W. Siu / Flickr](https://www.flickr.com/photos/7400937@N07/5101688010) · CC BY 2.0
