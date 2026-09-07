---
title: "动态计费引擎：复杂计费规则的配置化与计算实践"
slug: "post-10"
date: 2024-01-25T10:30:00+08:00
draft: false
image: /images/post-10-cover.jpg
tags: ["计费引擎", "规则引擎", "支付"]
categories: ["支付"]
description: "统一支付平台动态计费引擎从硬编码到配置化的演进"
---

## 每来一个新商户，就发一次版

统一支付平台对接的商户类型非常杂：按笔收固定手续费的、按金额走阶梯费率的、月封顶的，还有"新商户前三个月免费、之后 0.6%"这种带时间条件的。最早的版本是每来一个新商户就改一次代码、发一次版，运营在群里追着开发改费率。这么下去肯定不行。

我当时的目标很明确：运营在后台配规则，计费引擎按规则实时算出手续费，不改代码、不发版；同时计费结果要可追溯、可对账。

## 计费拆成三层

1. 计费维度（Dimension）：交易金额、笔数、商户等级、交易时间、渠道，从订单上下文里提取；
2. 规则（Rule）：一组条件加一种计费方式。条件支持 `AND/OR` 组合，计费方式支持固定费、比例费率、阶梯、封顶、包月；
3. 策略（Policy）：一个商户绑定一条或多条策略，策略按优先级命中第一条，或多条叠加。

规则存储我没用 DSL，而是用 JSON 结构化存储，运维友好且易于版本化：

```json
{
  "policy_id": "P_NEW_USER_3M",
  "priority": 100,
  "rules": [
    {
      "when": { "all": [
        { "field": "merchant.tags", "op": "contains", "value": "new" },
        { "field": "trade.created_at", "op": "before",
          "value": "merchant.joined_at + P3M" }
      ]},
      "then": { "type": "fixed", "amount": 0 }
    },
    {
      "when": { "all": [
        { "field": "trade.amount", "op": ">=", "value": 0 }
      ]},
      "then": { "type": "rate", "rate": "0.006",
                "min_fee": "0.01", "cap_monthly": "500.00" }
    }
  ]
}
```

![一条策略的求值过程：规则从上到下，命中即算](/images/post-10-policy-eval.svg)

## 求值器自己写

引擎入口是 `Calculator`：从订单上下文抽维度，策略按优先级排好，规则链依次求值，命中第一条就返回：

```go
type Dimension struct {
    MerchantID string
    Tags       []string
    JoinedAt   time.Time
    Amount     decimal.Decimal
    CreatedAt  time.Time
    Channel    string
}

type Calculator struct {
    policyRepo PolicyRepo
    capRepo    MonthlyCapRepo
}

func (c *Calculator) Fee(ctx context.Context, d Dimension) (decimal.Decimal, string, error) {
    policies, err := c.policyRepo.ListByMerchant(ctx, d.MerchantID)
    if err != nil {
        return decimal.Zero, "", err
    }
    sort.Slice(policies, func(i, j int) bool {
        return policies[i].Priority > policies[j].Priority
    })

    for _, p := range policies {
        for _, r := range p.Rules {
            if !match(r.When, d) {
                continue
            }
            fee, err := c.apply(ctx, r.Then, d)
            if err != nil {
                return decimal.Zero, "", err
            }
            return fee, p.PolicyID, nil
        }
    }
    return decimal.Zero, "", ErrNoPolicyMatched
}
```

`match` 我没有引表达式引擎，自己写了一个小型求值器，只支持有限的操作符：

```go
func match(node ConditionNode, d Dimension) bool {
    if len(node.All) > 0 {
        for _, n := range node.All {
            if !match(n, d) {
                return false
            }
        }
        return true
    }
    if len(node.Any) > 0 {
        for _, n := range node.Any {
            if match(n, d) {
                return true
            }
        }
        return false
    }
    actual := extract(d, node.Field)
    return compare(actual, node.Op, node.Value)
}
```

第一版其实考虑过直接上 Drools 或者 Go 生态里的表达式库，后来放弃了。一是团队得再学一门 DSL，二是表达式库出问题不好调试。自己这个求值器只有 200 多行，操作符能覆盖所有实际场景，出问题看日志一眼能定位。

阶梯费率和月封顶是两个相对复杂的计费方式：

```go
func (c *Calculator) apply(ctx context.Context, action Action, d Dimension) (decimal.Decimal, error) {
    switch action.Type {
    case "fixed":
        return decimal.NewFromFloat(action.Amount), nil
    case "rate":
        fee := d.Amount.Mul(action.Rate)
        if action.MinFee.GreaterThan(decimal.Zero) && fee.LessThan(action.MinFee) {
            fee = action.MinFee
        }
        if action.CapMonthly.GreaterThan(decimal.Zero) {
            used, _ := c.capRepo.MonthUsed(ctx, d.MerchantID, d.CreatedAt)
            remain := action.CapMonthly.Sub(used)
            if remain.LessThanOrEqual(decimal.Zero) {
                return decimal.Zero, nil
            }
            if fee.GreaterThan(remain) {
                fee = remain
            }
        }
        return fee, nil
    case "tiered":
        return applyTiered(action.Tiers, d.Amount), nil
    }
    return decimal.Zero, fmt.Errorf("unknown action type: %s", action.Type)
}
```

金额一律用 `shopspring/decimal`，绝不用 float64，这是做支付的底线。

## 三个坑

月封顶的并发问题真踩过。一笔订单算费时先读"本月已收"，再加当前 fee 写回 cap 表，两笔并发一撞就会超额。最后改成了 `INSERT ... ON DUPLICATE KEY UPDATE used = used + ?` 的原子更新，配合 `merchant_id + yyyymm` 唯一索引：先原子递增，再判断超没超额，超额部分回滚为 0。

第二个是阶梯计费的口径。是"全额落入某档"还是"分段累进"？两种业务都有，是跟运营反复确认才掰清楚的。我在 action 里加了 `tier_mode: "full" | "progressive"` 区分，不硬编码。

第三个是规则发布。每次运营改规则我都生成新版本号，订单上记录命中的 `policy_id + version`，对账时能精确还原"当时这笔订单是按哪条规则算的"。新规则先在白名单商户灰度 24 小时，再全量。

## 后来

这套引擎上线之后，新商户的费率配置从"排期等开发"变成运营后台自助，几分钟搞定。每笔手续费都带着规则版本，对账和客诉处理都轻松了不少。规则引擎这事，我的体会是不必追求大而全：能覆盖业务、能调试、能灰度，就够了。

> 封面图：[Ralf Steinberger / Flickr](https://www.flickr.com/photos/145472109@N04/32920934354) · CC BY 2.0
