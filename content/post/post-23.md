---
title: "微信、企业微信、飞书 OAuth 一键登录与账号绑定"
slug: "post-23"
date: 2024-08-15T10:30:00+08:00
draft: false
image: /images/post-23-cover.jpg
tags: ["OAuth","微信登录","飞书"]
categories: ["认证"]
description: "统一认证中心中三端 OAuth 登录与账号绑定的统一抽象"
---

## 三套流程，三种脾气

统一认证中心除了账号密码，还要接微信、企业微信、飞书的一键登录，而且得让同一个真人能把好几个第三方身份绑到同一个账号上。

麻烦在于，三家的 OAuth 流程看着相似，细节脾气完全不同：微信网页授权是 code 换 access_token，再拿 unionid；企业微信要 corpid + agentid，userid 只在企业内唯一；飞书走标准 OIDC 风格，还有个独立的 user_info 端点。

要是一个平台写一套独立 callback，维护成本扛不住。所以先定目标：抽象出统一的 Provider 接口，新增平台只实现接口，业务层不感知差异。

## 一个接口收编三个平台

接口就两个方法：AuthURL 生成跳转地址，Exchange 拿 code 换身份信息，返回统一的 Identity——平台类型、OpenID、UnionID、昵称、头像，都在里面。

账号绑定关系落在 user_identities 表，user_id + provider + provider_uid 联合唯一。登录时按 provider + uid 查这张表：查到，直接签发 JWT；查不到但当前已登录，走绑定流程；完全没账号，自动注册再绑上。

state 用 Redis 存 5 分钟，key 是随机 state，value 里带 redirect_uri 和操作类型（login 还是 bind）。既防 CSRF，回调时又能把上下文捞回来。

![三个平台的 OAuth 回调收敛到统一 Callback 流程](/images/post-23-oauth-callback.svg)

```go
type Identity struct {
    Provider  string
    OpenID    string
    UnionID   string
    Nickname  string
    AvatarURL string
}

type IdentityProvider interface {
    AuthURL(state string) string
    Exchange(ctx context.Context, code string) (*Identity, error)
}

type OAuthHandler struct {
    db        *gorm.DB
    rdb       *redis.Client
    providers map[string]IdentityProvider
    sf        *Snowflake
}

func (h *OAuthHandler) Callback(c *gin.Context) {
    state := c.Query("state")
    code := c.Query("code")

    metaStr, err := h.rdb.Get(c.Request.Context(), "oauth:state:"+state).Result()
    if err != nil {
        c.JSON(400, gin.H{"msg": "invalid or expired state"})
        return
    }
    h.rdb.Del(c.Request.Context(), "oauth:state:"+state)

    var meta struct {
        Provider   string `json:"provider"`
        Redirect   string `json:"redirect"`
        Action     string `json:"action"`
        BindUserID int64  `json:"bind_user_id"`
    }
    json.Unmarshal([]byte(metaStr), &meta)

    p := h.providers[meta.Provider]
    ident, err := p.Exchange(c.Request.Context(), code)
    if err != nil {
        c.JSON(502, gin.H{"msg": "exchange failed"})
        return
    }

    var bind UserIdentity
    err = h.db.Where("provider = ? AND provider_uid = ?",
        ident.Provider, ident.OpenID).First(&bind).Error

    switch meta.Action {
    case "login":
        if errors.Is(err, gorm.ErrRecordNotFound) {
            uid, err := h.sf.NextID()
            if err != nil {
                c.JSON(500, gin.H{"msg": "id gen failed"})
                return
            }
            h.db.Create(&User{ID: uid, Nickname: ident.Nickname, Avatar: ident.AvatarURL})
            h.db.Create(&UserIdentity{
                UserID: uid, Provider: ident.Provider,
                ProviderUID: ident.OpenID, UnionID: ident.UnionID,
            })
            issueJWTAndRedirect(c, uid, meta.Redirect)
            return
        }
        issueJWTAndRedirect(c, bind.UserID, meta.Redirect)
    case "bind":
        h.db.Create(&UserIdentity{
            UserID: meta.BindUserID, Provider: ident.Provider,
            ProviderUID: ident.OpenID, UnionID: ident.UnionID,
        })
        c.Redirect(302, meta.Redirect)
    }
}
```

飞书 Provider 的 Exchange 大致是：

```go
func (p *FeishuProvider) Exchange(ctx context.Context, code string) (*Identity, error) {
    resp, err := http.PostForm(p.TokenURL, url.Values{
        "app_id": {p.AppID}, "app_secret": {p.AppSecret},
        "grant_type": {"authorization_code"}, "code": {code},
    })
    // 解析 access_token，再请求 /open-apis/authen/v1/user_info
    // 略
}
```

## 各平台的坑

微信的 unionid 只有在开放平台绑定同主体应用后才会返回，网页授权单独拿不到。我们最初以为 openid 够用，结果同一个人在公众号和小程序之间对不上，后来补了 unionid 机制。

企业微信的 userid 是企业管理员导入的，OAuth 拿到的 userid 未必等于统一认证中心里的手机号，手动绑定入口省不掉。

自动注册体验好，副作用是一堆空壳账号。后来加了条策略：同一手机号已有账号的，提示登录后绑定，不直接新建。

state 必须一次性消费，回调里立刻 Del，防重放；只存 Redis 不写库，5 分钟过期自动清。

最后是 token 的琐碎账：飞书的 app_access_token 和 user_access_token 是两个东西，别拿错；企业微信的 access_token 有有效期和频次限制，得做缓存。

## 后来

三个平台收进一个 Provider 接口之后，再接钉钉或者自定义 OIDC 应用，实现两个方法就能上。账号绑定的核心就是 user_identities 这张关系表加 state 机制，剩下的活，是对各家文档细节的耐心。

> 封面图：[_Franck Michel_ / Flickr](https://www.flickr.com/photos/33634811@N07/29928732713) · CC BY 2.0
