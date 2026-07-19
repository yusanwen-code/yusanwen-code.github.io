---
title: "线上问题排查方法论：从日志、链路到监控"
date: 2026-07-19T10:30:00+08:00
draft: false
tags: ["排障","日志","监控"]
categories: ["可观测性"]
description: "从宠物医疗 SaaS 系统到 AI 数据平台，我总结的线上排障三步法。"
---

## 问题背景

做后端这些年，线上问题排查花掉的时间不比写新功能少。在某 SaaS 公司时，宠物医疗 SaaS 系统从 fasthttp C/S 迁到 go-zero B/S 后，微服务多了，一个"医生开不了处方"的报错可能横跨网关、鉴权、处方、HIS 对接四五个服务。到了公司做 AI 数据平台，知识库问答服务 和 数据集管理服务 又多了 LLM 调用、向量化、Temporal Worker 这些新组件，问题形态更杂。

我踩过足够多的坑之后，形成了一套固定的排障顺序：先看监控定边界，再查链路定位置，最后翻日志看细节。顺序反了，就是在大海里捞针。

## 方案与设计

**第一步，监控定边界。** 告警来了先别急着登机器，先在 Grafana 上回答三个问题：影响面多大（单用户还是全量）、从什么时候开始（发版后还是突发）、哪个指标异常（错误率、延迟、CPU、内存、队列堆积）。

我们在 KubeSphere 上给每个服务配了 RED 指标（Rate、Errors、Duration），业务侧再加关键看板：统一支付平台 看支付成功率和回调延迟，统一认证中心 看登录失败率和各 Provider（腾讯云 SMS/SES）的错误码分布，知识库问答服务 看首 token 延迟和各 LLM 供应商的超时率。一张 dashboard 能把"是不是我的问题、是我的问题大概在哪"先筛掉八成。

**第二步，链路定位置。** 确定是某个服务的问题后，用 trace_id 把整条请求链拉出来。我们在 go-zero 和 Hertz 里都接了 gRPC 拦截器和 HTTP middleware，把 trace_id 从入口一路透传到下游、MQ 消费者、Temporal Workflow。

```go
// Hertz 中统一的 trace + 日志中间件
func AccessLog() app.HandlerFunc {
    return func(ctx context.Context, c *app.RequestContext) {
        traceID := string(c.Request.Header.Get("X-Trace-Id"))
        if traceID == "" {
            traceID = snowflake.NextString()
            c.Request.Header.Set("X-Trace-Id", traceID)
        }
        c.Response.Header.Set("X-Trace-Id", traceID)

        start := time.Now()
        c.Next(ctx)

        log.Info("http access",
            zap.String("trace_id", traceID),
            zap.String("method", string(c.Method())),
            zap.String("path", string(c.Path())),
            zap.Int("status", c.Response.StatusCode()),
            zap.Duration("cost", time.Since(start)),
        )
    }
}
```

拿到 trace_id 后去 Jaeger 看瀑布图，一眼能看出是哪个 span 慢、哪个 span 报错。AI 场景里我特意把对 LLM 的调用、向量检索、S3 上传都包成独立 span，不然一个"回答超时"你根本分不清是模型慢还是检索慢。

**第三步，日志看细节。** trace 定位到具体服务和时段后，去 ELK 用 `trace_id: "xxx"` 精确捞日志。我们的日志规范是：顶层打印请求入参和最终错误，中间层只追加上下文不重复打错误，错误用 `zap.Error(err)` 带堆栈。一条合格的错误日志应该能直接回答"什么操作、什么入参、为什么失败"。

## 踩坑与权衡

**第一，日志别瞎打。** 早期有人在循环里打全量文档内容，一次解析任务日志几百 MB，ELK 直接被打爆。后来定了规矩：DEBUG 级别打细节，生产默认 INFO；大对象只打 ID 和长度；敏感字段（手机号、密钥）一律脱敏，统一认证中心 里这是红线。

**第二，告警要可收敛。** 每个错误都告警等于没有告警。我们按服务 + 错误类型聚合，5 分钟内同类错误只发一条，再配一个升级策略：错误率超过阈值且持续 10 分钟，才打电话。夜间告警质量直接决定你能不能睡个整觉。

**第三，异步任务的 trace 要手动续上。** MQ 消费者和 Temporal Workflow 是新的执行上下文，trace_id 不会自动传过去，必须在生产端塞进消息体、消费端取出来注入 context。这块漏了，异步链路就是断的，排障时最痛苦。

**第四，回滚优先于根因。** KubeSphere 容器化部署后回滚在 5 分钟内，发现是发版引起的问题，第一反应应该是回滚而不是在线上 debug。业务恢复之后再慢慢查根因，顺序不能反。

## 小结

排障能力的本质不是"见过的错误多"，而是有一套不依赖运气的检索路径。监控告诉你"哪里不对"，链路告诉你"在哪一步不对"，日志告诉你"具体为什么不对"。把这三件事在平时建设好，告警响的时候才不会慌。工具是基础设施，方法论才是让你比别人快十分钟定位问题的关键。
