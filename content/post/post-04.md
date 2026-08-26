---
title: "Go channels 在用户行为异步上报中的应用与踩坑"
slug: "post-04"
date: 2023-10-23T10:30:00+08:00
draft: false
tags: ["channel","goroutine","异步"]
categories: ["Go"]
description: "用 buffered channel 做用户行为异步上报的设计、背压处理与 panic 恢复"
---

## 问题背景

经营数据分析平台数据分析平台需要采集医生在 Web 端的行为埋点：页面停留、功能点击、病历查看等。最开始埋点接口是同步写库，结果高峰期数据库连接被打满，而且埋点写入失败还会影响主业务接口的响应。业务方对埋点的实时性要求不高（分钟级延迟可接受），但要求主链路绝对不能被拖慢。

我决定用 buffered channel + 后台 worker 做异步上报。

## 方案/设计

整体结构很简单：HTTP handler 把埋点事件扔进一个 buffered channel，立即返回 200；后台启动一组 worker goroutine 从 channel 消费，批量写入数据库。核心是 channel 的容量和 worker 数量要根据吞吐能力调整，我们初始设了 10000 缓冲、10 个 worker。

```go
type Event struct {
    UserID    int64
    Action    string
    Page      string
    Timestamp time.Time
    Extra     map[string]interface{}
}

type Reporter struct {
    ch     chan *Event
    db     *gorm.DB
    worker int
}

func NewReporter(db *gorm.DB, bufSize, worker int) *Reporter {
    r := &Reporter{
        ch:     make(chan *Event, bufSize),
        db:     db,
        worker: worker,
    }
    for i := 0; i < worker; i++ {
        go r.consume(i)
    }
    return r
}

func (r *Reporter) Report(e *Event) {
    select {
    case r.ch <- e:
    default:
        // channel 满了直接丢弃，避免阻塞主链路
        log.Printf("event dropped, channel full: %s", e.Action)
    }
}
```

关键在 `Report` 方法用了 `select + default`：channel 满了直接丢弃事件而不是阻塞。埋点数据丢几条不影响业务，但主接口卡住就是事故。

worker 批量消费，攒满 100 条或 200ms 超时就刷一次库：

```go
func (r *Reporter) consume(workerID int) {
    batch := make([]*Event, 0, 100)
    ticker := time.NewTicker(200 * time.Millisecond)
    defer ticker.Stop()

    flush := func() {
        if len(batch) == 0 {
            return
        }
        // 每个 worker 独立恢复 panic，避免一个崩溃全停
        defer func() {
            if rec := recover(); rec != nil {
                log.Printf("worker %d panic: %v", workerID, rec)
                batch = batch[:0]
            }
        }()
        if err := r.db.Table("user_event").Create(&batch).Error; err != nil {
            log.Printf("batch insert failed: %v", err)
        }
        batch = batch[:0]
    }

    for {
        select {
        case e := <-r.ch:
            batch = append(batch, e)
            if len(batch) >= 100 {
                flush()
            }
        case <-ticker.C:
            flush()
        }
    }
}
```

## 踩坑/权衡

第一个坑是 goroutine panic 导致 worker 静默退出。最初没有在 consume 里加 recover，一次空指针就让某个 worker 挂了，channel 消费速度下降但没有任何告警，缓冲慢慢堆满后事件全部被丢弃。现在每个 worker 的 flush 都有独立 recover，而且加了一个监控：channel 长度超过容量 80% 就报警。

第二个坑是优雅关闭。服务重启时 channel 里可能还有未消费的事件，直接退出会丢数据。我加了一个 `Close` 方法，先关闭 channel 触发 worker 把剩余数据刷完，再用 `sync.WaitGroup` 等待所有 worker 退出，最多等 5 秒：

```go
func (r *Reporter) Close() {
    close(r.ch)
    done := make(chan struct{})
    go func() {
        r.wg.Wait()
        close(done)
    }()
    select {
    case <-done:
    case <-time.After(5 * time.Second):
        log.Println("reporter close timeout")
    }
}
```

注意：channel 关闭后 worker 还能从已关闭的 channel 读出剩余数据，读完会进入零值循环，需要在 consume 的 for 里用 `e, ok := <-r.ch` 判断 ok 为 false 时退出。这个细节我第一次写的时候漏了，worker 会永远卡在零值事件上。

第三个是背压策略的选择。用 `default` 丢弃是最简单的背压，但也可以在 channel 满时降级写本地文件，后续补传。我们评估后觉得埋点允许少量丢失，没做文件补传，但在监控里把丢弃数做成了指标。

## 小结

buffered channel 做异步上报是 Go 里很朴素的方案，但"简单"不等于"随便写"。非阻塞发送、批量写入、panic 恢复、优雅关闭、channel 水位监控，这五样缺一不可。这套模式后来也被我复用到了操作日志和通知推送场景。
