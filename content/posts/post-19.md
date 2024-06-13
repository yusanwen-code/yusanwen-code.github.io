---
title: "可插拔 Provider 抽象：短信/邮件/验证码的配置化管理"
date: 2024-06-13T10:30:00+08:00
draft: false
tags: ["Provider","抽象","可扩展"]
categories: ["设计模式"]
description: "统一认证中心 中短信邮件验证码的可插拔 Provider 抽象与配置化"
---

## 问题背景

统一认证中心 作为认证中心，登录、注册、找回密码都要发验证码。初期我们只接了腾讯云 SMS，但很快需求就来了：国内用户用短信，海外用户用邮件，某些场景还要图形验证码防刷；运营还希望营销邮件和事务邮件走不同通道。如果把这些逻辑都写死在 Service 里，每加一个通道就要改业务代码、重新发布，而且不同通道的 API 差异很大，代码会变得非常臃肿。我们需要一层 Provider 抽象，让短信、邮件、验证码的发送变成可配置、可插拔的。

## 方案设计

我们定义了三个核心接口：SMSProvider、EmailProvider、CaptchaProvider，每个接口只有两三个方法。业务 Service 依赖接口而不是具体实现，具体用哪个 Provider 由配置决定。Provider 实例通过工厂方法创建，配置存在数据库里（支持按应用/团队覆盖），改动配置后通过配置中心热加载，不需要重启。验证码本身和发送通道解耦：统一认证中心 生成验证码存 Redis，然后调用注入的 Provider 发送，Provider 只负责"发"，不关心验证码生命周期。

## 关键代码

```go
type SMSProvider interface {
    Send(ctx context.Context, phone, tplID string, params map[string]string) error
    Name() string
}

type EmailProvider interface {
    Send(ctx context.Context, to, subject, body string) error
    Name() string
}

type ProviderFactory func(cfg map[string]string) (SMSProvider, error)

var smsProviders = map[string]ProviderFactory{}

func RegisterSMS(name string, f ProviderFactory) {
    smsProviders[name] = f
}

type VerifyService struct {
    sms   SMSProvider
    email EmailProvider
    rdb   *redis.Client
}

func (s *VerifyService) SendCode(ctx context.Context, channel, target string) error {
    code := genCode(6)
    key := fmt.Sprintf("verify:%s:%s", channel, target)
    if err := s.rdb.Set(ctx, key, code, 5*time.Minute).Err(); err != nil {
        return err
    }
    switch channel {
    case "sms":
        return s.sms.Send(ctx, target, "login_tpl",
            map[string]string{"code": code})
    case "email":
        return s.email.Send(ctx, target, "登录验证码",
            "您的验证码是 "+code)
    }
    return ErrUnsupportedChannel
}
```

腾讯云 SMS、SMTP 邮件等具体实现都在各自的包里用 init() 注册，Wire 注入时根据配置选择。我们还加了 Provider 级别的熔断和降级：短信通道失败时自动降级到邮件（如果用户绑定了邮箱），并记录指标用于告警。

## 踩坑与权衡

接口抽象的度要把握好。最初我们把 SMSProvider 定义得太细，连签名、模板管理都放进去了，结果不同供应商 API 差异导致接口很难统一。后来收敛成只留 Send 方法，模板和签名在供应商控制台配置，统一认证中心 只传 tplID 和参数。另一个坑是配置热加载：初期用指针替换 Provider 实例时有并发读写问题，后来用 atomic.Value 存储当前 Provider，切换时整体替换，读端无锁。还有验证码防刷，我们在 Provider 外面包了一层限流：同一手机号 60 秒内只能发一次，一天最多 10 次，防止接口被滥用。

## 小结

可插拔 Provider 抽象让 统一认证中心 的通知通道从硬编码变成了配置化，新增供应商只需实现接口并注册，业务代码零改动。这种"业务逻辑依赖接口、具体实现靠配置选择"的思路后来也用在了 知识库问答服务 的 LLM 适配层上——统一抽象 OpenAI、Azure、VLLM、HuggingFace 等多家供应商，本质是一样的设计模式。
