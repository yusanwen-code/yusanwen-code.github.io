---
title: "基于 Snowflake 的分布式 ID 生成与高并发数据一致性"
slug: "post-22"
date: 2024-07-30T10:30:00+08:00
draft: false
image: /images/post-22-cover.jpg
tags: ["Snowflake","分布式ID","高并发"]
categories: ["分布式"]
description: "在统一认证中心中落地 Snowflake 的工程实践与时钟回拨处理"
---

## 自增主键先撑不住

统一认证中心要给用户、应用、团队、授权记录这些实体发全局唯一 ID。早期直接用 MySQL 自增主键，问题很快暴露：分库分表之后，自增 ID 在不同分片之间会冲突；业务方希望 ID 自带时间信息，好排序；批量写入时，自增锁还是个热点。

调研了一圈候选：UUID、号段模式（Leaf）、Snowflake。UUID 无序，InnoDB 页分裂严重；号段模式依赖 DB，还得额外部署一套；Snowflake 本地生成、趋势递增、就是个 64 位整型，最对我们的场景。

## 64 位怎么切，WorkerID 怎么分

经典位分配：1 位符号 + 41 位毫秒时间戳 + 10 位 WorkerID + 12 位序列号，单机每毫秒理论上能出 4096 个 ID。

真正要花心思的是 WorkerID 怎么分。我们跑在 KubeSphere 上，每个 Pod 用 StatefulSet 的下标派生 WorkerID（0-1023），再配合配置中心给不同服务预留号段范围，避免不同实例撞车。光这样还不放心，启动时把 WorkerID 连同 Pod IP、启动时间写进 Redis，做一次占用校验。

## 时钟回拨：等还是拒

NTP 同步可能让时间毫秒级倒退，直接生成就是重复 ID，这事没有商量余地。我们的策略分两档：小幅回拨（5ms 内）自旋等待；超过阈值直接拒绝服务并告警，宁可这单失败，不产脏数据。

![Snowflake 生成一个 ID 前的完整判定流程](/images/post-22-snowflake-flow.svg)

核心的 NextID 长这样：

```go
const (
    epoch       int64 = 1704067200000 // 2024-01-01 00:00:00 UTC
    workerIDBits uint8 = 10
    seqBits      uint8 = 12
    maxWorkerID  int64 = -1 ^ (-1 << workerIDBits)
    maxSeq       int64 = -1 ^ (-1 << seqBits)
)

type Snowflake struct {
    mu        sync.Mutex
    lastStamp int64
    workerID  int64
    seq       int64
}

func NewSnowflake(workerID int64) (*Snowflake, error) {
    if workerID < 0 || workerID > maxWorkerID {
        return nil, fmt.Errorf("workerID %d out of range", workerID)
    }
    return &Snowflake{workerID: workerID}, nil
}

func (s *Snowflake) NextID() (int64, error) {
    s.mu.Lock()
    defer s.mu.Unlock()

    now := time.Now().UnixMilli()
    if now < s.lastStamp {
        offset := s.lastStamp - now
        if offset > 5 {
            return 0, fmt.Errorf("clock moved backwards %dms, refused", offset)
        }
        time.Sleep(time.Duration(offset) * time.Millisecond)
        now = time.Now().UnixMilli()
        if now < s.lastStamp {
            return 0, errors.New("clock still backwards after wait")
        }
    }

    if now == s.lastStamp {
        s.seq = (s.seq + 1) & maxSeq
        if s.seq == 0 {
            // 当前毫秒序列号耗尽，等到下一毫秒
            for now <= s.lastStamp {
                now = time.Now().UnixMilli()
            }
        }
    } else {
        s.seq = 0
    }

    s.lastStamp = now
    id := ((now - epoch) << (workerIDBits + seqBits)) |
        (s.workerID << seqBits) |
        s.seq
    return id, nil
}
```

业务层通过 Wire 注入单例 `*Snowflake`，DAO 在 BeforeCreate 钩子中填充主键：

```go
func (u *User) BeforeCreate(tx *gorm.DB) error {
    if u.ID == 0 {
        id, err := sf.NextID()
        if err != nil {
            return err
        }
        u.ID = id
    }
    return nil
}
```

## 五个坑

WorkerID 10 位看着够用，但我们最初把多个服务混在同一号段里，压测时出现跨服务 WorkerID 碰撞。后来按服务前缀切分号段，配置中心统一管。

时钟回拨的阈值不能设太大，也不能直接 panic。5ms 内等待，超过就返回错误让上游降级，比如重试到其他实例。底线只有一条：不生成重复 ID。

GORM 的 BeforeCreate 在批量 Create 时每条记录都会调一次，Snowflake 单例的锁竞争要留心。实测万级批量写入时锁等待可接受，再大的批量建议分片。

41 位时间戳能用大约 69 年，epoch 选 2024 年足够；系统要跑到 2090 年以后就得重新评估。

还有一条纪律：别把 WorkerID 写死在配置文件里。Pod 重建后复用了旧 WorkerID、旧实例还活着，就撞了。StatefulSet + 下标派生是目前我们最稳的方案。

## 后来

Snowflake 原理不复杂，难的是落地那几件事：WorkerID 分配、时钟回拨、批量写入的锁竞争。这套东西在统一认证中心跑了大半年，数千家机构的日常认证请求里没出过 ID 重复，趋势也没乱过。比起自增主键，分库分表和排序场景都省心不少。

> 封面图：[yellowcloud / Flickr](https://www.flickr.com/photos/63794141@N00/3197605452) · CC BY 2.0
