---
title: "支付订单状态机设计：多类型订单的创建、支付与结算"
slug: "post-08"
date: 2023-12-24T10:30:00+08:00
draft: false
image: /images/post-08-cover.jpg
tags: ["状态机", "订单系统", "DDD"]
categories: ["支付"]
description: "统一支付平台多类型订单状态机落地实践"
---

## 状态散落在 if 里

刚接手统一支付平台时，订单状态是用一堆 `if order.Status == "paid"` 散落在各处的。三端共用一张订单表，但各有各的关心点：C 端用户看能不能退款，商户看有没有到账，运营看能不能手工调账。

最痛的是，一次支付成功的回调同时更新了订单、账单、结算三张表，没有事务包裹，偶发的回调重放直接把状态搞乱了。

后来我想明白一件事：订单状态不能再由业务代码随手赋值，得收敛成一个显式的状态机，把两件事固化下来：哪些状态允许流转到哪些状态，流转时要做什么副作用。

## 一张转移表

我把订单抽象成聚合根 Order，状态用枚举：

```
CREATED → PAYING → PAID → SETTLING → SETTLED
                 ↘ FAILED
PAID → REFUNDING → REFUNDED
任意非终态 → CLOSED
```

三个关键点：外部传进来的是一个领域事件，比如 PaySucceeded，能不能迁由聚合根自己判断；状态机触发的副作用，账户流水、账单生成、消息发送，要么同事务落库，要么走 Outbox，不能裸调；充值、消费、退款多类型订单复用同一张状态图，差异靠 OrderType 决定允许的事件子集和后置处理器。

![订单状态机转移图](/images/post-08-state-machine.svg)

状态机核心我写成一张转移表，而不是一串 switch：

```go
type OrderStatus string
type OrderEvent string

const (
    StatusCreated  OrderStatus = "CREATED"
    StatusPaying   OrderStatus = "PAYING"
    StatusPaid     OrderStatus = "PAID"
    StatusFailed   OrderStatus = "FAILED"
    StatusSettling OrderStatus = "SETTLING"
    StatusSettled  OrderStatus = "SETTLED"
    StatusClosed   OrderStatus = "CLOSED"
    StatusRefunding OrderStatus = "REFUNDING"
    StatusRefunded OrderStatus = "REFUNDED"
)

type transition struct {
    From   OrderStatus
    Event  OrderEvent
    To     OrderStatus
    Hook   func(ctx context.Context, o *Order, tx *gorm.DB) error
}

var transitions = []transition{
    {StatusCreated, "PAY", StatusPaying, hookLockAmount},
    {StatusPaying, "PAY_SUCCESS", StatusPaid, hookRecordBill},
    {StatusPaying, "PAY_FAIL", StatusFailed, hookReleaseAmount},
    {StatusPaid, "SETTLE", StatusSettling, nil},
    {StatusSettling, "SETTLE_DONE", StatusSettled, hookNotifyMerchant},
    {StatusPaid, "REFUND", StatusRefunding, hookCreateRefundOrder},
    {StatusRefunding, "REFUND_DONE", StatusRefunded, hookReverseBill},
}
```

应用层只负责装载事件，调 Apply，聚合根自己查表：

```go
func (o *Order) Apply(ctx context.Context, ev OrderEvent, tx *gorm.DB) error {
    for _, t := range transitions {
        if t.From == o.Status && t.Event == ev {
            if t.Hook != nil {
                if err := t.Hook(ctx, o, tx); err != nil {
                    return err
                }
            }
            o.Status = t.To
            o.UpdatedAt = time.Now()
            return tx.Save(o).Error
        }
    }
    return fmt.Errorf("illegal transition: %s --%s-->", o.Status, ev)
}
```

回调入口因此变得很干净，幂等靠 out_trade_no 加 event 唯一键兜住：

```go
func (h *PayHandler) WxNotify(c *gin.Context) {
    var req WxPayNotify
    if err := c.ShouldBindJSON(&req); err != nil {
        c.String(400, "fail")
        return
    }
    err := h.db.Transaction(func(tx *gorm.DB) error {
        var o Order
        if err := tx.Where("out_trade_no = ?", req.OutTradeNo).First(&o).Error; err != nil {
            return err
        }
        if req.Result == "SUCCESS" {
            return o.Apply(c.Request.Context(), "PAY_SUCCESS", tx)
        }
        return o.Apply(c.Request.Context(), "PAY_FAIL", tx)
    })
    if err != nil {
        c.String(500, "fail")
        return
    }
    c.String(200, "success")
}
```

## 三个决定

最早想引一个成熟的 FSM 库。看下来状态图并不复杂，引库反而逼着团队先学一遍 DSL。最后就一张表加一个方法，可读性更好。

回调跟主动查询的竞态是个真坑。微信回调延迟时，我们的定时补单任务会先把订单推到 PAID，回调再进来就触发 illegal transition。解决办法是给转移表加一条幂等规则：同态事件直接返回 nil，不报错。PAID 再收到 PAY_SUCCESS，当没看见就行。

结算要不要独立成图，也犹豫过。一度想拆成单独的 Settlement 聚合，但业务上结算一定依附于某笔已支付订单，强一致比解耦重要，就留在订单状态机里，用 SETTLING 和 SETTLED 两个状态表达。

## 后来

状态机的价值，在于把业务规则从散落各处的 if 收敛到一个看得见的地方。后来接入退款、分账、跨境支付，我们都是先在状态图上画好新状态和新事件，再动手写代码，这套顺序帮团队躲开了不少状态错乱的坑。

> 封面图：[Kecko / Flickr](https://www.flickr.com/photos/70981241@N00/7632054886) · CC BY 2.0
