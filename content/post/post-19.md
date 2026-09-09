---
title: "可插拔 Provider 抽象：短信/邮件/验证码的配置化管理"
slug: "post-19"
date: 2024-06-13T10:30:00+08:00
draft: false
image: /images/post-19-cover.jpg
tags: ["Provider","抽象","可扩展"]
categories: ["设计模式"]
description: "统一认证中心中短信邮件验证码的可插拔 Provider 抽象与配置化"
---

## 通道越接越多

认证中心离不开发验证码：登录、注册、找回密码，都要发。初期只接了腾讯云 SMS，很快需求就排着队来了：国内用户走短信，海外用户得走邮件；有些场景要上图形验证码防刷；运营还提出营销邮件和事务邮件要分开走通道。

要是把这些逻辑都写死在 Service 里，每加一个通道就得改业务代码、重新发布。何况各家供应商的 API 差异很大，代码只会越堆越臃肿。我们需要一层 Provider 抽象，让短信、邮件、验证码的发送变成可配置、可插拔的。

## 业务依赖接口，实现靠配置选

接口只有三个：SMSProvider、EmailProvider、CaptchaProvider，每个就两三个方法。业务 Service 只依赖接口，具体用哪家由配置决定。Provider 实例通过工厂方法创建，配置存数据库，支持按应用/团队覆盖；配置改了走配置中心热加载，不需要重启。

验证码本身和发送通道是解耦的：认证中心生成验证码、存 Redis，然后调用注入进来的 Provider 发出去。Provider 只负责「发」，验证码的生命周期它一概不关心。

![验证码发送：Provider 抽象与配置化](/images/post-19-provider-abstract.svg)

## 注册、注入，外加熔断降级

各家的具体实现都收在自己的包里，用 init() 注册进工厂：

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

腾讯云 SMS、SMTP 邮件这些实现，都在各自的包里 init() 注册，Wire 注入时按配置选择。Provider 这一层还加了熔断和降级：短信通道失败时自动降级到邮件（前提是用户绑过邮箱），并记录指标用于告警。

## 踩下来的三个坑

第一个是接口抽象的度。最初把 SMSProvider 定义得太细，连签名、模板管理都想塞进去，结果不同供应商 API 差异太大，接口根本统一不起来。后来收敛到只留一个 Send，模板和签名放到供应商控制台配，认证中心只传 tplID 和参数。

第二个是配置热加载。初期直接替换 Provider 指针，读端可能正读着一半，并发读写就出问题了。后来改用 atomic.Value 存当前 Provider，切换时整体替换，读端无锁，问题解决。

第三个是防刷。Provider 外面包了一层限流：同一手机号 60 秒内只能发一次，一天最多 10 条，防止发送接口被人滥用。

## 后来

这套抽象做完，通知通道从硬编码变成了配置：新增一家供应商，实现接口、注册进工厂，业务代码零改动。

同一套思路后来也用在了知识库问答服务的 LLM 适配层上：统一抽象 OpenAI、Azure、VLLM、HuggingFace 这些供应商，业务逻辑依赖接口、具体实现靠配置选择，其实就是同一个设计模式。

> 封面图：[espensorvik / Flickr](https://www.flickr.com/photos/28478778@N05/5729002702) · CC BY 2.0
