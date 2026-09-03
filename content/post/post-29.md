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

## 问题背景

在数据治理服务数据治理平台中，我们需要将 OpenAlex 的学术数据（Works、Authors、Institutions 等）同步到本地 MySQL，再通过 StarRocks 外表做多维分析。OpenAlex 全量 Works 数据超过 2.5 亿条，如果每次全量拉取，不仅耗时巨大，还会频繁触发对方的限流策略。我们需要一套可靠的增量同步方案，同时保证重复运行不会产生脏数据。

## 方案设计

核心思路有三点：

1. **游标分页 + 日期过滤**：OpenAlex 支持 `filter=from_publication_date` 和 `cursor` 游标分页，天然适合增量拉取。每次从上次记录的游标继续，而不是重新翻页。
2. **同步状态表**：用一张 `sync_state` 表记录每个实体的最后游标、最后同步日期和更新时间，支持断点续传。
3. **以 OpenAlex ID 为主键的 Upsert 去重**：OpenAlex 每条记录都有全局唯一 ID（如 `W123456`），直接作为业务主键，冲突时更新而非插入。

同步任务跑在 Temporal Worker 上，单页失败自动重试，整个流程可观测、可恢复。

## 关键代码

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

同步主循环从状态表读取游标，逐页拉取并落库，最后更新游标：

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

## 踩坑与权衡

- **游标有效期**：OpenAlex 的游标不是永久有效的，间隔过久再用同一个游标可能报错。我们的做法是每次同步完成后，如果游标已过期，就回退到按日期重新拉取最近 7 天的数据，靠 Upsert 兜底去重。
- **每页数量**：`per_page` 最大 200。一开始试过 100，翻页次数多了一倍；调到 200 后整体耗时明显下降，但单次响应体也更大，需要确保 HTTP client 超时设置合理。
- **Polite Pool**：加上 `mailto` 参数后限流明显宽松。不加的话大约 10 请求/秒就可能被 429，加了之后基本能跑到 20 以上。
- **StarRocks 同步**：MySQL 写完后通过 Routine Load 订阅 Binlog 同步到 StarRocks，避免双写。偶尔遇到 DDL 变更导致 Routine Load 暂停，需要加监控告警。

## 小结

增量同步的本质是"用状态换取重复劳动"。OpenAlex 提供的游标和日期过滤机制让增量拉取变得简单，而以业务唯一 ID 做 Upsert 则保证了幂等性。配合 Temporal 的重试和状态持久化，整个同步流程稳定跑了数月，没有出现过数据重复或丢失。

> 封面图：[BinaryApe / Flickr](https://www.flickr.com/photos/93001633@N00/4882162452) · CC BY 2.0
