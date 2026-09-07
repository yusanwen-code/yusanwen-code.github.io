---
title: "从单体到账号中台：统一认证中心的架构思考"
slug: "post-13"
date: 2024-03-11T10:30:00+08:00
draft: false
image: /images/post-13-cover.jpg
tags: ["认证", "账号中台", "架构"]
categories: ["架构"]
description: "某科技公司统一认证中心从 0 到 1 架构设计"
---

## 四个系统，四套登录

2023 年底我刚到某科技公司时，内部几个业务系统各有各的登录：统一支付平台一套账号，数据治理服务一套，数据集管理服务和知识库问答服务又各搞一套。员工要记四五个密码，离职了账号还关不干净；外部客户在一个系统注册完，跳到另一个系统还得再注册一次。运维和安全团队都在催：能不能统一一下。

这就是统一认证中心的起点。但很快想明白一件事：它不是把用户表抽出来那么简单，真正要解决的是身份怎么统一、认证方式怎么扩展、应用之间怎么建立信任这三件事。

## 核心域怎么划

我把统一认证中心划成五个域：

1. 身份域：全局唯一的 `UserID`（Snowflake 生成），一个用户可以绑定多种凭证，密码、手机、邮箱、微信/企微/飞书 OAuth 都行。
2. 应用域：每个接入方有自己的 `AppID/AppSecret`，配置回调地址、授权方式、可用的登录 Provider。
3. 组织域：用 `AppRole` 做团队/租户隔离，用户在不同应用里可以有不同角色。RBAC 权限模型落在认证中心，资源权限还是业务系统自己持有。
4. 会话域：认证中心统一颁发 JWT（RSA 私钥签），业务系统拿 JWKS 公钥在本地验签，不回源。
5. Provider 域：短信、邮件、验证码、社交登录全做成可插拔接口，默认实现腾讯云 SMS/SES/Captcha，以后要换阿里或自建，加个实现就行。

技术栈上用 go-zero 拆 RPC 服务，Wire 做依赖注入，Service/DAO 分层。

![统一认证中心的五个核心域与一条信任链](/images/post-13-auth-center-domains.svg)

## 分层与关键代码

整体分层这样组织：

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

登录入口用 `AuthService` 统一编排。不管密码、短信还是社交登录，最后都收拢到同一套"凭证换 UserID → 发 Token"的流程里：

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

## 最难的是用户合并

五个域里真正难缠的是身份。一个用户先用微信登录、后来又用手机号注册，识别为同一个人之后要合并。我的做法是建一张 `user_bindings` 表，凭证和用户是多对一关系，合并时把旧凭证挂到新 UserID 下，再写一条审计日志。

麻烦在后头：业务系统的外键引用的还是旧 UserID，得发事件通知各系统做 ID 映射。这件事比当初拍板时想的工作量大得多。

## 吊销、组织树和供应商灰度

JWT 吊销是个老话题。我们用短 AccessToken（2 小时）加长 RefreshToken（7 天），RefreshToken 存 Redis，随时可吊销；AccessToken 不做黑名单，靠短过期自然失效。登出只吊销 RefreshToken。支付这类安全要求极高的场景，再加一个"令牌版本号"claim，改密码时版本号递增，旧 token 立刻作废。

组织这块一开始想把组织树建在认证中心，后来发现各业务系统的组织模型差异太大：统一支付平台里是商户，数据治理服务里是团队，知识库问答服务里是企业。强行统一就是削足适履。最后认证中心只存 `(app_id, user_id, role_external_id)`，组织名和层级由业务系统自己维护。

Provider 也有灰度需求。腾讯云短信偶尔抖动，我在 Provider 层加了个 `FanoutProvider`，按权重在多家供应商之间分流，失败自动降级，配置走配置中心热更新，不用重启。

## 后来

统一认证中心上线之后，新业务接入 SSO 只要半天，离职员工的账号在一处关掉就全端下线，安全审计也有了统一入口。回头看，做账号中台最重要的不是技术多花哨，而是克制：只做身份、认证、应用信任这三件事，组织和资源权限坚决留给业务系统。"登录"这件每个系统都要重复做的事，总算变成了一个可复用的平台能力。

> 封面图：[anthony arrigo / Flickr](https://www.flickr.com/photos/34831177@N06/3232156751) · CC BY 2.0
