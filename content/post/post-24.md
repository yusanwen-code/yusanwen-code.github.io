---
title: "Go 事务通过 Context 透传由 DAO 层感知的设计"
slug: "post-24"
date: 2024-08-30T10:30:00+08:00
draft: false
image: /images/post-24-cover.jpg
tags: ["事务","Context","DAO"]
categories: ["Go"]
description: "用 Context 透传 GORM 事务，让 Service 与 DAO 解耦"
---

## 把 tx 当参数传，签名全毁了

统一认证中心的 Service/DAO 分层里，多表原子写躲不掉：创建应用要同时写 apps、app_credentials、audit_logs；给用户授权要写 user_roles 和 role_permissions 快照。少写哪张都不行。

最直接的写法是 Service 层开 `db.Transaction(func(tx *gorm.DB) error { ... })`，把 tx 当参数往下传给 DAO。能用，但 DAO 方法签名全得带上 `tx *gorm.DB`，和普通查询混在一起很难看；嵌套调用一多，代码里到处是 tx 透传。我想要的是：DAO 签名保持干净，自己知道"现在在不在事务里"。

## 把事务塞进 Context

思路是让 context.Context 顺路把事务句柄带下去。Service 开事务时把 tx 放进 ctx，DAO 从 ctx 取：取到就用 tx，取不到就用默认 db。DAO 签名只需要 `ctx context.Context`，跟普通 RPC 风格一致。

具体拆成两个小件。TxManager 提供 WithTx(ctx, fn)：内部 `db.WithContext(ctx).Transaction` 开事务，tx 存进 ctx，fn 成功就提交，出错或 panic 就回滚。DAO 侧一个 GetDB(ctx) 辅助函数，优先从 ctx 捞事务句柄。为了类型安全，context key 用自定义类型，不用字符串。

![事务句柄通过 Context 在 Service 与 DAO 之间透传](/images/post-24-tx-context.svg)

```go
type ctxKey struct{}
var txKey = ctxKey{}

type TxManager struct {
    db *gorm.DB
}

func (m *TxManager) WithTx(ctx context.Context, fn func(ctx context.Context) error) error {
    return m.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
        txCtx := context.WithValue(ctx, txKey, tx)
        return fn(txCtx)
    })
}

// GetDB 从 ctx 提取事务句柄，没有事务则用默认 db
func GetDB(ctx context.Context, def *gorm.DB) *gorm.DB {
    if tx, ok := ctx.Value(txKey).(*gorm.DB); ok && tx != nil {
        return tx.WithContext(ctx)
    }
    return def.WithContext(ctx)
}
```

DAO 使用：

```go
type AppDAO struct {
    db *gorm.DB
}

func (d *AppDAO) Create(ctx context.Context, app *App) error {
    return GetDB(ctx, d.db).Create(app).Error
}

func (d *AppDAO) CreateCredential(ctx context.Context, cred *AppCredential) error {
    return GetDB(ctx, d.db).Create(cred).Error
}
```

Service 组合：

```go
func (s *AppService) CreateApp(ctx context.Context, req CreateAppReq) (int64, error) {
    appID, _ := s.sf.NextID()
    err := s.txm.WithTx(ctx, func(ctx context.Context) error {
        if err := s.appDAO.Create(ctx, &App{ID: appID, Name: req.Name}); err != nil {
            return err
        }
        if err := s.appDAO.CreateCredential(ctx, &AppCredential{
            AppID: appID, AppSecret: hashSecret(req.Secret),
        }); err != nil {
            return err
        }
        return s.auditDAO.Log(ctx, "app.create", appID)
    })
    return appID, err
}
```

## 坑都在事务边界外

GORM 的 Transaction 回调里 panic 会被 recover 并回滚，但 recover 管不到别的 goroutine：fn 里起了 goroutine，它的 panic 不会触发回滚，而且它拿着的 ctx 还指向原来的 tx，那时事务可能已经提交或回滚了。所以事务内别把 ctx 传给异步任务，异步用 context.Background() 另起。

嵌套调 WithTx 是可以的，GORM 基于 savepoint 实现嵌套事务。但内层回滚只回到 savepoint，不会连累外层整体回滚；内层的 error 要是被吞了，外层照样提交。error 老老实实 return 上去。

还有几条小的。*gorm.DB 别长期存在结构体里跨请求复用，GORM 的 Session 机制会复用语句状态；每次从 ctx 取出来后调一下 WithContext(ctx) 是安全的。

这套模式也有代价：事务边界隐式藏在 ctx 里，新人读代码看不出某个 DAO 调用在不在事务中。我们靠 Code Review 把关，Service 方法注释里标明事务边界。

至于"context 该不该携带请求范围之外的数据"这个老争论：事务句柄确实是请求范围内的，又需要跨层透传，这个场景用 ctx 比把 tx 塞进每个方法签名实用。我站 ctx 这边。

## 后来

Context 透传事务之后，DAO 层保持只依赖 ctx 的干净签名，Service 用 WithTx 把业务逻辑一包，原子性就有了。配合 GORM 自带的 savepoint 嵌套事务，统一认证中心里大部分多表写操作都走这套模式，可读性和可测试性都比手动透传 tx 强。
