---
title: "基于 RSA/SHA 签名的 OpenAPI 安全机制实现"
slug: "post-09"
date: 2024-01-09T10:30:00+08:00
draft: false
image: /images/post-09-cover.jpg
tags: ["RSA", "签名", "OpenAPI"]
categories: ["安全"]
description: "统一支付平台 OpenAPI 签名校验与防重放机制设计"
---

## 为什么是 RSA，不是 HMAC

商户的服务器要调我们的下单、查询、退款接口，安全是第一道门槛。没法靠 Session，也不能让 AppSecret 在网络上裸奔。我参考了微信支付、支付宝那一套签名机制，最后定下 RSA 非对称签名加 SHA256 摘要，再用时间戳和随机串防重放。

为什么不全用 HMAC？因为 HMAC 是对称的，平台手里也捏着商户的密钥，一旦平台侧泄露，商户没法自证清白。换成 RSA 就没有这个问题：商户的私钥自己保管，平台只存公钥，谁发的、有没有被改，验签时责任边界清清楚楚。

## 签名串怎么拼

签名串的构造规则我们定得很死：

1. 按 ASCII 升序排列所有非空业务参数（不含 `sign`、`sign_type`、`sign_version`）；
2. 拼接成 `key1=value1&key2=value2`；
3. 末尾追加上行请求体的 SHA256 摘要（JSON 原文，不做字段排序）；
4. 商户私钥做 SHA256WithRSA 签名，Base64 编码后放在 `X-Sign` Header；
5. 同时带 `X-App-Id`、`X-Timestamp`（秒）、`X-Nonce`。

定这么死是故意的。签名串最怕商户各自发挥：参数排序差一点、大小写差一点，验签就永远过不去，还查不出是哪边的问题。

构造逻辑我直接写成一个纯函数，平台和 SDK 共用：

```go
func BuildSignString(query url.Values, body []byte) string {
    keys := make([]string, 0, len(query))
    for k := range query {
        if k == "sign" || k == "sign_type" {
            continue
        }
        if v := query.Get(k); v != "" {
            keys = append(keys, k)
        }
    }
    sort.Strings(keys)

    var buf strings.Builder
    for i, k := range keys {
        if i > 0 {
            buf.WriteByte('&')
        }
        buf.WriteString(k)
        buf.WriteByte('=')
        buf.WriteString(query.Get(k))
    }
    sum := sha256.Sum256(body)
    buf.WriteString("&body_sha256=")
    buf.WriteString(hex.EncodeToString(sum[:]))
    return buf.String()
}
```

## 验签四道关

平台校验四件事：AppId 是否存在、时间戳是否在 5 分钟窗口内、Nonce 是否在 Redis 里没出现过（防重放）、签名是否通过。

![OpenAPI 验签：签名在商户侧生成，四道关在平台侧依次过](/images/post-09-sign-verify.svg)

验签挂在 Gin 的 OpenAPI 路由组上，是个中间件：

```go
func RSAVerifyMiddleware(appDao dao.AppDAO, rdb *redis.Client) gin.HandlerFunc {
    return func(c *gin.Context) {
        appID := c.GetHeader("X-App-Id")
        timestamp := c.GetHeader("X-Timestamp")
        nonce := c.GetHeader("X-Nonce")
        sign := c.GetHeader("X-Sign")

        if appID == "" || timestamp == "" || nonce == "" || sign == "" {
            c.AbortWithStatusJSON(401, gin.H{"code": "MISSING_AUTH_HEADERS"})
            return
        }
        ts, err := strconv.ParseInt(timestamp, 10, 64)
        if err != nil || math.Abs(float64(time.Now().Unix()-ts)) > 300 {
            c.AbortWithStatusJSON(401, gin.H{"code": "TIMESTAMP_EXPIRED"})
            return
        }
        nonceKey := "openapi:nonce:" + appID + ":" + nonce
        if ok, _ := rdb.SetNX(c, nonceKey, 1, 10*time.Minute).Result(); !ok {
            c.AbortWithStatusJSON(401, gin.H{"code": "REPLAY_DETECTED"})
            return
        }

        app, err := appDao.FindByAppID(c, appID)
        if err != nil || app.Status != "ACTIVE" {
            c.AbortWithStatusJSON(401, gin.H{"code": "APP_NOT_FOUND"})
            return
        }
        body, _ := c.GetRawData()
        c.Request.Body = io.NopCloser(bytes.NewBuffer(body)) // 回放给后续 handler
        signStr := BuildSignString(c.Request.URL.Query(), body)

        pub, err := parseRSAPublicKey(app.PublicKey)
        if err != nil {
            c.AbortWithStatusJSON(401, gin.H{"code": "INVALID_PUBKEY"})
            return
        }
        hashed := sha256.Sum256([]byte(signStr))
        sig, _ := base64.StdEncoding.DecodeString(sign)
        if err := rsa.VerifyPKCS1v15(pub, crypto.SHA256, hashed[:], sig); err != nil {
            c.AbortWithStatusJSON(401, gin.H{"code": "SIGN_INVALID"})
            return
        }
        c.Set("app", app)
        c.Next()
    }
}
```

`GetRawData` 之后记得用 `io.NopCloser` 把 body 放回去，否则后续 `ShouldBindJSON` 会读到空。这是我第一次联调踩的坑。

## 四个权衡

第一是 GET 请求的 body 处理。GET 没有 body，我们约定 `body_sha256` 字段直接填空字符串的 SHA256（即 `e3b0c442...`），而不是省略这个字段。签名串结构稳定，SDK 不用写两套分支。

第二是 Nonce 的存储成本。Redis 存 10 分钟窗口的 Nonce，看着有压力，实际上按 AppId 隔离之后单商户 QPS 并不高，10 分钟过期自动回收，没必要上滑动窗口或布隆过滤器。

第三是密钥轮换。App 表里留了 `public_key` 和 `public_key_prev` 两个字段，轮换时新公钥进主字段、旧公钥降到 prev，中间件两把都试。商户有 24 小时灰度窗口，不会一刀切验签失败。

第四是要不要加密 body。平台已经全链路 HTTPS，签名本身防篡改，最后没做请求体加密，只有银行卡号这类敏感字段由业务层单独做字段级加密。给所有商户平添一层对接成本，不值。

## 上线之后

上线至今，没出过签名层面的安全事件。回头看，这套机制的核心不在算法多强，而在规则够不够死、边界够不够清：谁发的、有没有被改、是不是重放，一趟验签全解决。商户接入文档里我配了 Java、Python、Go 三份 SDK 示例，写文档花的功夫，比后来省下的联调时间少多了。

> 封面图：[Simon A. Eugster / Wikimedia Commons](https://commons.wikimedia.org/w/index.php?curid=52421294) · CC BY-SA 3.0
