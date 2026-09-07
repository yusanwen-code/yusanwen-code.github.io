---
title: "OpenAlex 学术数据同步：增量拉取与去重设计"
slug: "post-29"
date: 2024-11-16T10:30:00+08:00
draft: false
image: /images/post-29-cover.jpg
tags: ["OpenAlex","数据同步","去重"]
categories: ["数据"]
description: "基于游标的增量拉取与 OpenAlex ID 去重实践"
---

## 2.5 亿条 Works，全量拉不动

我们在数据治理平台里需要把 OpenAlex 的学术数据（Works、Authors、Institutions 这些）同步到本地 MySQL，再通过 StarRocks 外表做多维分析。OpenAlex 的全量 Works 超过 2.5 亿条，每次全量拉，不仅耗时巨大，还频繁触发对方的限流。

所以诉求很明确：增量拉取，而且重复运行不能留脏数据。

## 游标、状态表，再加一个天然主键

方案拆开就三件事。

第一，增量靠游标分页加日期过滤。OpenAlex 支持 `filter=from_publication_date` 和 `cursor` 游标分页，天然适合增量：每次从上次记下的游标继续，不用从头翻页。

第二，断点靠一张 `sync_state` 表。每个实体记最后游标、最后同步日期和更新时间，任务中断了能接着跑。

第三，去重靠 OpenAlex 自己的 ID。每条记录都有全局唯一 ID（`W123456` 这种），直接拿来当业务主键，冲突就更新，不做插入。

同步任务跑在 Temporal Worker 上，单页失败自动重试，整个流程可观测、可恢复。

![OpenAlex 增量同步的整体链路](/images/post-29-openalex-sync.svg)

## 请求就一个 GET

请求封装很薄，值得注意的是带上了 `mailto`，后面会讲为什么：

```go
type OpenAlexClient struct {
    baseURL string
    email   string // 加入 polite pool
    client  *http.Client
}

type WorksResponse struct {
    Meta struct {
        Count      int    `json:"count"`
        NextCursor string `json:"next_cursor"`
    } `json:"meta"`
    Results []Work `json:"results"`
}

func (c *OpenAlexClient) FetchWorksPage(ctx context.Context, cursor, fromDate string) (*WorksResponse, error) {
    u := fmt.Sprintf("%s/works?filter=from_publication_date:%s&per_page=200&cursor=%s&mailto=%s",
        c.baseURL, fromDate, url.QueryEscape(cursor), c.email)

    req, err := http.NewRequestWithContext(ctx, "GET", u, nil)
    if err != nil {
        return nil, err
    }
    resp, err := c.client.Do(req)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()

    var result WorksResponse
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return nil, err
    }
    return &result, nil
}
```

## 冲突就更新，别插入

去重写入用 GORM 的 `OnConflict` 子句，按 `openalex_id` 冲突时更新所有字段：

```go
func (r *WorkRepo) UpsertBatch(ctx context.Context, works []Work) error {
    if len(works) == 0 {
        return nil
    }
    return r.db.WithContext(ctx).
        Clauses(clause.OnConflict{
            Columns:   []clause.Column{{Name: "openalex_id"}},
            UpdateAll: true,
        }).
        CreateInBatches(&works, 200).Error
}
```

## 主循环：翻页、落库、记游标

同步主循环从状态表读游标，逐页拉取并落库，最后更新游标：

```go
func (s *Syncer) SyncWorks(ctx context.Context) error {
    state, _ := s.stateRepo.Get(ctx, "works")
    cursor := state.Cursor
    if cursor == "" {
        cursor = "*"
    }

    for {
        page, err := s.client.FetchWorksPage(ctx, cursor, state.LastDate)
        if err != nil {
            return err // Temporal 会重试
        }
        if err := s.workRepo.UpsertBatch(ctx, page.Results); err != nil {
            return err
        }
        if page.Meta.NextCursor == "" {
            break
        }
        cursor = page.Meta.NextCursor
        _ = s.stateRepo.UpdateCursor(ctx, "works", cursor)
    }
    return nil
}
```

## 四个坑

游标不是永久有效的。间隔过久再拿同一个游标去请求，可能直接报错。我们的做法是每次同步完成后检查：如果游标已过期，就回退到按日期重新拉最近 7 天的数据，靠 Upsert 兜底去重。

per_page 最大 200。一开始设的 100，翻页次数多了一倍；调到 200 之后整体耗时明显下降，代价是单次响应体变大，HTTP client 的超时要设置得合理一些。

限流和 politeness 直接挂钩。请求里带上 `mailto` 参数就能进 Polite Pool，限流明显宽松：不加的话大约 10 请求/秒就可能被 429，加了之后基本能跑到 20 以上。一行参数的事，没理由不加。

MySQL 写完还要进 StarRocks。我们用 Routine Load 订阅 Binlog 做同步，避免双写。偶尔 DDL 变更会把 Routine Load 暂停掉，这个只能靠监控告警兜着，不然数据就悄悄断流了。

## 后来

这套方案上线后稳定跑了几个月，没出过数据重复或丢失。回头看没有什么高深的地方：游标管"从哪继续"，ID 当主键管"重复了怎么办"，失败重试交给 Temporal。都是笨办法，拼在一起反而省心。

> 封面图：[BinaryApe / Flickr](https://www.flickr.com/photos/93001633@N00/4882162452) · CC BY 2.0
