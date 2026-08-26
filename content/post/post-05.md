---
title: "使用 Redis + go-cache 构建多级缓存降低数据库压力"
slug: "post-05"
date: 2023-11-07T10:30:00+08:00
draft: false
tags: ["Redis","go-cache","多级缓存"]
categories: ["缓存"]
description: "本地 go-cache 与 Redis 组合的多级缓存设计、穿透击穿防护与一致性策略"
---

## 问题背景

谛语平台的医院字典、科室列表、医生排班这类基础数据读多写少，但查询量很大。最开始所有请求直接打 MySQL，高峰期连接数经常逼近上限。我们先加了 Redis 缓存，效果不错，但 Redis 也有网络开销，而且 Redis 本身在高峰期 CPU 也不低。对于那些变化极不频繁、体积小的热点数据，再加一层进程内缓存可以进一步减少 Redis 访问。

我用 `go-cache`（本地内存缓存）+ Redis 构建了两级缓存。

## 方案/设计

读路径：先查本地 go-cache，命中直接返回；未命中查 Redis，命中则回填本地缓存；Redis 也未命中才查数据库，结果同时回填 Redis 和本地。写路径：先更新数据库，再删除 Redis 和本地缓存（cache-aside 模式，不主动更新缓存，避免并发写导致脏数据）。

```go
import (
    "context"
    "encoding/json"
    "time"
    "github.com/coocood/freecache"
    "github.com/go-redis/redis/v8"
    "github.com/patrickmn/go-cache"
)

type MultiLevelCache struct {
    local  *cache.Cache
    redis  *redis.Client
    localTTL time.Duration
    redisTTL time.Duration
}

func NewMultiLevelCache(rdb *redis.Client) *MultiLevelCache {
    return &MultiLevelCache{
        local:    cache.New(5*time.Minute, 10*time.Minute),
        redis:    rdb,
        localTTL: 1 * time.Minute,
        redisTTL: 30 * time.Minute,
    }
}

func (m *MultiLevelCache) Get(ctx context.Context, key string, dst interface{}) (bool, error) {
    // L1: 本地缓存
    if v, ok := m.local.Get(key); ok {
        return true, json.Unmarshal(v.([]byte), dst)
    }
    // L2: Redis
    data, err := m.redis.Get(ctx, key).Bytes()
    if err == redis.Nil {
        return false, nil
    }
    if err != nil {
        return false, err
    }
    // 回填本地，TTL 设短一些，防止多实例数据不一致窗口太长
    m.local.Set(key, data, m.localTTL)
    return true, json.Unmarshal(data, dst)
}

func (m *MultiLevelCache) Set(ctx context.Context, key string, val interface{}) error {
    data, err := json.Marshal(val)
    if err != nil {
        return err
    }
    if err := m.redis.Set(ctx, key, data, m.redisTTL).Err(); err != nil {
        return err
    }
    m.local.Set(key, data, m.localTTL)
    return nil
}

func (m *MultiLevelCache) Del(ctx context.Context, key string) error {
    m.local.Delete(key)
    return m.redis.Del(ctx, key).Err()
}
```

注意本地缓存 TTL 我故意设得比 Redis 短很多（1 分钟 vs 30 分钟），因为本地缓存不会收到其他实例的失效通知，TTL 短可以控制脏数据窗口。

## 踩坑/权衡

第一个是缓存穿透。有些不存在的字典 key 会被反复查询，缓存和数据库都没有。我用了布隆过滤器在缓存层之前拦截，但更简单的做法是缓存空值（TTL 设短，比如 30 秒）：

```go
// 数据库未查到时，缓存一个空标记
if errors.Is(err, gorm.ErrRecordNotFound) {
    m.redis.Set(ctx, key, []byte("__null__"), 30*time.Second)
    return false, nil
}
```

第二个是缓存击穿。某个热点 key 过期瞬间大量请求同时打到数据库。我们用 `singleflight` 合并并发请求，同一时刻只有一个 goroutine 查库：

```go
var sf singleflight.Group

func (m *MultiLevelCache) GetWithLoad(ctx context.Context, key string,
    dst interface{}, loader func() (interface{}, error)) error {

    if found, _ := m.Get(ctx, key, dst); found {
        return nil
    }
    v, err, _ := sf.Do(key, func() (interface{}, error) {
        // double check，可能其他 goroutine 已经加载完
        if found, _ := m.Get(ctx, key, dst); found {
            return dst, nil
        }
        return loader()
    })
    if err != nil {
        return err
    }
    data, _ := json.Marshal(v)
    m.local.Set(key, data, m.localTTL)
    m.redis.Set(ctx, key, data, m.redisTTL)
    return json.Unmarshal(data, dst)
}
```

第三个是多实例一致性问题。本地缓存在 A 实例更新了，B 实例还是旧值，最多有 1 分钟窗口。对于字典数据这个窗口可以接受，但如果是余额、库存这类强一致数据，绝不能走本地缓存，必须直查 Redis 或数据库。我们把缓存按一致性要求分级：弱一致性数据走多级，强一致性只走 Redis 并加分布式锁。

第四个是内存控制。go-cache 没有容量上限，如果 key 无限增长会 OOM。我在 Set 时做了 key 数量检查，超过阈值就用 `DeleteExpired` 主动清理，后来换成了 freecache，它自带容量限制和 LRU 淘汰。

## 小结

多级缓存不是银弹，适合读多写少、对短暂不一致容忍的场景。本地 TTL 要远短于 Redis，缓存空值防穿透，singleflight 防击穿，强一致数据不要碰本地缓存。把缓存按一致性分级，比一刀切要靠谱得多。
