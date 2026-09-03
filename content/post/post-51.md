---
title: "Jaeger 在微服务排障中的真实案例"
slug: "post-51"
date: 2025-10-26T10:30:00+08:00
draft: false
image: /images/post-51-cover.jpg
tags: ["Jaeger", "排障", "链路追踪"]
categories: ["可观测性"]
description: "宠物医疗 SaaS 系统 go-zero 微服务里，用 Jaeger 定位一次 5 秒卡顿的真实过程"
---

## 问题背景

在某 SaaS 公司时期，我们把宠物医疗 SaaS 系统从 fasthttp C/S 架构迁到 go-zero B/S，服务拆成了十多个 gRPC 微服务，并接了 Jaeger 做分布式链路追踪。上线后医院端反馈"病历保存偶尔要 5 秒以上"，但日志分散在各个服务里，光看 Nginx access log 根本判断不出卡在哪一跳。这个问题在高峰期尤其明显，又无法稳定复现。

## 方案设计

我们用 OpenTelemetry SDK 统一埋点，gRPC unary interceptor 在服务端自动创建 span，客户端拦截器透传 trace context。Jaeger Collector 收 span 后写入 ES 后端，在 Jaeger UI 里按 operation 和耗时过滤。关键是把 DB 查询、Redis 调用、外部 AI 影像判读接口都包成子 span，这样瀑布图才能真实反映每一跳耗时。

## 关键代码

初始化 TracerProvider：

```go
func InitTracer(ctx context.Context, serviceName, endpoint string) (*sdktrace.TracerProvider, error) {
    conn, err := grpc.DialContext(ctx, endpoint,
        grpc.WithTransportCredentials(insecure.NewCredentials()),
    )
    if err != nil {
        return nil, err
    }
    exp, err := otlptracegrpc.New(ctx, otlptracegrpc.WithGRPCConn(conn))
    if err != nil {
        return nil, err
    }
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exp),
        sdktrace.WithResource(resource.NewWithAttributes(
            semconv.SchemaURL,
            semconv.ServiceName(serviceName),
        )),
        sdktrace.WithSampler(
            sdktrace.ParentBased(sdktrace.TraceIDRatioBased(0.1)),
        ),
    )
    otel.SetTracerProvider(tp)
    return tp, nil
}
```

gRPC 服务端拦截器：

```go
func TracingInterceptor(ctx context.Context, req any,
    info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
    tracer := otel.Tracer("grpc-server")
    ctx, span := tracer.Start(ctx, info.FullMethod)
    defer span.End()
    resp, err := handler(ctx, req)
    if err != nil {
        span.RecordError(err)
        span.SetStatus(codes.Error, err.Error())
    }
    return resp, err
}
```

把 GORM 查询也挂上 span：

```go
ctx, span := tracer.Start(ctx, "db.patient.save")
defer span.End()
err := db.WithContext(ctx).Create(&patient).Error
```

## 踩坑与权衡

那次"5 秒卡顿"，我们在 Jaeger UI 里用 `minDuration=3s` 过滤，一眼看到根因：病历保存链路会同步调用 AI 影像判读服务，该服务冷启动时加载模型耗时 4 秒多，而前端是同步等待结果。我们把 AI 调用改成异步落库加回调通知，P99 立刻降到几百毫秒。

其他踩过的坑：第一，采样率不要一刀切。登录、支付这种核心链路我用 100% 采样（通过 span attribute 标记），普通查询 10%，否则 Jaeger 后端扛不住。第二，context 透传是重灾区。go-zero 里有些自定义 goroutine 没把 ctx 传进去，trace 直接断链。我们规定所有异步任务必须显式接 context，跨 Kafka/RabbitMQ 时用 `otel.GetTextMapPropagator().Inject` 把 carrier 塞进消息 header。第三，span 不是越多越好，一个 for 循环里每条 SQL 都开 span 会让 UI 卡死，批量操作只开一个聚合 span。第四，不要把大对象塞进 span attribute，请求体只记摘要和 ID，否则 Jaeger 查询本身会很慢。

## 小结

链路追踪的价值不在"接了"，而在用它解决具体问题。那次 AI 冷启动排查之后我养成习惯：任何一次跨服务慢请求，先开 Jaeger 看瀑布图，而不是翻日志。Trace 是微服务时代的调试器，没有它，十多个 gRPC 服务之间的调用就是一个黑盒。

> 封面图：[somegeekintn / Flickr](https://www.flickr.com/photos/66335021@N00/3709203268) · CC BY 2.0
