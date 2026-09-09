---
title: "腾讯云 SMS/SES/Captcha 多租户通道按需切换实践"
slug: "post-20"
date: 2024-06-29T10:30:00+08:00
draft: false
image: /images/post-20-cover.jpg
tags: ["腾讯云","SMS","多租户"]
categories: ["认证"]
description: "统一认证中心中腾讯云多通道按租户切换与配置隔离实践"
---

## 每家的通道配置都不一样

统一认证中心服务着多家客户和内部业务线：有的客户用自己报备的腾讯云账号，签名和模板都得单独申请；有的直接用平台统一账号。国内走短信，海外走 SES 邮件，不同应用的验证码模板也不一样。

所有租户挤在同一套腾讯云配置上，签名和模板就没法隔离，客户自己报备的签名也用不上。所以要在 Provider 抽象之上再加一层多租户通道，这件事没有绕开的余地。

## 一份配置对应一条通道

核心是一张 ChannelConfig 表：team_id + app_id + channel 三元组对应一份通道配置，存供应商类型、加密后的凭证、模板 ID、签名这些。发送时按请求上下文查到配置，从缓存里拿对应的 Provider 实例，没有就创建一个再缓存住，之后一直复用。

凭证安全是底线：AES-GCM 加密落库，主密钥从 KMS 或环境变量读取，明文不落盘。腾讯云 SDK 的 client 是并发安全的，按配置维度缓存复用就行，不必每个请求都新建。

![多租户通道：按 team/app/channel 切换](/images/post-20-tenant-channel.svg)

## 发一次短信背后的查找

```go
type ChannelConfig struct {
    ID        int64  `gorm:"primaryKey"`
    TeamID    int64  `gorm:"uniqueIndex:idx_ch"`
    AppID     string `gorm:"uniqueIndex:idx_ch"`
    Channel   string `gorm:"uniqueIndex:idx_ch"` // sms/email/captcha
    Provider  string `gorm:"size:32"`           // tencent_sms / tencent_ses
    ConfigEnc []byte // AES-GCM 加密的 JSON
    Status    int8
}

type TencentSMSProvider struct {
    client *sms.Client
    appID  string
    sign   string
}

func strPtr(s string) *string { return &s }

func (p *TencentSMSProvider) Send(ctx context.Context,
    phone, tplID string, params map[string]string) error {

    req := sms.NewSendSmsRequest()
    req.SmsSdkAppId = strPtr(p.appID)
    req.SignName = strPtr(p.sign)
    req.TemplateId = strPtr(tplID)
    req.PhoneNumberSet = []*string{strPtr(phone)}
    // 腾讯云模板参数为有序数组，需按模板顺序传
    arr := make([]*string, 0, len(params))
    for _, v := range params {
        arr = append(arr, strPtr(v))
    }
    req.TemplateParamSet = arr
    _, err := p.client.SendSms(ctx, req)
    return err
}
```

Provider 缓存用 sync.Map，key 取配置内容的 hash。配置变更时更新数据库、删掉对应缓存 key，下一个请求自动重建。没有自定义配置的租户，回退到平台默认配置。

验证码这条链路前面还加了一道人机校验：接了腾讯云验证码，前端先拿到 ticket，后端调用腾讯云接口校验通过，才允许发验证码。人机验证之外，还配了频率限制。

## 三个教训

第一个是凭证加密，这条没得商量。最初 SecretKey 明文存数据库，安全评审直接打回来。改成 AES-GCM 加密之后，主密钥通过环境变量注入 Secret，代码里不出现任何硬编码。

第二个坑藏在腾讯云 SMS 的模板参数里：它是有序数组，不是 map。我们按 map 遍历传参，顺序不稳定，结果验证码和过期时间填反了。后来改成按模板定义的参数顺序显式构造数组，才算踏实。

第三个是频率限制。多租户共用默认账号时容易触发腾讯云限流，我们给默认通道加了令牌桶限流和告警，量大的客户引导他们换用自有账号。

## 后来

多租户通道切换做完，认证中心两头都照顾到了：想快速接入的用平台统一配置；要隔离的客户自带腾讯云账号，签名、凭证完全独立。加密存储、Provider 缓存、默认回退、人机校验，几个机制组合在一起，安全性和易用性都站住了，支撑住了多业务线和外部客户的验证码与通知需求。

> 封面图：[Matthew Summerton / Wikimedia Commons](https://commons.wikimedia.org/w/index.php?curid=53726675) · CC BY-SA 3.0
