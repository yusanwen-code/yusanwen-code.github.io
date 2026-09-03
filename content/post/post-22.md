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

## 问题背景

统一认证中心需要为用户、应用、团队、授权记录等多种实体生成全局唯一 ID。早期我们直接用 MySQL 自增主键，问题很快暴露：分库分表后自增 ID 在不同分片冲突；业务方希望 ID 携带时间信息便于排序；批量写入时自增锁成为热点。

我们调研了 UUID、号段模式（Leaf）和 Snowflake。UUID 无序导致 InnoDB 页分裂严重；号段模式依赖 DB 且需要额外部署；Snowflake 本地生成、趋势递增、64 位整型，最适合我们的场景。

## 方案设计

Snowflake 的经典位分配：1 位符号 + 41 位毫秒时间戳 + 10 位 WorkerID + 12 位序列号。理论单机每毫秒可生成 4096 个 ID。

WorkerID 的分配是工程重点。我们在 KubeSphere 中为每个 Pod 注入通过 StatefulSet 下标派生的 WorkerID（0-1023），配合配置中心预留范围，避免不同服务实例冲突。同时在启动时将 WorkerID 与 Pod IP、启动时间写入 Redis，做一次占用校验。

时钟回拨是另一个关键点。NTP 同步可能导致毫秒级倒退，如果直接生成会出现重复 ID。我们的策略是：小幅回拨（5ms 内）自旋等待；超过阈值则拒绝服务并告警，避免脏数据。

## 关键代码

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

## 踩坑与权衡

- WorkerID 10 位看似够用，但我们最初把多个服务混在同一号段，压测时出现跨服务 WorkerID 碰撞。后来按服务前缀切分号段，并通过配置中心统一管理。
- 时钟回拨阈值不能设太大，也不能直接 panic。我们在 5ms 内等待，超过则返回错误让上游降级（比如重试到其他实例），保证不生成重复 ID。
- GORM 的 BeforeCreate 在批量 Create 时对每条记录都会调用，注意 Snowflake 单例的锁竞争。实测万级批量写入时锁等待在可接受范围，但超大批量建议分片。
- 41 位时间戳大约可用 69 年，epoch 选 2024 年足够；但如果系统要跑到 2090 年以后需要重新评估。
- 不要把 WorkerID 写死在配置文件里，Pod 重建后如果复用了旧 WorkerID 而旧实例还在，就会冲突。StatefulSet + 下标派生是我们目前最稳的方案。

## 小结

Snowflake 的原理不复杂，但真正落地要把 WorkerID 分配、时钟回拨、批量写入锁竞争这几件事处理好。我们在统一认证中心中跑了大半年，数千家机构日常认证请求下没有出现过 ID 重复或趋势乱序，相比自增主键在分库分表和排序场景都省心不少。

> 封面图：[yellowcloud / Flickr](https://www.flickr.com/photos/63794141@N00/3197605452) · CC BY 2.0
