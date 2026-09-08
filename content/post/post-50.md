---
title: "用 Zap + ELK 构建 Go 服务结构化日志体系"
slug: "post-50"
date: 2025-10-11T10:30:00+08:00
draft: false
image: /images/post-50-cover.jpg
tags: ["Zap", "ELK", "日志"]
categories: ["可观测性"]
description: "在统一认证中心、统一支付平台等多服务里用 Zap + ELK 落地结构化日志的实践"
---

## 一个请求，几十个 Pod

我之前主导过几个 Go 服务：统一认证中心、统一支付平台、知识库问答服务。早期都用标准 `log` 包打文本日志，服务之间走 gRPC，一个请求出了问题，就要在几十个 Pod 的日志里来回 grep，trace_id 还经常对不上，排障体验很差。

后来我们下决心，统一到 Zap 加 ELK 的结构化日志体系。

## 一条日志的旅程

大方向是这样的：Zap 用 `NewProduction` 的 JSON Encoder 出结构化日志，统一写 stdout；Filebeat 负责采集，交给 Logstash 清洗后写入 Elasticsearch；查问题的时候，在 Kibana 里按 trace_id 聚合查询。

trace_id、request_id、tenant_id 这些字段通过 `context.Context` 注入。Gin 中间件在 HTTP 入口生成或透传 trace_id，gRPC 拦截器从 metadata 里取出来挂到 logger 上，跨了进程也不丢。

![一条日志的旅程：trace_id 透传与 ELK 管道](/images/post-50-elk-pipeline.svg)

知识库问答服务的流式接口还多打了一个会话 ID 字段，要复现某一轮对话，拿 ID 直接过滤就行。

## Logger 初始化

生产和开发两套配置，生产开采样：

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

## trace_id 从哪来

Gin 中间件把 trace_id 塞进 context，顺手打一条访问日志：

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

gRPC 服务端拦截器从 metadata 透传 trace_id，保证跨进程能串起来，实现思路和上面类似，不展开了。

## 五个坑

第一个是 logger 选型。`SugaredLogger` 比强类型 `Logger` 慢约三成，知识库问答服务流式输出这种热路径上我们坚持用 `Logger`，只在脚本和启动阶段用 Sugared。

第二，生产环境一定要开 Sampling。有点反直觉，日志系统自己也会被日志打垮：下游一次故障触发的错误风暴，足以把 ES 打爆。`Initial` 和 `Thereafter` 按服务实际 QPS 调。

第三，脱敏是红线。AppSecret、RSA 私钥、Authorization 头，严禁原样打出来。统一认证中心里我们写了脱敏 hook，对 `password`、`secret`、`token` 这几个字段统一 mask。

第四，采集链路用 Filebeat，别让应用直连 ES，Pod 重启也不丢缓冲日志，稳得多。要记得配 multiline，把 panic 堆栈合并成一条。

第五，日志级别要能动态调。`zap.AtomicLevel` 配合配置中心，线上出问题时临时把某个服务调到 DEBUG，不用发版。

## 后来

这套体系搭好之后，最直观的变化是排障速度：统一认证中心跨服务的登录问题，从几十分钟缩到了分钟级。回头看，结构化日志的难点不在换个日志库，而在两件事：字段规范（trace_id、error、latency、biz_code）和上下游透传。简单说，Zap 决定"打什么、怎么打"，ELK 解决"去哪查"。

> 封面图：[dfulmer / Flickr](https://www.flickr.com/photos/28376044@N00/4350618884) · CC BY 2.0
