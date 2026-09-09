---
title: "使用 Redis + go-cache 构建多级缓存降低数据库压力"
slug: "post-05"
date: 2023-11-07T10:30:00+08:00
draft: false
image: /images/post-05-cover.jpg
tags: ["Redis","go-cache","多级缓存"]
categories: ["缓存"]
description: "本地 go-cache 与 Redis 组合的多级缓存设计、穿透击穿防护与一致性策略"
---

## 直查 MySQL 撑不住了

医院字典、科室列表、医生排班这类基础数据，读的人多，改的人少，但查询量很大。最开始所有请求直接打 MySQL，高峰期连接数经常逼近上限。

先加了 Redis，效果不错。但 Redis 也有网络开销，高峰期它自己的 CPU 也不低。这时候就想：那些变化极不频繁、体积又小的热点数据，能不能再往进程里挪一层，连 Redis 这一跳都省掉？

于是有了 go-cache（本地内存缓存）+ Redis 的两级缓存。

![两级缓存的读路径与写路径](/images/post-05-multi-level-cache.svg)

## 读和写是两条路

读路径一层层往下穿透：先查本地 go-cache，命中直接返回；未命中查 Redis，命中就回填本地；Redis 也没有，才去查数据库，结果同时回填 Redis 和本地。

写路径反过来：先更新数据库，再删 Redis 和本地缓存。也就是 cache-aside，不主动更新缓存，避免并发写把脏数据写进去。

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

有个细节值得单独说。本地缓存的 TTL 我故意设得比 Redis 短很多，1 分钟对 30 分钟。本地缓存收不到其他实例的失效通知，A 实例改了数据，B 实例毫不知情，只能等 TTL 自然过期。TTL 短，脏数据的窗口就短。

## 四个坑

第一个是缓存穿透。有些根本不存在的字典 key 被反复查，缓存和数据库里都没有，每次都穿透到库。我在缓存层前面加了布隆过滤器，但其实还有个更省事的做法：缓存空值，TTL 设短一点，比如 30 秒：

```go
// 数据库未查到时，缓存一个空标记
if errors.Is(err, gorm.ErrRecordNotFound) {
    m.redis.Set(ctx, key, []byte("__null__"), 30*time.Second)
    return false, nil
}
```

第二个是缓存击穿。某个热点 key 过期的一瞬间，大量请求同时打到数据库。singleflight 可以把并发请求合并，同一时刻只有一个 goroutine 去查库，其余的等结果：

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

第三个是多实例一致性。本地缓存在 A 实例更新了，B 实例还是旧值，这个窗口最长能有 1 分钟。字典数据可以接受，但换成余额、库存这类强一致数据就不行了，这类数据根本不该碰本地缓存，必须直查 Redis 或数据库。后来我们把缓存按一致性要求分了级：弱一致的走多级缓存，强一致的只走 Redis，再加分布式锁。

第四个是内存控制。go-cache 没有容量上限，key 无限增长迟早 OOM。我一开始在 Set 时检查 key 数量，超了阈值就调 DeleteExpired 主动清。后来干脆换成 freecache，自带容量限制和 LRU 淘汰，省心。

## 后来

多级缓存只适合读多写少、能容忍短暂不一致的数据。这套跑下来，真正起决定作用的判断是先按一致性要求给数据分级，再决定谁能进本地缓存。分级立住了，TTL 怎么设、空值怎么防、singleflight 用在哪，都是顺手的工程活。

> 封面图：[rob.wall / Flickr](https://www.flickr.com/photos/49503072941@N01/2262564867) · CC BY 2.0
