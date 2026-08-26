---
title: "分库分表设计：支付与认证场景的水平拆分经验"
date: 2025-12-12T10:30:00+08:00
draft: false
tags: ["分库分表", "水平拆分", "高并发"]
categories: ["数据库"]
description: "统一支付平台订单与统一认证中心登录日志的分片策略、路由与扩容经验"
---

## 问题背景

统一支付平台的订单表和统一认证中心的登录日志表都增长到了单表数千万行，订单查询和日志写入开始吃紧。订单是典型的按商户维度的高并发写入，登录日志是按用户和时间维度的海量追加写入。两个场景的访问模式完全不同，分片策略也必须分别设计，不能套同一个模板。

## 方案设计

订单表按 `merchant_id` 哈希分成 16 库 × 8 表，共 128 张表。商户维度的查询（订单列表、对账）天然落在一个分片内；跨商户的后台统计走 MySQL 到 StarRocks 的离线同步，不做强一致跨片 JOIN。登录日志按 `user_id` 分库、再按月份分表，这样"查某用户最近登录"和"按月归档清理"都很方便。主键统一用 Snowflake，业务订单号里嵌入商户分片位，解析订单号即可路由，避免二次查路由表。

## 关键代码

订单路由（真实项目里我们用 GORM 的 sharding 插件和自研 Resolver，下面是核心路由逻辑的简化版）：

```go
const (
    dbCount    = 16
    tableCount = 8
)

func OrderShard(merchantID int64) (db, table int) {
    db = int(merchantID % dbCount)
    table = int(merchantID / dbCount % tableCount)
    return
}

type Order struct {
    ID         int64     `gorm:"primaryKey"`
    OrderNo    string    `gorm:"size:32;uniqueIndex"`
    MerchantID int64     `gorm:"index"`
    Amount     int64
    Status     int
    CreatedAt  time.Time
}

func (o *Order) TableName() string {
    _, t := OrderShard(o.MerchantID)
    return fmt.Sprintf("order_%02d", t)
}
```

订单号里嵌入分片位，业务侧解析即可路由：

```go
// 订单号 = 13位毫秒时间戳 + 3位商户分片位 + 5位序列号
func GenOrderNo(merchantID, seq int64) string {
    return fmt.Sprintf("%d%03d%05d",
        time.Now().UnixMilli(), merchantID%1000, seq%100000)
}

func RouteOrderNo(orderNo string) (db, table int) {
    if len(orderNo) < 16 {
        return 0, 0
    }
    bucket, _ := strconv.ParseInt(orderNo[13:16], 10, 64)
    db = int(bucket % dbCount)
    table = int(bucket / dbCount % tableCount)
    return
}
```

登录日志按月分表：

```go
func LoginLogTable(ts time.Time) string {
    return "login_log_" + ts.Format("200601")
}
```

## 踩坑与权衡

第一，分片键一旦选错，代价极大。订单按 `merchant_id` 分片后，C 端"查我的订单"会变成广播查询。我们的做法是订单再冗余一份按 `user_id` 分片到查询库（通过 Canal 同步），复杂检索直接走 ES，不要指望一个分片键满足所有查询。第二，跨片事务尽量避免。统一支付平台订单和账户余额在同一商户分片内，本地事务即可；跨片的清结算用本地消息表保证最终一致，而不是 XA。第三，分库数量要提前规划但不要过度，16 库是按未来几年容量估的，扩容用翻倍法（16→32），配合双写加数据校对平滑迁移。第四，Snowflake 要防时钟回拨，我们在 NTP 同步基础上对小幅回拨直接拒绝请求，避免重复 ID。第五，跨片分页是噩梦，`LIMIT 100000,20` 会在每个分片都执行再归并，我们强制要求带时间范围和分片键，并限制深翻页。第六，数据迁移必须能回滚，新流量双写新旧库，对账任务比对两边数据，一致后切读，最后停旧写。

## 小结

分库分表是"先苦后甜"，核心不是中间件配置，而是想清楚四件事：按什么维度分片、哪些查询必须落在单片、跨片查询去哪查、未来怎么扩容。统一支付平台和统一认证中心两个场景策略完全不同，本身就说明分片没有银弹。
