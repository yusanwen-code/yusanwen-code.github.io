---
title: "Gin 中间件实战：JWT 认证与请求日志异步落盘 MongoDB"
slug: "post-06"
date: 2023-11-23T10:30:00+08:00
draft: false
tags: ["Gin","JWT","MongoDB"]
categories: ["Go"]
description: "在 Gin 中实现 JWT 认证中间件，并将请求日志通过 channel 异步写入 MongoDB"
---

## 问题背景

宠物医疗 SaaS 系统的 B/S 版后端需要统一的认证和审计。所有 API 请求都要校验 JWT，提取用户和医院上下文；同时合规要求所有请求日志要落盘，包括请求方法、路径、参数、响应状态码、耗时、操作者等，保留半年用于审计追溯。

同步写日志会拖慢接口响应，而且日志结构嵌套深、量大，用 MySQL 存查询和归档都不方便，我选了 MongoDB。日志通过 channel 异步写入，不阻塞主请求。

## 方案/设计

JWT 中间件用 `golang-jwt/jwt/v5`，从 `Authorization` 头解析 token，校验签名和过期时间，把用户 ID、医院 ID、角色注入 `gin.Context`：

```go
type Claims struct {
    UserID   int64  `json:"uid"`
    HospID   int64  `json:"hid"`
    RoleCode string `json:"rol"`
    jwt.RegisteredClaims
}

func JWTAuth(signingKey []byte) gin.HandlerFunc {
    return func(c *gin.Context) {
        tokenStr := c.GetHeader("Authorization")
        if len(tokenStr) > 7 && tokenStr[:7] == "Bearer " {
            tokenStr = tokenStr[7:]
        }
        if tokenStr == "" {
            c.AbortWithStatusJSON(401, gin.H{"code": 401, "msg": "missing token"})
            return
        }

        claims := &Claims{}
        token, err := jwt.ParseWithClaims(tokenStr, claims, func(t *jwt.Token) (interface{}, error) {
            if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
                return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
            }
            return signingKey, nil
        })
        if err != nil || !token.Valid {
            c.AbortWithStatusJSON(401, gin.H{"code": 401, "msg": "invalid token"})
            return
        }

        c.Set("uid", claims.UserID)
        c.Set("hid", claims.HospID)
        c.Set("rol", claims.RoleCode)
        c.Next()
    }
}
```

日志中间件用 `ResponseWriter` 包装器捕获响应状态码和响应体大小，通过一个带缓冲 channel 把日志投递给后台 writer。这里用 channel 和之前埋点上报同样的非阻塞策略，但审计日志不允许丢，所以 channel 满时降级写本地文件而不是丢弃：

```go
type AccessLog struct {
    TraceID    string        `bson:"trace_id"`
    UserID     int64         `bson:"user_id"`
    HospID     int64         `bson:"hosp_id"`
    Method     string        `bson:"method"`
    Path       string        `bson:"path"`
    Query      string        `bson:"query"`
    ClientIP   string        `bson:"client_ip"`
    StatusCode int           `bson:"status_code"`
    Latency    time.Duration `bson:"latency"`
    ReqSize    int           `bson:"req_size"`
    RespSize   int           `bson:"resp_size"`
    ErrMsg     string        `bson:"err_msg,omitempty"`
    CreatedAt  time.Time     `bson:"created_at"`
}

type bodyWriter struct {
    gin.ResponseWriter
    size int
}

func (w *bodyWriter) Write(b []byte) (int, error) {
    n, err := w.ResponseWriter.Write(b)
    w.size += n
    return n, err
}

func AccessLogMiddleware(logCh chan<- *AccessLog, fallback *os.File) gin.HandlerFunc {
    return func(c *gin.Context) {
        start := time.Now()
        bw := &bodyWriter{ResponseWriter: c.Writer}
        c.Writer = bw

        c.Next()

        entry := &AccessLog{
            TraceID:    c.GetString("trace_id"),
            Method:     c.Request.Method,
            Path:       c.Request.URL.Path,
            Query:      c.Request.URL.RawQuery,
            ClientIP:   c.ClientIP(),
            StatusCode: c.Writer.Status(),
            Latency:    time.Since(start),
            ReqSize:    int(c.Request.ContentLength),
            RespSize:   bw.size,
            CreatedAt:  start,
        }
        if uid, ok := c.Get("uid"); ok {
            entry.UserID = uid.(int64)
        }
        if hid, ok := c.Get("hid"); ok {
            entry.HospID = hid.(int64)
        }
        if len(c.Errors) > 0 {
            entry.ErrMsg = c.Errors.String()
        }

        select {
        case logCh <- entry:
        default:
            // channel 满，降级写本地文件，保证审计日志不丢
            json.NewEncoder(fallback).Encode(entry)
        }
    }
}
```

后台 writer 批量写入 MongoDB，利用 `mongo.Collection` 的 `BulkWrite`：

```go
func LogWriter(ctx context.Context, coll *mongo.Collection, ch <-chan *AccessLog) {
    batch := make([]mongo.WriteModel, 0, 200)
    ticker := time.NewTicker(500 * time.Millisecond)
    defer ticker.Stop()

    flush := func() {
        if len(batch) == 0 {
            return
        }
        _, err := coll.BulkWrite(ctx, batch)
        if err != nil {
            log.Printf("mongo bulk write error: %v", err)
        }
        batch = batch[:0]
    }

    for {
        select {
        case e := <-ch:
            m := mongo.NewInsertOneModel().SetDocument(e)
            batch = append(batch, m)
            if len(batch) >= 200 {
                flush()
            }
        case <-ticker.C:
            flush()
        case <-ctx.Done():
            flush()
            return
        }
    }
}
```

## 踩坑/权衡

第一个坑是请求体不能直接读。最开始我把 `c.Request.Body` 读出来记日志，但读完之后后续 handler 就拿不到 body 了。需要用 `io.NopCloser` + `bytes.Buffer` 复制一份再放回去，而且大 body 要截断，否则日志体积爆炸。我们只记前 1KB。

第二个是敏感字段脱敏。密码、身份证、手机号不能明文进日志。我在序列化前对 query 和 body 里的 `password`、`id_card`、`phone` 字段做了掩码处理，这是合规硬要求，不能等到数据入库再处理。

第三个是 MongoDB 写入延迟。BulkWrite 在批量 200 条时延迟很稳定，但如果 MongoDB 副本集发生主从切换，写入会短暂失败。我们在 flush 失败时把批次写回本地文件，有一个补传任务定期扫描文件重放，保证审计数据最终不丢。

第四个是 JWT 的注销问题。JWT 是无状态的，token 在过期前无法主动失效。我们在 Redis 里维护了一个黑名单（退出登录或改密码时把 token 的 jti 加入，TTL 等于剩余有效期），中间件多查一次 Redis。这会给每个请求加一次 Redis 调用，但比完全无状态要安全。

## 小结

认证和日志是每个 Web 服务的标配，但做好需要注意细节：JWT 要校验签名算法防止 alg 混淆攻击，日志要异步但不能丢（channel 满降级文件），敏感字段必须在入口脱敏，请求体读后要放回。这两个中间件后来成为我所有 Go Web 项目的基础组件。
