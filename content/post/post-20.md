---
title: "腾讯云 SMS/SES/Captcha 多租户通道按需切换实践"
slug: "post-20"
date: 2024-06-29T10:30:00+08:00
draft: false
tags: ["腾讯云","SMS","多租户"]
categories: ["认证"]
description: "统一认证中心中腾讯云多通道按租户切换与配置隔离实践"
---

## 问题背景

统一认证中心服务多家客户和内部业务线，短信、邮件、验证码的通道配置各不相同。有的客户用自己的腾讯云账号（短信签名和模板要单独报备），有的用平台统一账号；国内走短信、海外走 SES 邮件；不同应用的验证码模板也不一样。如果所有租户共用一套腾讯云配置，签名和模板没法隔离，客户也无法使用自己报备的签名。我们需要在 Provider 抽象之上支持多租户通道：每个团队/应用可以配置自己的腾讯云 SecretId、SecretKey、SdkAppID、签名和模板，运行时按需切换。

## 方案设计

在前面 SMSProvider 抽象的基础上，我们引入了 ChannelConfig：每个 team_id + app_id + channel 组合对应一份通道配置，存在数据库里，包含供应商类型、加密后的凭证、模板 ID、签名等。发送时根据当前请求上下文查到对应配置，从缓存里拿到对应的 Provider 实例（没有就创建并缓存），用该实例发送。凭证用 AES-GCM 加密存储，主密钥从 KMS 或环境变量读取，明文不落盘。腾讯云 SDK 的 client 是并发安全的，我们按配置维度缓存复用，避免每次请求都创建。

## 关键代码

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

Provider 缓存用 sync.Map，key 是配置内容的 hash。配置变更时更新数据库并删除缓存 key，下次请求自动重建。没有自定义配置的租户回退到平台默认配置。Captcha 我们接了腾讯云验证码，前端先拿到 ticket，后端调用腾讯云接口校验通过后才允许发送验证码，形成人机验证加频率限制的双重防护。

## 踩坑与权衡

凭证加密是个重点。最初直接把 SecretKey 明文存数据库，安全评审被打回来，后来改成 AES-GCM 加密，主密钥通过环境变量注入 KubeSphere 的 Secret，代码里不硬编码。腾讯云 SMS 的模板参数是有序数组而不是 map，这个细节坑了一次——我们按 map 遍历传参，顺序不稳定导致验证码和过期时间填反了，后来改成按模板定义的参数顺序显式构造数组。另一个问题是腾讯云账号有频率限制，多租户共用默认账号时容易触发限流，我们给默认通道加了令牌桶限流和告警，量大的客户引导其使用自有账号。

## 小结

多租户通道按需切换让统一认证中心既支持平台统一配置快速接入，又支持客户自带腾讯云账号实现签名和凭证隔离。加密存储、Provider 缓存、默认回退、人机校验这几个机制组合在一起，在安全性和易用性之间取得了平衡，支撑了多业务线和外部客户的验证码与通知需求。
