---
title: "多应用接入体系设计：AppID/AppSecret 与应用级 AccessToken"
slug: "post-16"
date: 2024-04-27T10:30:00+08:00
draft: false
image: /images/post-16-cover.jpg
tags: ["AppID","AccessToken","多应用"]
categories: ["认证"]
description: "统一认证中心中多应用接入的 AppID/AppSecret 与应用级 Token 设计"
---

## 一套凭证共用，边界就没了

统一认证中心上线后，统一支付平台、数据治理服务、数据集管理服务、知识库问答服务等多个应用都要接入。这些应用形态不一：有的是前端 SPA，有的是后端服务间调用，还有第三方合作方的系统。如果共用一套 client 凭证，权限边界根本划不清，某个应用被攻破会波及所有系统，也没法按应用做限流和审计。

所以我们需要一套多应用接入体系，目标很明确：每个应用有独立身份、独立密钥、独立 Token，权限和配额都能按应用隔离。

## 每个应用一个身份

我们给每个接入应用签发全局唯一的 AppID（Snowflake 生成）和 AppSecret。AppSecret 在数据库里只存 bcrypt 哈希，创建时明文只返回一次。

应用有两种拿 Token 的方式。一是用户登录后拿用户级 Access Token，audience 绑定到该 AppID；二是服务间调用走 client_credentials，应用拿 AppID+AppSecret 去换应用级 Access Token。这种 Token 没有用户上下文，但带 app_role 和 scope，2 小时有效期，网关按 AppID 做独立限流。

![多应用接入：独立身份与两种 Token](/images/post-16-app-token.svg)

## AppToken：先验应用，再对哈希

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

AppSecret 支持重置，重置后老 Secret 有 10 分钟宽限期，期间新旧都能用，给接入方留出平滑切换的时间。网关层按 AppID 配置独立 QPS 配额，免得一个应用把认证中心打满。

## 不存明文，也不要过大的权限

AppSecret 明文只展示一次这个设计，初期被不少接入方抱怨"忘了存怎么办"。我们后来加了 Secret 重置流程，但坚决不在数据库存明文。

另一个坑是 client_credentials 拿到的 Token 权限过大：早期只认 AppID 就放行，后来强制应用级 Token 必须带 scope，网关按 scope 鉴权，遵循最小权限原则。

内部服务间调用我们考虑过 mTLS，运维成本高，放弃了。最终用的是 AppID/AppSecret 加短期 Token，配合内网隔离和 IP 白名单。

## 后来

AppID/AppSecret 是多应用接入的基石。独立身份让权限、限流、审计都能按应用维度切分；应用级 Access Token 解决了服务间调用的身份问题，但前提是配 scope 最小权限和短有效期。我们靠这套体系接入了公司内多个业务系统，新增应用只需要在管理后台创建、分配权限，认证中心的代码一行不用改。

> 封面图：[kalleboo / Flickr](https://www.flickr.com/photos/82365211@N00/8203658681) · CC BY 2.0
