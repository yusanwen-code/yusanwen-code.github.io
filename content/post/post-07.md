---
title: "支付平台三端分离架构设计：多场景统一支付的落地"
slug: "post-07"
date: 2023-12-09T10:30:00+08:00
draft: false
image: /images/post-07-cover.jpg
tags: ["支付","架构设计","Gin"]
categories: ["架构"]
description: "统一支付平台用户端、商户端、管理端三端分离与统一支付内核的设计实践"
---

## 问题背景

我在某科技公司主导统一支付平台时，面临的核心问题是：支付场景分散——有面向终端用户的充值/订阅付费，有面向机构客户的对公转账和批量打款，还有运营后台的手工调账和退款审批。如果把这些逻辑塞进一个应用，权限边界混乱、发版互相影响、接口粒度也很难统一。

我的做法是"三端分离，一个支付内核"：用户端、商户端、管理端各自独立部署，但底层共用支付订单、状态机、渠道适配和对账能力。

## 方案/设计

三端在接入层用 Gin 做了三个独立的 HTTP 服务，各自有独立的路由组和中间件链：

- 用户端（portal-api）：对接前端，走 OAuth2 登录，权限是普通用户，只有下单、查单、回调接收。
- 商户端（merchant-api）：对接机构客户系统，走 AppID/AppSecret 的 OpenAPI 签名认证，提供统一下单、退款、查询接口。
- 管理端（admin-api）：对接运营后台，走 RBAC 权限，有审批、调账、对账导出、渠道配置等管理能力。

三端不直接操作数据库，而是通过 gRPC 调用统一的 payment-core 服务。支付核心封装了订单状态机和支付渠道适配：

```go
type PaymentService struct {
    db       *gorm.DB
    channels map[string]Channel // channelCode -> adapter
    engine   *billing.Engine     // 动态计费引擎
}

type Channel interface {
    CreateOrder(ctx context.Context, order *Order) (payURL string, err error)
    QueryOrder(ctx context.Context, orderNo string) (*ChannelOrder, error)
    Refund(ctx context.Context, orderNo string, amount int64) error
    ParseCallback(req *http.Request) (*CallbackResult, error)
}

// 统一下单入口，三端最终都走到这里
func (s *PaymentService) CreateOrder(ctx context.Context, req *CreateOrderReq) (*Order, error) {
    // 1. 计费引擎算出应付金额
    amount, err := s.engine.Calculate(ctx, req.BizCode, req.Params)
    if err != nil {
        return nil, err
    }

    order := &Order{
        OrderNo:   snowflake.New().NextID().String(),
        BizCode:   req.BizCode,
        BizID:     req.BizID,
        PayerID:   req.PayerID,
        Amount:    amount,
        Status:    OrderStatusPending,
        Channel:   req.ChannelCode,
        CreatedAt: time.Now(),
    }

    // 2. 落库
    if err := s.db.Create(order).Error; err != nil {
        return nil, err
    }

    // 3. 调起对应渠道
    ch, ok := s.channels[req.ChannelCode]
    if !ok {
        return nil, ErrChannelNotSupported
    }
    payURL, err := ch.CreateOrder(ctx, order)
    if err != nil {
        order.Status = OrderStatusFailed
        s.db.Model(order).Update("status", OrderStatusFailed)
        return nil, err
    }
    order.PayURL = payURL
    return order, nil
}
```

订单状态机是支付系统的核心，所有状态流转必须走显式的事件，不能直接 update status：

```go
var transitions = map[OrderStatus][]OrderEvent{
    OrderStatusPending:   {EventPaySuccess, EventPayFailed, EventCancel},
    OrderStatusPaid:      {EventRefundApply, EventClose},
    OrderStatusRefunding: {EventRefundSuccess, EventRefundFailed},
    OrderStatusClosed:    {},
    OrderStatusFailed:    {EventRetry},
}

func (s *PaymentService) Transit(ctx context.Context, orderNo string, event OrderEvent) error {
    return s.db.Transaction(func(tx *gorm.DB) error {
        var order Order
        if err := tx.Where("order_no = ?", orderNo).First(&order).Error; err != nil {
            return err
        }
        allowed := transitions[order.Status]
        if !containsEvent(allowed, event) {
            return fmt.Errorf("invalid transition %s --%s-->", order.Status, event)
        }
        next := nextStatus(order.Status, event)
        return tx.Model(&order).Updates(map[string]interface{}{
            "status":     next,
            "updated_at": time.Now(),
        }).Error
    })
}
```

