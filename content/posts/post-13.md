---
title: "从单体到账号中台：统一认证中心的架构思考"
date: 2024-03-11T10:30:00+08:00
draft: false
tags: ["认证", "账号中台", "架构"]
categories: ["架构"]
description: "某科技公司统一认证中心从 0 到 1 架构设计"
---

## 问题背景

2023 年底我刚到某科技公司时，公司内部几个业务系统各有各的登录：统一支付平台有一套账号，数据治理服务数据治理有一套，数据集管理服务和知识库问答服务又各搞一套。员工要记四五个密码，离职了账号关不干净；外部客户在一个系统注册完，跳到另一个系统还得再注册一次。运维和安全团队都在催"能不能统一一下"。

这就是统一认证中心的起点。但我清楚地知道，做账号中台不是简单把用户表抽出来，它要解决三件事：**身份的统一、认证方式的扩展、多应用之间的信任关系**。

## 方案设计

我把统一认证中心划分成几个核心域：

1. **身份域（Identity）**：全局唯一的 `UserID`（Snowflake 生成），一个用户可以绑定多种凭证（密码、手机、邮箱、微信/企微/飞书 OAuth）。
2. **应用域（Application）**：每个接入方有 `AppID/AppSecret`，配置回调地址、授权方式、可用的登录 Provider。
3. **组织域（Organization/Role）**：`AppRole` 实现团队/租户隔离，用户在不同应用里可以有不同角色，RBAC 权限模型落在统一认证中心，但资源权限由业务系统自己持有。
4. **会话域（Session）**：统一认证中心颁发 JWT（RSA 私钥签），业务系统用 JWKS 公钥本地验签，不回源。
5. **Provider 域**：短信、邮件、验证码、社交登录都做成可插拔接口，默认实现腾讯云 SMS/SES/Captcha，后续要换阿里或自建只需加实现。

技术栈上用 go-zero 拆 RPC 服务，Wire 做依赖注入，Service/DAO 分层。

## 关键代码

整体分层是这样组织的：

```
passport/
├── api/              # HTTP 网关 (go-zero rest)
│   ├── handler/
│   └── middleware/
├── rpc/              # gRPC 服务
│   ├── user/
│   ├── app/
│   ├── auth/
│   └── org/
├── internal/
│   ├── service/      # 业务编排
│   ├── dao/          # 数据访问
│   ├── provider/     # 可插拔 Provider
│   └── token/        # JWT 签发/JWKS
└── wire/
```

Provider 接口是可插拔的关键：

```go
type SMSProvider interface {
    Send(ctx context.Context, phone, tmplID string, params map[string]string) error
}

type EmailProvider interface {
    Send(ctx context.Context, to, subject, body string) error
}

type CaptchaProvider interface {
    Verify(ctx context.Context, ticket, randstr string) error
}
```

Wire 注入时按配置选择实现：

```go
func NewSMSProvider(cfg config.SMS) provider.SMSProvider {
    switch cfg.Provider {
    case "tencent":
        return tencent.NewSMS(cfg.Tencent)
    case "aliyun":
        return aliyun.NewSMS(cfg.Aliyun)
    default:
        return noop.NewSMS()
    }
}
```

登录入口用 `AuthService` 统一编排，无论密码、短信、社交登录都走同一套"凭证换 UserID → 发 Token"的流程：

```go
type AuthService struct {
    userDao   dao.UserDAO
    credDao   dao.CredentialDAO
    tokenSvc  *token.Service
    providers provider.Container
}

func (s *AuthService) Login(ctx context.Context, req *LoginRequest) (*TokenPair, error) {
    var userID int64
    var err error
    switch req.GrantType {
    case "password":
        userID, err = s.loginByPassword(ctx, req.AppID, req.Account, req.Password)
    case "sms":
        userID, err = s.loginBySMS(ctx, req.AppID, req.Phone, req.Code)
    case "social":
        userID, err = s.loginBySocial(ctx, req.AppID, req.Provider, req.Code)
    default:
        return nil, ErrUnsupportedGrantType
    }
    if err != nil {
        return nil, err
    }
    return s.tokenSvc.Issue(ctx, userID, req.AppID)
}
```

JWT 签发用 RSA 私钥，公钥通过 JWKS 端点暴露：

```go
func (s *Service) Issue(ctx context.Context, userID int64, appID string) (*TokenPair, error) {
    now := time.Now()
    claims := Claims{
        UserID: userID,
        AppID:  appID,
        RegisteredClaims: jwt.RegisteredClaims{
            Issuer:    "passport",
            Subject:   strconv.FormatInt(userID, 10),
            Audience:  jwt.ClaimStrings{appID},
            ExpiresAt: jwt.NewNumericDate(now.Add(2 * time.Hour)),
            IssuedAt:  jwt.NewNumericDate(now),
            ID:        snowflake.NextID(),
        },
    }
    accessToken, err := jwt.NewWithClaims(jwt.SigningMethodRS256, claims).
        SignedString(s.privKey)
    // refresh token 省略
    return &TokenPair{AccessToken: accessToken, ...}, nil
}
```

## 踩坑与权衡

**用户合并是账号中台最棘手的问题**。一个用户先用微信登录、后来又用手机号注册，如果识别为同一人需要合并。我设计了一张 `user_bindings` 表，凭证和用户是多对一关系，合并时把旧凭证挂到新 UserID 下，并写审计日志。但业务系统外键引用了旧 UserID，需要发事件通知各系统做 ID 映射，这件事比想象中复杂。

**JWT 吊销**是个老话题。我们用短 AccessToken（2 小时）+ 长 RefreshToken（7 天），RefreshToken 存 Redis 可吊销；AccessToken 不做黑名单，靠短过期自然失效。登出只吊销 RefreshToken，对安全性要求极高的场景（支付）配合"令牌版本号"claim，改密码时版本号递增。

**AppRole 与租户隔离**。一开始想把组织树建在统一认证中心，但业务系统的组织模型差异很大（统一支付平台是商户、数据治理服务是团队、知识库问答服务是企业），强行统一会削足适履。最终统一认证中心只存 `(app_id, user_id, role_external_id)`，具体的组织名和层级由业务系统维护。

**Provider 灰度**。腾讯云短信偶尔抖动，我在 Provider 层加了一个 `FanoutProvider`，按权重在多个供应商间分流，失败自动降级，配置中心热更新，不用重启。

## 小结

做账号中台的核心不是技术炫技，而是克制——只做"身份、认证、应用信任"这三件事，把组织、资源权限留给业务系统。统一认证中心上线后，新业务接入 SSO 只需要半天，离职员工账号在一个地方关掉就全端下线，安全审计也有了统一入口。对我来说，这套架构最大的价值是把"登录"这件每个系统都要重复做的事，真正做成了一个可复用的平台能力。
