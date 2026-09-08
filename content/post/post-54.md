---
title: "分库分表设计：支付与认证场景的水平拆分经验"
slug: "post-54"
date: 2025-12-12T10:30:00+08:00
draft: false
image: /images/post-54-cover.jpg
tags: ["分库分表", "水平拆分", "高并发"]
categories: ["数据库"]
description: "统一支付平台订单与统一认证中心登录日志的分片策略、路由与扩容经验"
---

## 单表数千万行之后

统一支付平台的订单表和统一认证中心的登录日志表，都长到了单表数千万行。订单查询开始吃紧，日志写入也开始吃紧。

这两张表气质完全不同。订单是按商户维度的高并发写入，登录日志是按用户和时间的海量追加写入。访问模式不同，分片策略就不能套同一个模板。

## 按商户切订单，按用户切日志

订单表按 `merchant_id` 哈希，16 库 × 8 表，一共 128 张。商户维度的查询——订单列表、对账——天然落在一个分片内。跨商户的后台统计走 MySQL 到 StarRocks 的离线同步，不做强一致跨片 JOIN。

登录日志按 `user_id` 分库、再按月份分表。「查某用户最近的登录」落在单片；按月归档清理直接处理整月表，两头都方便。

主键统一用 Snowflake。订单号里嵌入了商户分片位，解析订单号就能直接路由，不用二次查路由表。

![两种访问模式对应的分片与路由设计](/images/post-54-sharding-route.svg)

## 订单号里藏着路由

真实项目里我们用 GORM 的 sharding 插件加自研 Resolver，下面是核心路由逻辑的简化版：

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

## 坑一个一个说

第一个坑是分片键。一旦选错，代价极大。订单按 `merchant_id` 分片之后，C 端「查我的订单」会变成广播查询。我们的做法是订单再冗余一份按 `user_id` 分片到查询库（通过 Canal 同步），复杂检索直接走 ES。别指望一个分片键满足所有查询。

第二，跨片事务尽量避免。订单和账户余额落在同一商户分片内，本地事务就够；跨片的清结算用本地消息表保证最终一致，不上 XA。

第三，分库数量提前规划，但别过度。16 库是按未来几年容量估的，扩容用翻倍法（16→32），配合双写加数据校对平滑迁移。

第四，Snowflake 要防时钟回拨。NTP 同步打底，小幅回拨直接拒绝请求，宁可让调用方重试，也不能吐出重复 ID。

第五，跨片分页是噩梦。`LIMIT 100000,20` 会在每个分片都执行再归并，我们强制查询带时间范围和分片键，并限制深翻页。

第六，数据迁移必须能回滚。新流量双写新旧库，对账任务比对两边，一致后切读，最后停旧写。每一步都要退得回来。

## 后来

分库分表是「先苦后甜」，苦的不是中间件配置，是想清楚四件事：按什么维度分片、哪些查询必须落在单片、跨片查询去哪查、未来怎么扩容。统一支付平台和统一认证中心两个场景策略完全不同，本身就说明：分片没有银弹。

> 封面图：[mikecogh / Flickr](https://www.flickr.com/photos/89165847@N00/6068966667) · CC BY-SA 2.0
