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

## 病历保存偶尔要 5 秒

在某 SaaS 公司时期，我们把宠物医疗 SaaS 系统从 fasthttp C/S 架构迁到 go-zero B/S，服务拆成了十多个 gRPC 微服务，接了 Jaeger 做分布式链路追踪。

上线后医院端反馈：病历保存偶尔要 5 秒以上。高峰期尤其明显，又无法稳定复现。日志分散在各个服务里，光看 Nginx access log，根本判断不出卡在哪一跳。

## 每一跳都留 span

埋点用 OpenTelemetry SDK 统一做。gRPC unary interceptor 在服务端自动创建 span，客户端拦截器负责透传 trace context；Jaeger Collector 收 span 后写入 ES 后端，在 Jaeger UI 里按 operation 和耗时过滤。

关键一步是把 DB 查询、Redis 调用、外部 AI 影像判读接口都包成子 span，瀑布图才能真实反映每一跳的耗时。

## 埋点代码

初始化 TracerProvider，采样率先设 10%：

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

gRPC 服务端拦截器，出错时记进 span：

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

DB 查询也挂上 span，这样瀑布图里能看到每一次落库：

```go
ctx, span := tracer.Start(ctx, "db.patient.save")
defer span.End()
err := db.WithContext(ctx).Create(&patient).Error
```

## minDuration=3s，根因一眼可见

那次 5 秒卡顿，我们在 Jaeger UI 里用 `minDuration=3s` 过滤，把所有超过 3 秒的 trace 捞出来，根因基本就摆在瀑布图上了。

![病历保存链路的 span 瀑布：AI 判读冷启动吃掉 4 秒](/images/post-51-jaeger-waterfall.svg)

病历保存链路会同步调用 AI 影像判读服务，这个服务冷启动时加载模型要 4 秒多，而前端在同步等结果。改法是把 AI 调用改成异步落库加回调通知，改完 P99 立刻降到几百毫秒。

## 其他几个坑

第一，采样率不要一刀切。登录、支付这种核心链路我用 100% 采样（通过 span attribute 标记），普通查询 10%，不然 Jaeger 后端扛不住。

第二，context 透传是重灾区。go-zero 里有些自定义 goroutine 没把 ctx 传进去，trace 直接断链。我们规定所有异步任务必须显式接 context；跨 Kafka/RabbitMQ 时，用 `otel.GetTextMapPropagator().Inject` 把 carrier 塞进消息 header。

第三，span 不是越多越好。一个 for 循环里每条 SQL 都开 span，UI 会卡死，批量操作只开一个聚合 span。

第四，别把大对象塞进 span attribute，请求体只记摘要和 ID，不然 Jaeger 查询本身会很慢。

## 后来

那次排查之后我养成一个习惯：任何一次跨服务的慢请求，先开 Jaeger 看瀑布图，而不是翻日志。链路追踪的价值不在"接了"，而在用它解决具体问题。Trace 就是微服务时代的调试器，没有它，十多个 gRPC 服务之间的调用就是一个黑盒。

> 封面图：[somegeekintn / Flickr](https://www.flickr.com/photos/66335021@N00/3709203268) · CC BY 2.0
