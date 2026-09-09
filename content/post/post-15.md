---
title: "基于 RSA 非对称签名签发 JWT 的多系统单点登录实践"
slug: "post-15"
date: 2024-04-12T10:30:00+08:00
draft: false
image: /images/post-15-cover.jpg
tags: ["JWT","SSO","RSA"]
categories: ["安全"]
description: "在统一认证中心用 RSA 签发 JWT 实现多系统 SSO"
---

## HMAC 差在哪

我们在某科技公司做统一认证中心时，多个业务系统（统一支付平台、数据治理服务、知识库问答服务等）各自维护登录态，用户在系统间跳转要反复登录。最初考虑过用 HMAC 对称签名签发 JWT，但那样每个下游系统都得持有同一把密钥，一处泄露，整个认证体系就崩了，轮换密钥还得挨个通知所有业务方，运维成本很高。

最后选了 RSA 非对称签名：统一认证中心持私钥签发 JWT，各业务系统只持公钥验签，私钥永远不离开认证中心。

## 私钥签发，公钥验签

整体流程是：用户在统一认证中心登录后，认证中心用 RSA 私钥签发 Access Token 和 Refresh Token，写进 Cookie 或通过 Authorization 头返回。业务系统在网关层用公钥本地验签，不需要每次回调统一认证中心，认证中心的压力也小。

JWT 里放了 user_id、app_id、team_id、roles、exp、iss、aud 这些声明。iss 固定为 passport，aud 是目标应用的 AppID，防止 token 被跨应用滥用。Access Token 有效期 2 小时，Refresh Token 7 天，刷新时轮转新 Token。

![RSA 单点登录：签发、验签与密钥轮换](/images/post-15-rsa-sso.svg)

## 代码里就两个函数

```go
import (
    "crypto/rsa"
    "time"

    "github.com/golang-jwt/jwt/v5"
)

type Claims struct {
    UserID int64    `json:"user_id"`
    AppID  string   `json:"app_id"`
    TeamID int64    `json:"team_id"`
    Roles  []string `json:"roles"`
    JTI    string   `json:"jti"`
    jwt.RegisteredClaims
}

func (s *Service) SignToken(c *Claims, ttl time.Duration) (string, error) {
    c.RegisteredClaims = jwt.RegisteredClaims{
        Issuer:    "passport",
        Audience:  jwt.ClaimStrings{c.AppID},
        ExpiresAt: jwt.NewNumericDate(time.Now().Add(ttl)),
        IssuedAt:  jwt.NewNumericDate(time.Now()),
        ID:        c.JTI,
    }
    tok := jwt.NewWithClaims(jwt.SigningMethodRS256, c)
    return tok.SignedString(s.privKey) // *rsa.PrivateKey
}

func ParseToken(pub *rsa.PublicKey, tokenStr string) (*Claims, error) {
    claims := &Claims{}
    tok, err := jwt.ParseWithClaims(tokenStr, claims, func(t *jwt.Token) (interface{}, error) {
        if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
            return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
        }
        return pub, nil
    })
    if err != nil || !tok.Valid {
        return nil, err
    }
    return claims, nil
}
```

验签逻辑放在各业务系统的 gRPC/HTTP 拦截器里，公钥通过配置中心下发。密钥轮转也支持：统一认证中心同时挂载新老两把私钥签发，公钥端点暴露 JWKS，业务系统定期拉取缓存。

## alg=none 和另外两个坑

一是 alg=none 攻击。ParseWithClaims 的回调里必须校验 t.Method 是 RS256，不能信任 header 里的 alg。

二是 JWT 无法主动失效。我们用 Redis 维护黑名单，退出登录时把 jti 写进去，直到 token 自然过期才出黑名单。代价是每次请求多一次 Redis 查询，用 pipeline 加本地短缓存，压到可接受。

三是密钥轮转初期踩过坑：新私钥签发的 token，老业务系统还没拉到新公钥，验签直接失败。后来改成两把私钥灰度签发、JWKS 缓存 10 分钟、切换前先发公钥再切私钥，才算平稳。

## 后来

RSA 非对称签名让私钥收敛在认证中心，下游只持公钥，安全性和可扩展性都比 HMAC 好。配合短有效期 Access Token、Refresh Token 轮转和 Redis 黑名单，多业务系统的 SSO 就立住了。后续要接微信、企微、飞书登录，也只是多一种签发来源，验签侧一行不用改。

> 封面图：[pixishared / Flickr](https://www.flickr.com/photos/60614544@N02/6878462778) · CC BY-SA 2.0
