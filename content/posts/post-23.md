---
title: "微信、企业微信、飞书 OAuth 一键登录与账号绑定"
date: 2024-08-15T10:30:00+08:00
draft: false
tags: ["OAuth","微信登录","飞书"]
categories: ["认证"]
description: "统一认证中心 中三端 OAuth 登录与账号绑定的统一抽象"
---

## 问题背景

统一认证中心除了账号密码，还需要支持微信、企业微信、飞书的一键登录，并且要让同一个真人能把多个第三方身份绑定到同一个 统一认证中心 账号。三个平台的 OAuth 流程相似但细节差异很大：微信网页授权用 code 换 access_token 再拿 unionid；企业微信需要 corpid + agentid 且 userid 在企业内唯一；飞书走标准 OIDC 风格，有独立的 user_info 端点。

如果每个平台写一套独立的 callback，维护成本很高。我们的目标是抽象出统一的 Provider 接口，新增平台只实现接口，业务层不感知差异。

## 方案设计

定义 `IdentityProvider` 接口：AuthURL 生成跳转地址，Exchange 用 code 换身份信息，返回统一的 `Identity`（平台类型、OpenID、UnionID、昵称、头像）。

账号绑定关系存 `user_identities` 表：user_id + provider + provider_uid 联合唯一。登录时根据 provider+uid 查绑定记录，找到则直接签发 JWT；找不到但当前已登录，则走绑定流程；完全没账号则自动注册并绑定。

state 参数用 Redis 存 5 分钟，key 是随机 state，value 包含 redirect_uri 和操作类型（login/bind），既防 CSRF 又能在回调时恢复上下文。

## 关键代码

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

## 踩坑与权衡

- 微信的 unionid 只有在开放平台绑定同主体应用后才会返回，网页授权单独拿不到。我们最初以为 openid 够用，结果同一用户在公众号和小程序间无法识别，后来补了 unionid 机制。
- 企业微信的 userid 是企业内管理员导入的，OAuth 拿到的 userid 不一定等于 统一认证中心 里的手机号，需要提供手动绑定入口。
- 自动注册虽然体验好，但会产生大量"空壳账号"。我们后来加了策略：如果同一手机号已存在账号，提示用户登录后绑定，而不是直接新建。
- state 必须一次性消费，回调里立即 Del，防止重放。state 只存 Redis 不写库，5 分钟过期自动清理。
- 飞书的 app_access_token 和 user_access_token 是两个东西，别拿错；企业微信的 access_token 有有效期和频次限制，要做缓存。

## 小结

把三个平台抽象成统一的 Provider 接口后，新增钉钉或自定义 OIDC 应用只需实现两个方法。账号绑定的核心是 `user_identities` 这张关系表和 state 机制，剩下的就是对各平台文档细节的耐心处理。
