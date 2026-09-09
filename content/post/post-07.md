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

## 支付场景太散了

我在某科技公司主导统一支付平台。支付场景很散：有面向终端用户的充值、订阅付费，有面向机构客户的对公转账和批量打款，还有运营后台的手工调账、退款审批。要是把这些逻辑全塞进一个应用，权限边界会搅在一起，发版互相影响，接口粒度也没法统一。

我的做法是三端分离、共用一个支付内核：用户端、商户端、管理端各自独立部署，底层共用支付订单、状态机、渠道适配和对账能力。

![三端分离与统一支付内核](/images/post-07-pay-core.svg)

## 三端，一个内核

接入层用 Gin 起了三个独立服务，各自有自己的路由组和中间件链。用户端对接前端，OAuth2 登录，只有下单、查单、回调接收；商户端对接机构客户的系统，走 AppID/AppSecret 的 OpenAPI 签名认证，提供统一下单、退款、查询；管理端对接运营后台，RBAC 权限，审批、调账、对账导出都在这。

三端都不直接碰数据库，统一走 gRPC 调 payment-core。支付核心封装了订单状态机和支付渠道适配：

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

商户端的签名认证是独立中间件，除了验签还带防重放，5 分钟时间窗加 nonce 去重：

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

## 四个权衡

第一是接口粒度。结果发现三端要的东西完全不一样：用户端要聚合后的 DTO，订单里带商品名、状态文案；商户端要稳定精简的字段，OpenAPI 不能随便加字段；管理端要全量字段加筛选分页。我们没有让 payment-core 做接口裁剪，而是三端 API 层各自组装 DTO，core 只返回领域模型，别让核心服务被展示逻辑污染。

第二是回调幂等。支付渠道的回调可能重复投递。我们用 order_no 加 channel_trade_no 做唯一索引，重复回调直接返回成功，不重复触发流转。状态机自己还有一层防护：Paid 状态再收到 PaySuccess 是空操作，不会重复发货。

第三是对账。三端共用一个对账内核，每天凌晨拉渠道对账单跟本地订单比对，差异进差错池。导出用 Excelize 流式写入，机构客户一次能导几十万行，全量加载会 OOM。数据隔离在 DAO 层用 merchant_id 强制过滤，商户端只能导出自己名下的订单。

第四是计费规则。按次、包月、阶梯价、渠道费率，不同业务线算法不一样。我们把规则抽成 Rule 接口，配置驱动，新增业务线只加规则实现和配置，不用动下单主流程。

## 后来

三端分离拆的其实是"谁在用"和"怎么支付"这两件事：认证、权限、DTO 组装留在接入层，状态机一致性和渠道扩展性收在核心层。支付系统还有条底线：业务代码不许直接改订单状态，所有流转都过状态机校验。

> 封面图：[The City of Toronto / Flickr](https://www.flickr.com/photos/34608255@N08/10056440086) · CC BY 2.0
