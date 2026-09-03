---
title: "OAuth2/OIDC 认证中心实现：authorize/token/userinfo 与 JWKS"
slug: "post-14"
date: 2024-03-27T10:30:00+08:00
draft: false
image: /images/post-14-cover.jpg
tags: ["OAuth2", "OIDC", "JWT"]
categories: ["安全"]
description: "统一认证中心实现标准 OAuth2/OIDC 协议端点的工程细节"
---

## 问题背景

统一认证中心第一版只做了内部系统的 SSO，用的是自定义的 cookie + session 方案。后来要接入外部第三方应用，还要让企业客户用自己的飞书/企微做身份源（IdP），自定义协议就走不通了。我当时决定把统一认证中心改造成标准的 **OAuth2/OIDC Provider**，让任何符合协议的客户端都能接入，同时也能作为 RP 对接外部 IdP。

标准协议听起来就是实现几个端点，但真正落地有一堆工程细节：授权码模式的 PKCE、state/nonce 防 CSRF、redirect_uri 严格校验、ID Token 的签名与 claims、JWKS 公钥轮换。

## 方案设计

OIDC 在 OAuth2 之上加了身份层，核心要实现四个端点：

- `GET /oauth/authorize`：用户登录与授权同意，返回 code；
- `POST /oauth/token`：用 code 换 access_token / id_token / refresh_token；
- `GET /oauth/userinfo`：用 access_token 取用户信息；
- `GET /.well-known/openid-configuration` 和 `/oauth/jwks`：发现文档与公钥集合。

授权码模式（Authorization Code）+ PKCE 作为默认，所有 public client 强制 PKCE；client credentials 用于服务间调用。

## 关键代码

`/authorize` 端点先做参数校验，再判断是否已登录，没登录跳转到登录页，带上 state 保证回跳：

```go
func (h *OAuthHandler) Authorize(c *gin.Context) {
    var req AuthorizeReq
    if err := c.ShouldBindQuery(&req); err != nil {
        c.String(400, "invalid request")
        return
    }
    app, err := h.appSvc.VerifyRedirectURI(c, req.ClientID, req.RedirectURI)
    if err != nil {
        c.String(400, "invalid redirect_uri")
        return
    }
    if req.ResponseType != "code" {
        c.Redirect(302, appendErr(req.RedirectURI, "unsupported_response_type", req.State))
        return
    }
    // PKCE: code_challenge 必填
    if req.CodeChallenge == "" || req.CodeChallengeMethod != "S256" {
        c.Redirect(302, appendErr(req.RedirectURI, "invalid_request", req.State))
        return
    }

    userID, loggedIn := session.GetUserID(c)
    if !loggedIn {
        c.Redirect(302, "/login?redirect="+url.QueryEscape(c.Request.RequestURI))
        return
    }

    code, err := h.authSvc.CreateAuthCode(c, AuthCode{
        AppID:           app.AppID,
        UserID:          userID,
        RedirectURI:     req.RedirectURI,
        Scope:           req.Scope,
        Nonce:           req.Nonce,
        CodeChallenge:   req.CodeChallenge,
        ExpiresAt:       time.Now().Add(60 * time.Second),
    })
    if err != nil {
        c.String(500, "server error")
        return
    }
    u, _ := url.Parse(req.RedirectURI)
    q := u.Query()
    q.Set("code", code)
    q.Set("state", req.State)
    u.RawQuery = q.Encode()
    c.Redirect(302, u.String())
}
```

`/token` 端点校验 code、PKCE verifier，然后签发 token：

```go
func (h *OAuthHandler) Token(c *gin.Context) {
    if err := c.Request.ParseForm(); err != nil {
        c.JSON(400, tokenErr("invalid_request"))
        return
    }
    grant := c.PostForm("grant_type")
    clientID, secret, ok := c.Request.BasicAuth()
    if !ok {
        c.JSON(401, tokenErr("invalid_client"))
        return
    }
    app, err := h.appSvc.Authenticate(c, clientID, secret)
    if err != nil {
        c.JSON(401, tokenErr("invalid_client"))
        return
    }

    switch grant {
    case "authorization_code":
        code := c.PostForm("code")
        verifier := c.PostForm("code_verifier")
        ac, err := h.authSvc.ConsumeAuthCode(c, code, app.AppID)
        if err != nil {
            c.JSON(400, tokenErr("invalid_grant"))
            return
        }
        if !pkce.Verify(ac.CodeChallenge, verifier) {
            c.JSON(400, tokenErr("invalid_grant"))
            return
        }
        pair, err := h.tokenSvc.Issue(OIDCTokenInput{
            UserID:   ac.UserID,
            AppID:    app.AppID,
            Nonce:    ac.Nonce,
            Scope:    ac.Scope,
            AuthTime: ac.CreatedAt,
        })
        if err != nil {
            c.JSON(500, tokenErr("server_error"))
            return
        }
        c.JSON(200, gin.H{
            "access_token":  pair.AccessToken,
            "id_token":      pair.IDToken,
            "refresh_token": pair.RefreshToken,
            "token_type":    "Bearer",
            "expires_in":    7200,
            "scope":         ac.Scope,
        })
    case "refresh_token":
        // 省略：验证 refresh token 并重新签发
    }
}
```

