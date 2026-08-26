---
title: "支付平台账单对账模块设计：多维度数据聚合与差异处理"
date: 2024-02-25T10:30:00+08:00
draft: false
tags: ["对账", "账单", "数据聚合"]
categories: ["支付"]
description: "统一支付平台对账模块多维聚合与差异自动处理"
---

## 问题背景

支付平台跑久了，账对不平是迟早的事。统一支付平台同时对接微信、支付宝、银联多个渠道，每天几十万笔交易，渠道回调可能丢、可能重放、可能金额被篡改、可能跨日清算。如果靠运营每天拉 Excel 肉眼比对，迟早出大事。

我在统一支付平台主导设计了一套对账模块，目标有三个：T+1 自动拉取渠道账单、多维度聚合比对、差异自动分类并产出处理工单。

## 方案设计

整个模块分成四层：

1. **数据采集层**：每天凌晨定时拉取各渠道对账文件（微信是 gz 压缩的 CSV、支付宝是 ZIP、银联是定长文本），统一解析成内部 `ChannelBill` 结构落库。
2. **数据聚合层**：把平台订单按"商户 + 渠道 + 日"维度聚合，算出订单笔数、订单金额、手续费、退款金额；同样把渠道账单按相同维度聚合。
3. **对账引擎层**：以渠道账单为基准，左连接平台订单，逐笔比对四个字段：订单号、金额、状态、时间。差异分为四类：长款（渠道有平台无）、短款（平台有渠道无）、金额不符、状态不符。
4. **差异处理层**：差异自动建单，能自动处理的（如跨日清算）自动核销，不能自动处理的推给运营工单系统，并附带原始凭证。

## 关键代码

聚合查询我用了一条 SQL 同时算出四个指标，避免来回扫表：

```sql
SELECT merchant_id, channel, trade_date,
       COUNT(*) AS order_count,
       SUM(amount) AS total_amount,
       SUM(fee) AS total_fee,
       SUM(refund_amount) AS total_refund
FROM orders
WHERE trade_date = ?
GROUP BY merchant_id, channel, trade_DATE
```

GORM 里我直接用 `Scan` 到结构体切片：

```go
type Aggregate struct {
    MerchantID  string
    Channel     string
    TradeDate   string
    OrderCount  int64
    TotalAmount decimal.Decimal
    TotalFee    decimal.Decimal
    TotalRefund decimal.Decimal
}

var platformAggs []Aggregate
db.WithContext(ctx).Raw(`
    SELECT merchant_id, channel, DATE(paid_at) AS trade_date,
           COUNT(*) AS order_count,
           SUM(amount) AS total_amount,
           SUM(fee) AS total_fee,
           COALESCE(SUM(refund_amount),0) AS total_refund
    FROM orders
    WHERE paid_at >= ? AND paid_at < ?
    GROUP BY merchant_id, channel, DATE(paid_at)
`, start, end).Scan(&platformAggs)
```

逐笔比对用 channel bill 左连 platform order，在内存里做（两边都按日期分片，单日数据量可控）：

```go
type DiffType string

const (
    DiffShort       DiffType = "SHORT"        // 平台有渠道无
    DiffLong        DiffType = "LONG"         // 渠道有平台无
    DiffAmount      DiffType = "AMOUNT_MISMATCH"
    DiffStatus      DiffType = "STATUS_MISMATCH"
)

type Diff struct {
    Type       DiffType
    OutTradeNo string
    Platform   *Order
    Channel    *ChannelBill
    Reason     string
}

func Reconcile(platform map[string]*Order, channel map[string]*ChannelBill) []Diff {
    var diffs []Diff
    seen := make(map[string]struct{}, len(platform))

    for no, cb := range channel {
        seen[no] = struct{}{}
        po, ok := platform[no]
        if !ok {
            diffs = append(diffs, Diff{Type: DiffLong, OutTradeNo: no, Channel: cb,
                Reason: "渠道存在订单但平台无记录"})
            continue
        }
        if !po.Amount.Equal(cb.Amount) {
            diffs = append(diffs, Diff{Type: DiffAmount, OutTradeNo: no,
                Platform: po, Channel: cb, Reason: "金额不一致"})
            continue
        }
        if po.Status == "PAID" && cb.Status == "REFUNDED" {
            diffs = append(diffs, Diff{Type: DiffStatus, OutTradeNo: no,
                Platform: po, Channel: cb, Reason: "平台未同步退款状态"})
        }
    }
    for no, po := range platform {
        if _, ok := seen[no]; !ok {
            diffs = append(diffs, Diff{Type: DiffShort, OutTradeNo: no, Platform: po,
                Reason: "平台存在订单但渠道无记录"})
        }
    }
    return diffs
}
```

差异处理策略用责任链模式，每条规则尝试自动核销：

```go
type Handler interface {
    Handle(ctx context.Context, diff Diff) (resolved bool, err error)
}

type CrossDayHandler struct{ next Handler }

func (h *CrossDayHandler) Handle(ctx context.Context, diff Diff) (bool, error) {
    if diff.Type != DiffShort || diff.Platform == nil {
        return h.next.Handle(ctx, diff)
    }
    // 短款可能是渠道 T+1 清算，查次日账单
    var cb ChannelBill
    err := db.WithContext(ctx).Where("out_trade_no = ? AND trade_date = ?",
        diff.OutTradeNo, diff.Platform.PaidAt.AddDate(0,0,1).Format("2006-01-02")).
        First(&cb).Error
    if err == nil && cb.Amount.Equal(diff.Platform.Amount) {
        return true, markResolved(ctx, diff, "跨日清算自动核销")
    }
    return h.next.Handle(ctx, diff)
}
```

## 踩坑与权衡

**时区是对账里最隐蔽的坑**。渠道账单的"交易日"通常用渠道侧时区（微信/支付宝都是北京时间），而我们数据库存 UTC。聚合时必须用 `CONVERT_TZ` 或在应用层明确按商户时区切日，否则一笔 23:50 的交易可能在平台算 T 日、渠道算 T+1 日，产生大量伪差异。

**金额比对一律用 decimal**，且比较前要做币种归一。曾经出过美元订单按人民币比对的低级错误，后来加了币种一致性校验。

**手续费差异**最复杂。渠道手续费是按渠道规则算的，我们按自己的计费引擎算，两边规则不同时差异必然存在。我们专门建了一张 `fee_adjustment` 表，把可接受的尾差（单笔 < 0.01 元）自动归到"手续费尾差"科目，不报警。

**差异重试与幂等**。对账任务可能因为渠道文件未就绪重跑，差异工单必须按 `(trade_date, out_trade_no, diff_type)` 做唯一索引，避免重复建单骚扰运营。

**聚合粒度的选择**。一度想做成按小时聚合，跑下来发现渠道账单本身就是按天的，按小时聚合反而徒增复杂度，最终定为天级，商户级对账单再下钻到明细。

## 小结

对账模块看起来不性感，却是支付平台的"良心"。统一支付平台这套设计上线后，每天自动出对账结果，差异自动分类、能自动核销的不打扰运营，不能自动的带着凭证进工单。账对得平，财务才睡得着；差异处理有迹可循，客诉来了也能快速定位是平台问题、渠道问题还是跨日问题。
