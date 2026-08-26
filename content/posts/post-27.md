---
title: "基于 Temporal Worker 的数据质量规则引擎与自动检查"
date: 2024-10-16T10:30:00+08:00
draft: false
tags: ["Temporal","规则引擎","数据质量"]
categories: ["数据"]
description: "用 Temporal 编排可配置的数据质量检查工作流"
---

## 问题背景

数据治理服务治理入库的论文元数据需要跑一系列质量检查：DOI 格式是否合法、作者机构是否为空、摘要长度是否达标、引用关系是否完整、字段间是否矛盾（比如发表年份晚于当前年份）。规则会不断增加，不同数据源的严格程度也不同，硬编码 if-else 显然不可持续。

我们把规则抽象成配置，用 Temporal 编排执行。选择 Temporal 而不是普通异步任务框架，是因为质量检查可能跑几分钟到几十分钟（涉及 StarRocks 大表聚合），需要可靠的重试、超时、状态持久化和人工介入能力，Temporal 天生擅长这种长事务工作流。

## 方案设计

规则定义存在 `quality_rules` 表：规则编码、名称、类型（not_null/regex/sql/custom）、参数（正则、阈值、SQL 模板）、严重级别（error/warning/info）、适用数据源。

每个数据集入库后启动一个 Temporal Workflow：
1. 加载该数据集启用的规则列表；
2. 用 Activity 并行执行各类检查，SQL 类规则下发到 StarRocks，正则类在 Worker 内存跑；
3. 收集结果，error 级别的阻断发布，warning 记录但允许通过；
4. 生成质量报告并通知数据负责人；
5. 如果有 error，Workflow 等待人工修复或豁免信号，收到信号后继续。

Activity 是幂等的：以 dataset_id + rule_code 作为幂等键，结果写 `quality_results` 表，重跑时已通过的规则可跳过。

## 关键代码

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

## 踩坑与权衡

- Temporal Activity 默认会无限重试，一定要配 RetryPolicy。我们的 SQL 检查可能因为 StarRocks 短暂不可用失败，3 次指数退避足够；超过就标记失败让人工看，而不是无限重试堆积。
- Workflow 里不能直接调 time.Sleep 或用 goroutine，必须用 workflow.Sleep 和 workflow.Go。我第一次写时在 Workflow 里用了普通 for 循环查状态，导致重放时确定性错误，排查了很久。
- 规则配置要支持灰度。我们加了规则的 enabled 开关和适用数据源范围，新规则先在 info 级别跑一周观察误报，再提升为 warning/error，避免一上线就阻断所有数据。
- 人工信号是 Temporal 的强项。数据负责人在内部页面点"豁免"，后端发 Signal 给 Workflow，Workflow 继续往下走，比自己在 Redis 里轮询状态优雅得多。
- 大表 SQL 检查不要在主 MySQL 上跑，全部路由到 StarRocks，避免影响线上交易库。

## 小结

把数据质量规则做成配置 + Temporal Workflow 编排后，新增一条规则就是加一行配置和一个 Activity 分支，不再需要发版。Temporal 的持久化、重试、信号机制让长耗时、需要人工介入的检查流程变得可靠，数据治理从"事后救火"变成了"事前卡口"。