PKCE 校验就是 SHA256 + Base64URL：

```go
func Verify(challenge, verifier string) bool {
    sum := sha256.Sum256([]byte(verifier))
    computed := base64.RawURLEncoding.EncodeToString(sum[:])
    return subtle.ConstantTimeCompare([]byte(computed), []byte(challenge)) == 1
}
```

ID Token 是 OIDC 的核心，必须包含标准 claims：

```go
func (s *Service) buildIDToken(input OIDCTokenInput, user *User) (string, error) {
    now := time.Now()
    claims := IDTokenClaims{
        Issuer:    s.issuer,
        Subject:   strconv.FormatInt(user.ID, 10),
        Audience:  jwt.ClaimStrings{input.AppID},
        ExpiresAt: jwt.NewNumericDate(now.Add(2 * time.Hour)),
        IssuedAt:  jwt.NewNumericDate(now),
        AuthTime:  jwt.NewNumericDate(input.AuthTime),
        Nonce:     input.Nonce,
        Name:      user.Nickname,
        Picture:   user.Avatar,
        Email:     user.Email,
        Phone:     user.Phone,
    }
    return jwt.NewWithClaims(jwt.SigningMethodRS256, claims).SignedString(s.privKey)
}
```

JWKS 端点暴露公钥，支持轮换：

```go
func (h *OAuthHandler) JWKS(c *gin.Context) {
    set := h.keySvc.PublicKeySet() // 返回当前 + 上一把公钥
    c.JSON(200, gin.H{"keys": set})
}
```

公钥的 JSON 表示要用 `jwk` 格式（kty/n/e/x5c 等字段），我用 `lestrrat-go/jwx/jwk` 来做序列化，避免手写：

```go
import "github.com/lestrrat-go/jwx/jwk"

func (s *KeyService) PublicKeySet() jwk.Set {
    set := jwk.NewSet()
    for _, k := range s.activeKeys() {
        key, _ := jwk.New(k.PublicKey)
        key.Set(jwk.KeyIDKey, k.Kid)
        key.Set(jwk.AlgorithmKey, "RS256")
        key.Set(jwk.KeyUsageKey, "sig")
        set.AddKey(key)
    }
    return set
}
```

## 踩坑与权衡

**redirect_uri 必须精确匹配**。早期为了方便支持了前缀匹配，被安全团队指出有开放重定向风险，改成配置里完整 URL 白名单，查询参数不参与匹配。

**ID Token 的 nonce 一定要原样回传**。客户端用它防重放，如果我们漏传，严格的 OIDC 客户端会直接拒绝登录。

**Code 一次性使用 + 短过期**。我把 code 设成 60 秒过期、用后即删，并且同一 code 被二次使用时立即吊销该 app 下所有该用户的活跃 token，这是 OAuth2 安全 BCP 推荐做法。

**公钥轮换**要平滑。JWT header 里带 `kid`，资源服务器按 `kid` 从 JWKS 缓存公钥；换密钥时新私钥签发带新 kid 的 token，旧公钥在 JWKS 里保留 7 天，让存量 token 自然过期。

**/userinfo 接口**默认只返回 sub，其他 claims 要看 access token 的 scope 是否包含 `profile/email/phone`，不能一股脑把用户信息全吐出去。

**不要自己造 JWT 轮子**。我用 `golang-jwt/jwt/v5` 签发、`lestrrat-go/jwx` 处理 JWK，两个库都是社区主流，避免自己手写 base64 和 JSON 序列化时漏边界条件。

## 小结

实现标准 OAuth2/OIDC 的工作量不在代码量，而在把协议里那些 MUST/SHOULD 的安全要求逐条落到工程里：PKCE、state/nonce、精确 redirect_uri、code 一次性、JWKS 轮换。统一认证中心改造完成后，任何标准 OIDC 客户端（NextAuth、Spring Security、Keycloak adapter）都能直接接入，飞书/企微作为外部 IdP 也能通过同一个 OIDC 联邦框架对接，扩展性比自定义协议好得多。标准协议的价值，就在于它让"对接"这件事不再需要一对一谈判。

> 封面图：[Strooks-traveller1 / Flickr](https://www.flickr.com/photos/44241312@N08/4059216490) · CC BY-SA 2.0
