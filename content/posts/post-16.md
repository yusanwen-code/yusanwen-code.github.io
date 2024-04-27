---
title: "多应用接入体系设计：AppID/AppSecret 与应用级 AccessToken"
date: 2024-04-27T10:30:00+08:00
draft: false
tags: ["AppID","AccessToken","多应用"]
categories: ["认证"]
description: "统一认证中心 中多应用接入的 AppID/AppSecret 与应用级 Token 设计"
---

## 问题背景

统一认证中心上线后，统一支付平台 支付、数据治理服务、数据集管理服务、知识库问答服务 等多个应用都要接入。这些应用有的是前端 SPA，有的是后端服务间调用，还有第三方合作方的系统。如果共用一套 client 凭证，权限边界根本划不清，某个应用被攻破会波及所有系统，也没法按应用做限流和审计。我们需要一套多应用接入体系：每个应用有独立身份、独立密钥、独立 Token，且能按应用做权限和配额隔离。

## 方案设计

我们给每个接入应用签发全局唯一 AppID（用 Snowflake 生成）和 AppSecret。AppSecret 在数据库里只存 bcrypt 哈希，创建时只返回一次明文。应用有两种拿 Token 的方式：一是用户登录后拿到的用户级 Access Token，audience 绑定到该 AppID；二是服务间调用用 client_credentials 模式，应用用 AppID+AppSecret 换应用级 Access Token，这种 Token 没有用户上下文，但带有 app_role 和 scope，用于后端服务互相调用。应用级 Token 设 2 小时有效期，网关按 AppID 做独立限流。

## 关键代码

```go
type App struct {
    ID          int64  `gorm:"primaryKey"`
    AppID       string `gorm:"uniqueIndex;size:32"`
    SecretHash  string `gorm:"size:128"`
    Name        string `gorm:"size:128"`
    RedirectURI string `gorm:"size:512"`
    Scopes      string `gorm:"size:512"` // 逗号分隔
    AppRole     string `gorm:"size:32"`
    Status      int8
}

func (s *Service) AppToken(ctx context.Context, appID, secret string) (*Token, error) {
    app, err := s.appDAO.GetByAppID(ctx, appID)
    if err != nil || app.Status != 1 {
        return nil, ErrInvalidApp
    }
    if err := bcrypt.CompareHashAndPassword(
        []byte(app.SecretHash), []byte(secret)); err != nil {
        return nil, ErrInvalidSecret
    }
    claims := &Claims{
        AppID:   app.AppID,
        AppRole: app.AppRole,
        Scopes:  strings.Split(app.Scopes, ","),
        RegisteredClaims: jwt.RegisteredClaims{
            Subject:   app.AppID,
            Issuer:    "passport",
            ExpiresAt: jwt.NewNumericDate(time.Now().Add(2 * time.Hour)),
        },
    }
    return s.issueToken(ctx, claims)
}
```

AppSecret 支持重置，重置后老 Secret 有 10 分钟宽限期，期间新旧都能用，给接入方平滑切换时间。网关层按 AppID 配置独立 QPS 配额，避免一个应用把认证中心打满。

## 踩坑与权衡

AppSecret 明文只展示一次这个设计，初期被不少接入方抱怨"忘了存怎么办"，我们后来加了 Secret 重置流程，但坚决不在数据库存明文。另一个坑是 client_credentials 拿到的 Token 权限过大，早期只认 AppID 就放行，后来强制要求应用级 Token 必须带 scope，网关按 scope 鉴权，遵循最小权限原则。内部服务间调用我们考虑过 mTLS，但运维成本高，最终还是用 AppID/AppSecret 加短期 Token，配合内网隔离和 IP 白名单。

## 小结

AppID/AppSecret 是多应用接入的基石，独立身份让权限、限流、审计都能按应用维度切分。应用级 Access Token 解决了服务间调用的身份问题，但要配合 scope 最小权限和短有效期。我们在 统一认证中心 里靠这套体系接入了公司内多个业务系统，新增应用只需要在管理后台创建、分配权限，不需要改认证中心代码。
