---
title: "支付订单状态机设计：多类型订单的创建、支付与结算"
date: 2023-12-24T10:30:00+08:00
draft: false
tags: ["状态机", "订单系统", "DDD"]
categories: ["支付"]
description: "统一支付平台多类型订单状态机落地实践"
---

## 问题背景

刚接手 统一支付平台时，订单状态是用一堆 `if order.Status == "paid"` 散落各处的。三端（C 端用户、商户后台、运营后台）共用一张订单表，却有不同的业务诉求：C 端关心能不能退款，商户关心有没有到账，运营关心能不能手工调账。最痛的是，一次支付成功回调里同时更新了订单、账单、结算三张表，没有事务包裹，偶发回调重放导致状态错乱。

我当时的判断是：订单状态不能再由业务代码"随手赋值"，必须收敛成一个显式的状态机，把"哪些状态允许流转到哪些状态、流转时要做什么副作用"这两件事固化下来。

## 方案设计

我把 统一支付平台 的订单抽象成一个聚合根 `Order`，状态定义为枚举：

```
CREATED → PAYING → PAID → SETTLING → SETTLED
                 ↘ FAILED
PAID → REFUNDING → REFUNDED
任意非终态 → CLOSED
```

关键点有三个：

1. **状态与事件分离**。外部传入的不是"把状态改成 PAID"，而是一个领域事件 `PaySucceeded`，由聚合根自己决定能不能迁。
2. **副作用与状态变更同事务**。状态机触发的账户流水、账单生成、消息发送，要么在同一事务里落库，要么走 Outbox，不能裸调。
3. **多类型订单走同一套状态骨架**。充值、消费、退款订单复用同一张状态图，差异通过 `OrderType` 决定允许的事件子集和后置处理器。

## 关键代码

状态机的核心我写成了一张转移表，而不是 switch：

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

应用层只负责装载事件并调用 `Apply`，聚合根自己查表：

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

回调入口也变得很干净，幂等靠 `out_trade_no + event` 唯一键兜住：

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

## 踩坑与权衡

最早想引入一个成熟的 FSM 库，但看下来状态图并不复杂，引库反而让团队成员得先学 DSL，最后就用了一张表 + 一个方法，可读性更好。

有一个坑是**回调与主动查询的竞态**。微信回调延迟时，我们的定时补单任务会先把订单推到 PAID，回调再来就触发"illegal transition"。我在转移表里加了一条幂等规则：同态事件（PAID 收到 PAY_SUCCESS）直接返回 nil，而不是报错。

另一个权衡是结算状态是否独立成图。一度想把结算拆成单独的 `Settlement` 聚合，但业务上结算一定依附于某笔已支付订单，强一致比解耦更重要，就保留在订单状态机里，用 `SETTLING/SETTLED` 两个状态表达。

## 小结

订单状态机的价值不在代码多精巧，而在于把"业务规则"从散落在 service 层的 if 里收敛到一个看得见的地方。统一支付平台 后续接入退款、分账、跨境支付时，我们做的第一件事都是先在状态图上画新状态和新事件，再写代码，这套习惯帮团队少踩了很多状态错乱的坑。
