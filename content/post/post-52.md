---
title: "Redis 分布式锁在高并发扣减场景的正确姿势"
slug: "post-52"
date: 2025-11-11T10:30:00+08:00
draft: false
image: /images/post-52-cover.jpg
tags: ["Redis", "分布式锁", "高并发"]
categories: ["分布式"]
description: "统一支付平台计费引擎里，Redis 锁 + Lua 原子扣减的落地与踩坑"
---

## 问题背景

统一支付平台有一个动态计费引擎，订单支付成功后要扣减商户的套餐额度，PC、小程序、OpenAPI 三端可能同时触发同一商户的扣减。最早我们用 `SELECT ... FOR UPDATE` 行锁，高并发下数据库连接很快被占满，接口 RT 抖动明显。后来我们改成 Redis 分布式锁加 Lua 原子扣减，把并发压力从 MySQL 挪到 Redis。

## 方案设计

锁的 key 按商户维度 `lock:quota:{merchant_id}`，而不是全局锁。加锁用 `SET key value NX PX 30000`，value 是唯一 token（UUID），释放锁用 Lua 脚本比对 value，防止误删别人的锁。对于执行时间可能超过 30 秒的对账导出任务，用看门狗（watchdog）自动续期。额度扣减本身也走一段 Lua，保证"检查余额 + 扣减"原子性，避免锁内再发多条 Redis 命令。

## 关键代码

加锁与解锁：

```go
const unlockScript = `
if redis.call("get", KEYS[1]) == ARGV[1] then
    return redis.call("del", KEYS[1])
else
    return 0
end`

type RedisLock struct {
    client redis.Cmdable
    key    string
    token  string
    ttl    time.Duration
}

func (l *RedisLock) TryLock(ctx context.Context) (bool, error) {
    ok, err := l.client.SetNX(ctx, l.key, l.token, l.ttl).Result()
    if err != nil || !ok {
        return false, err
    }
    go l.watchdog(ctx)
    return true, nil
}

func (l *RedisLock) Unlock(ctx context.Context) error {
    return l.client.Eval(ctx, unlockScript, []string{l.key}, l.token).Err()
}

func (l *RedisLock) watchdog(parent context.Context) {
    ticker := time.NewTicker(l.ttl / 3)
    defer ticker.Stop()
    for {
        select {
        case <-parent.Done():
            return
        case <-ticker.C:
            ok, _ := l.client.Expire(parent, l.key, l.ttl).Result()
            if !ok {
                return
            }
        }
    }
}
```

额度扣减 Lua：

```go
const deductScript = `
local remain = tonumber(redis.call("HGET", KEYS[1], "remain"))
local need = tonumber(ARGV[1])
if remain == nil or remain < need then
    return -1
end
redis.call("HINCRBY", KEYS[1], "remain", -need)
return remain - need`

func DeductQuota(ctx context.Context, rdb redis.Cmdable, merchantID string, amount int64) (int64, error) {
    key := "quota:" + merchantID
    res, err := rdb.Eval(ctx, deductScript, []string{key}, amount).Result()
    if err != nil {
        return 0, err
    }
    code, _ := res.(int64)
    if code < 0 {
        return 0, ErrQuotaNotEnough
    }
    return code, nil
}
```

## 踩坑与权衡

第一，早期用 `GET` 再 `DEL` 两步释放锁，出过事故：A 业务执行超过 TTL，锁自动过期，B 拿到了锁，A 结束时把 B 的锁删了。Lua 比对 value 是必须的，不能省。

第二，单实例 Redis 锁在主从切换时有小概率丢锁。统一支付平台是资金场景，我们的兜底是：扣减 Lua 里仍做余额判断，最终以数据库对账为准；锁只做并发控制，不做唯一正确性来源。对强一致要求更高的场景应考虑 etcd/ZooKeeper，而不是盲信 Redlock。

第三，看门狗必须和 ctx 绑定，业务结束或 panic 时能退出，否则 goroutine 会泄漏。第四，锁粒度按 merchant_id 比全局锁吞吐高得多，但要注意单商户热点 key，如果某商户并发极高还要进一步分桶（`quota:{merchant}:{shard}`）再聚合。第五，TTL 取业务 P99 的两倍左右比较稳妥，太长会在异常时阻塞，太短会提前过期。

## 小结

Redis 分布式锁的"正确姿势"是：唯一 token 加 Lua 释放、合理 TTL 加看门狗、细粒度 key，并且承认它在主从切换等异常下不是强一致的。资金系统里，锁是性能优化，数据库唯一约束和定期对账才是正确性的底线。

> 封面图：[Horia Varlan / Flickr](https://www.flickr.com/photos/10361931@N06/4268291295) · CC BY 2.0