商户端的 OpenAPI 签名认证是独立中间件，用 AppID 查到 AppSecret 后做 RSA/SHA 验签：

```go
func MerchantSignAuth(redis *redis.Client, merchantSvc MerchantService) gin.HandlerFunc {
    return func(c *gin.Context) {
        appID := c.GetHeader("X-App-Id")
        sign := c.GetHeader("X-Sign")
        timestamp := c.GetHeader("X-Timestamp")
        nonce := c.GetHeader("X-Nonce")

        if appID == "" || sign == "" {
            c.AbortWithStatusJSON(401, gin.H{"msg": "missing auth headers"})
            return
        }
        // 防重放：5 分钟时间窗 + nonce 去重
        if math.Abs(float64(time.Now().Unix()-toInt64(timestamp))) > 300 {
            c.AbortWithStatusJSON(401, gin.H{"msg": "timestamp expired"})
            return
        }
        if ok, _ := redis.SetNX(c, "nonce:"+nonce, 1, 5*time.Minute).Result(); !ok {
            c.AbortWithStatusJSON(401, gin.H{"msg": "replayed request"})
            return
        }

        secret, err := merchantSvc.GetAppSecret(c, appID)
        if err != nil {
            c.AbortWithStatusJSON(401, gin.H{"msg": "invalid app"})
            return
        }
        // 按 method + path + timestamp + nonce + body 拼接待签名字符串
        signStr := buildSignString(c, timestamp, nonce)
        if err := rsa.Verify(secret.PublicKey, []byte(signStr), sign); err != nil {
            c.AbortWithStatusJSON(401, gin.H{"msg": "sign verify failed"})
            return
        }
        c.Set("merchant_id", secret.MerchantID)
        c.Next()
    }
}
```

## 踩坑/权衡

第一是三端的接口粒度差异。用户端要的是聚合后的 DTO（订单里带商品名、状态文案），商户端要的是稳定精简的字段（OpenAPI 不能随便加字段），管理端要的是全量字段加筛选分页。我们没有在 payment-core 里做接口裁剪，而是在三端 API 层各自组装 DTO，core 只返回领域模型，避免核心服务被展示逻辑污染。

第二是回调的幂等。支付渠道的回调可能重复投递，我们在接收回调时用 `order_no + channel_trade_no` 做唯一索引，重复回调直接返回成功，不重复触发状态流转。状态机本身也有防护：Paid 状态再收到 PaySuccess 事件是空操作，不会重复发货。

第三是对账能力。三端共用一个对账内核，每天凌晨拉取渠道对账单与本地订单比对，差异进差错池。导出用了 Excelize 流式写入，因为机构客户一次可能导出几十万行，全量加载会 OOM。管理端运营可以直接在后台发起导出，商户端只能导出自己名下的订单，数据隔离在 DAO 层通过 merchant_id 强制过滤。

第四是计费引擎的灵活性。不同业务线的计费规则不同（按次、包月、阶梯价、渠道费率），我们把规则抽象成 `Rule` 接口，用配置驱动而非硬编码，新增业务线只加规则实现和配置，不用改下单主流程。

## 小结

三端分离的本质不是物理上拆三个服务，而是把"谁在用"和"怎么支付"解耦：接入层处理认证、权限、DTO 组装，核心层保证订单状态机的一致性和支付渠道的可扩展性。支付系统最忌讳的是在业务代码里直接改订单状态，所有流转必须经过状态机校验，这是资金安全的底线。

> 封面图：[The City of Toronto / Flickr](https://www.flickr.com/photos/34608255@N08/10056440086) · CC BY 2.0
