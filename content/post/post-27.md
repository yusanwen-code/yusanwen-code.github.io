---
title: "基于 Temporal Worker 的数据质量规则引擎与自动检查"
slug: "post-27"
date: 2024-10-16T10:30:00+08:00
draft: false
image: /images/post-27-cover.jpg
tags: ["Temporal","规则引擎","数据质量"]
categories: ["数据"]
description: "用 Temporal 编排可配置的数据质量检查工作流"
---

## 规则越加越多，if-else 写不动了

入库的论文元数据要跑一串质量检查：DOI 格式合不合法、作者机构是不是空的、摘要长度够不够、引用关系完不完整、字段间有没有矛盾（比如发表年份晚于当前年份）。麻烦在于规则会不断增加，不同数据源的严格程度还不一样，硬编码 if-else 显然撑不了多久。

我们把规则抽成配置，用 Temporal 编排执行。选 Temporal 而不是普通异步任务框架，是因为质量检查可能一跑几分钟到几十分钟（涉及 StarRocks 大表聚合），需要可靠的重试、超时、状态持久化和人工介入。Temporal 天生擅长这种长事务工作流。

## 规则进配置，检查进 Workflow

规则定义存在 quality_rules 表：规则编码、名称、类型（not_null/regex/sql/custom）、参数（正则、阈值、SQL 模板）、严重级别（error/warning/info）、适用数据源。

每个数据集入库后启动一个 Temporal Workflow，流程是这样的：

1. 加载该数据集启用的规则列表；
2. 用 Activity 并行执行各类检查：SQL 类规则下发到 StarRocks，正则类在 Worker 内存跑；
3. 收集结果。error 级别阻断发布，warning 记录但放行；
4. 生成质量报告，通知数据负责人；
5. 如果有 error，Workflow 挂起等待人工修复或豁免信号，收到信号再继续。

Activity 是幂等的：以 dataset_id + rule_code 作为幂等键，结果写 quality_results 表，重跑时已通过的规则直接跳过。

![Temporal 质量检查工作流：并行检查、结果分级、人工信号](/images/post-27-quality-workflow.svg)

## Workflow 与 Activity

Workflow：

```go
func QualityCheckWorkflow(ctx workflow.Context, datasetID int64) error {
    var rules []QualityRule
    if err := workflow.ExecuteActivity(ctx, LoadRulesActivity, datasetID).Get(ctx, &rules); err != nil {
        return err
    }

    // 并行执行所有规则
    futures := make(map[string]workflow.Future)
    for _, r := range rules {
        r := r
        ao := workflow.ActivityOptions{
            StartToCloseTimeout: 10 * time.Minute,
            RetryPolicy: &temporal.RetryPolicy{
                InitialInterval:    5 * time.Second,
                BackoffCoefficient: 2.0,
                MaximumAttempts:    3,
            },
        }
        ctx1 := workflow.WithActivityOptions(ctx, ao)
        futures[r.Code] = workflow.ExecuteActivity(ctx1, RunRuleActivity, datasetID, r)
    }

    var hasError bool
    for code, f := range futures {
        var result RuleResult
        if err := f.Get(ctx, &result); err != nil {
            workflow.GetLogger(ctx).Error("rule failed", "code", code, "err", err)
            hasError = true
            continue
        }
        if result.Severity == "error" && !result.Passed {
            hasError = true
        }
    }

    _ = workflow.ExecuteActivity(ctx, SaveReportActivity, datasetID).Get(ctx, nil)

    if hasError {
        // 等待人工修复或豁免信号
        var signal SignalData
        ch := workflow.GetSignalChannel(ctx, "quality-resolve")
        ch.Receive(ctx, &signal)
        if signal.Action != "exempt" {
            // 非豁免，重新跑检查
            return workflow.NewContinueAsNewError(ctx, QualityCheckWorkflow, datasetID)
        }
    }
    return workflow.ExecuteActivity(ctx, PublishDatasetActivity, datasetID).Get(ctx, nil)
}
```

Activity 中 SQL 类规则执行：

```go
func RunRuleActivity(ctx context.Context, datasetID int64, r QualityRule) (RuleResult, error) {
    result := RuleResult{RuleCode: r.Code, Severity: r.Severity}
    switch r.Type {
    case "sql":
        var cnt int64
        query := renderSQL(r.Params.SQL, datasetID)
        // starrocksDB 是独立的 *sql.DB
        if err := starrocksDB.QueryRowContext(ctx, query).Scan(&cnt); err != nil {
            return result, err
        }
        result.Passed = cnt == 0
        result.Message = fmt.Sprintf("violation rows: %d", cnt)
    case "regex":
        // 在内存拉取样本校验，略
    }
    saveResult(datasetID, result)
    return result, nil
}
```

## 五个坑

第一个是 Temporal 的默认重试。Activity 默认会无限重试，一定要自己配 RetryPolicy。我们的 SQL 检查可能因为 StarRocks 短暂不可用而失败，3 次指数退避足够；超过就标记失败让人工看，不能无限重试堆积。

第二个坑我印象很深：Workflow 里不能直接调 time.Sleep，也不能用 goroutine，必须用 workflow.Sleep 和 workflow.Go。我第一次写的时候在 Workflow 里用普通 for 循环查状态，重放时直接确定性错误，排查了很久。

规则配置还要支持灰度。我们加了规则的 enabled 开关和适用数据源范围，新规则先在 info 级别跑一周观察误报，再提升为 warning 或 error。不然一条误报多的新规则上线，一上来就阻断所有数据。

人工信号是 Temporal 的强项。数据负责人在内部页面点「豁免」，后端发 Signal 给 Workflow，流程继续往下走。比自己在 Redis 里轮询状态优雅多了。

最后一条很朴素：大表 SQL 检查不要在主 MySQL 上跑，全部路由到 StarRocks，别碰线上交易库。

## 后来

规则做成配置、检查交给 Temporal 编排之后，新增一条规则就是加一行配置和一个 Activity 分支，不用发版。持久化、重试、信号这些机制，让长耗时、要人工介入的检查流程变得可靠。数据治理这件事，也从「事后救火」挪到了「事前卡口」。

> 封面图：[jitze / Flickr](https://www.flickr.com/photos/40648743@N00/1849093841) · CC BY 2.0
