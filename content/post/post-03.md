---
title: "基于 Jaeger 的全链路追踪：从 gRPC 到 HTTP 的上下文透传"
slug: "post-03"
date: 2023-10-07T10:30:00+08:00
draft: false
tags: ["Jaeger","链路追踪","OpenTracing"]
categories: ["可观测性"]
description: "宠物医疗 SaaS 系统微服务中 Jaeger 链路追踪的接入与跨协议上下文透传实践"
---

## 问题背景

宠物医疗 SaaS 系统拆成微服务后，排查一次挂号请求要跨 API 网关、clinic-rpc、payment-rpc、inventory-rpc 四个服务。最开始出了问题只能靠日志拼时间线，每个服务打印自己的 requestId，但请求经过 gRPC 调用后 requestId 就断了，根本串不起来。一次"挂号后扣费失败"的线上问题，三个工程师对着日志查了两个小时才定位到是 inventory-rpc 超时导致的回滚失败。

我们必须上全链路追踪，选型用了 Jaeger，因为它兼容 OpenTracing 标准，go-zero 也有内置支持。

## 方案/设计

核心思路是在入口层生成 traceId，然后通过 HTTP Header 和 gRPC metadata 一路透传下去，每个服务在处理请求时从 context 里取出 SpanContext，创建子 Span 上报给 Jaeger Agent。

go-zero 自带了 `trace` 包，在 API 层配置一个 Jaeger 上报地址即可自动注入：

```yaml
# api/etc/clinic-api.yaml
Name: clinic-api
Host: 0.0.0.0
Port: 8888
Telemetry:
  Name: clinic-api
  Endpoint: http://jaeger-agent:14268/api/traces
  Sampler: 1.0
  Batcher: jaeger
```

但 go-zero 内置的 trace 只覆盖了它自己生成的 gRPC 客户端，对于我们直接用 `grpc.Dial` 创建的连接，需要手动加拦截器。服务端拦截器负责从 incoming context 提取 SpanContext 并创建服务端 Span：

```go
func UnaryServerInterceptor(tracer opentracing.Tracer) grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req interface{},
        info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {

        md, ok := metadata.FromIncomingContext(ctx)
        var spanCtx opentracing.SpanContext
        if ok {
            // 从 gRPC metadata 的 uber-trace-id 提取
            if carriers, ok := md["uber-trace-id"]; ok && len(carriers) > 0 {
                textMap := opentracing.TextMapCarrier{"uber-trace-id": carriers[0]}
                spanCtx, _ = tracer.Extract(opentracing.TextMap, textMap)
            }
        }

        span := tracer.StartSpan(
            info.FullMethod,
            ext.RPCServerOption(spanCtx),
        )
        defer span.Finish()

        ctx = opentracing.ContextWithSpan(ctx, span)
        resp, err := handler(ctx, req)
        if err != nil {
            ext.Error.Set(span, true)
            span.LogKV("event", "error", "message", err.Error())
        }
        return resp, err
    }
}
```

客户端拦截器则把当前 SpanContext 注入 outgoing metadata：

```go
func UnaryClientInterceptor(tracer opentracing.Tracer) grpc.UnaryClientInterceptor {
    return func(ctx context.Context, method string,
        req, reply interface{}, cc *grpc.ClientConn,
        invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {

        span, ctx := opentracing.StartSpanFromContext(ctx, method)
        defer span.Finish()

        md, _ := metadata.FromOutgoingContext(ctx)
        if md == nil {
            md = metadata.New(nil)
        }
        carrier := opentracing.TextMapCarrier{}
        _ = tracer.Inject(span.Context(), opentracing.TextMap, carrier)
        for k, v := range carrier {
            md.Set(k, v)
        }
        ctx = metadata.NewOutgoingContext(ctx, md)
        return invoker(ctx, method, req, reply, cc, opts...)
    }
}
```

HTTP 层我们在 Gin 网关加了一个中间件，从请求头取 `Uber-Trace-Id`，没有就新开根 Span：

```go
func TracingMiddleware(tracer opentracing.Tracer) gin.HandlerFunc {
    return func(c *gin.Context) {
        spanCtx, _ := tracer.Extract(
            opentracing.HTTPHeaders,
            opentracing.HTTPHeadersCarrier(c.Request.Header),
        )
        span := tracer.StartSpan(
            c.Request.URL.Path,
            ext.RPCServerOption(spanCtx),
        )
        defer span.Finish()

        ctx := opentracing.ContextWithSpan(c.Request.Context(), span)
        c.Request = c.Request.WithContext(ctx)
        c.Next()
    }
}
```

## 踩坑/权衡

第一个坑是跨异步 goroutine 的 context 丢失。有些逻辑起 goroutine 异步处理，直接用了 `context.Background()`，Span 链就断了。我们的规矩是异步任务必须从父 context 派生，但要做 detach——不能直接用父 ctx，因为父 ctx 在 HTTP 返回后会被 cancel。我封装了一个 `detachContext`，只保留 trace 信息、不继承 cancel 信号。

第二个是采样率。生产环境 100% 采样会给 Jaeger 后端和网络带来不小压力，我们改成 10% 采样，错误请求强制 100% 采样（在拦截器里判断 err != nil 时设置 `sampling.priority=1`）。

第三个是 B3 和 Jaeger 原生头的兼容。老版本 Istio sidecar 用的是 B3 头（`X-B3-TraceId`），我们应用层用的是 `uber-trace-id`，两边串不起来。统一改成 `W3C TraceContext`（`traceparent` 头）后解决了这个问题，也是未来的标准方向。

## 小结

全链路追踪的价值不在平时，而在故障时——它把跨服务的黑盒变成了可观测的调用链。关键是 context 透传不能有断点：HTTP 入口、gRPC 双向、异步 goroutine 都要覆盖。踩过这些坑后，宠物医疗 SaaS 系统排查一次跨服务故障的平均时间从小时级降到了分钟级。
