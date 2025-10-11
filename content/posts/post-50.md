---
title: "用 Zap + ELK 构建 Go 服务结构化日志体系"
date: 2025-10-11T10:30:00+08:00
draft: false
tags: ["Zap", "ELK", "日志"]
categories: ["可观测性"]
description: "在 统一认证中心、统一支付平台 等多服务里用 Zap + ELK 落地结构化日志的实践"
---

## 问题背景

在某科技公司主导 统一认证中心、统一支付平台、知识库问答服务 等多个 Go 服务后，我发现早期用标准 `log` 包打文本日志在排障时非常痛苦：多个服务之间走 gRPC，一个请求要在几十个 Pod 的日志里来回 grep，trace_id 还经常对不上。我们决定统一到 Zap + ELK 的结构化日志体系。

## 方案设计

Zap 选 `NewProduction` 的 JSON Encoder，通过 `context.Context` 注入 `trace_id`、`request_id`、`tenant_id`。Gin 中间件在 HTTP 入口生成或透传 trace_id，gRPC 拦截器从 metadata 里取出并挂到 logger 上。日志统一写 stdout，由 Filebeat 采集到 Logstash，清洗后入 Elasticsearch，Kibana 里按 trace_id 聚合查询。知识库问答服务 的流式接口还会把会话 ID 打到字段里，方便复现某一轮对话。

## 关键代码

Logger 初始化：

```go
func NewLogger(env string) *zap.Logger {
    var cfg zap.Config
    if env == "production" {
        cfg = zap.NewProductionConfig()
        cfg.EncoderConfig.TimeKey = "ts"
        cfg.EncoderConfig.EncodeTime = zapcore.ISO8601TimeEncoder
        cfg.Sampling = &zap.SamplingConfig{
            Initial:    100,
            Thereafter: 100,
        }
    } else {
        cfg = zap.NewDevelopmentConfig()
        cfg.EncoderConfig.EncodeLevel = zapcore.CapitalColorLevelEncoder
    }
    lg, err := cfg.Build(zap.AddCallerSkip(1))
    if err != nil {
        panic(err)
    }
    return lg
}
```

Gin 中间件把 trace_id 塞进 context，并打访问日志：

```go
const TraceIDHeader = "X-Trace-Id"

func AccessLog(lg *zap.Logger) gin.HandlerFunc {
    return func(c *gin.Context) {
        start := time.Now()
        tid := c.GetHeader(TraceIDHeader)
        if tid == "" {
            tid = uuid.NewString()
        }
        c.Writer.Header().Set(TraceIDHeader, tid)
        c.Set("logger", lg.With(
            zap.String("trace_id", tid),
            zap.String("path", c.Request.URL.Path),
        ))
        c.Next()
        lg.Info("http.access",
            zap.String("trace_id", tid),
            zap.Int("status", c.Writer.Status()),
            zap.Duration("latency", time.Since(start)),
            zap.String("client_ip", c.ClientIP()),
        )
    }
}
```

业务代码里通过 helper 取带字段的 logger：

```go
type ctxKey struct{}

func FromContext(ctx context.Context) *zap.Logger {
    if l, ok := ctx.Value(ctxKey{}).(*zap.Logger); ok {
        return l
    }
    return zap.L()
}
```

gRPC 服务端拦截器从 metadata 透传 trace_id，保证跨进程串联，这里不再展开。

## 踩坑与权衡

第一，`SugaredLogger` 比强类型 `Logger` 慢约三成，在 知识库问答服务 流式输出这种热路径上我们坚持用 `Logger`，只在脚本和启动阶段用 Sugared。第二，生产环境一定要开 Sampling，否则下游一次故障触发的错误风暴能把 ES 打爆，`Initial`/`Thereafter` 按服务实际 QPS 调。第三，严禁把 AppSecret、RSA 私钥、Authorization 头原样打出来。统一认证中心 里我们写了脱敏 hook，对 `password`、`secret`、`token` 字段统一 mask。第四，Filebeat 采集比应用直连 ES 稳妥，Pod 重启也不丢缓冲日志，但要给 Filebeat 配 multiline 合并 panic 堆栈。第五，日志级别用 `zap.AtomicLevel` 配合配置中心动态调整，线上出问题时临时把某个服务调到 DEBUG，不用发版。

## 小结

结构化日志不是换个日志库那么简单，关键是字段规范（trace_id、error、latency、biz_code）和上下游透传。Zap 解决"打什么、怎么打"，ELK 解决"去哪查"。这套体系搭好后，统一认证中心 跨服务的登录排障从几十分钟缩到了分钟级。
