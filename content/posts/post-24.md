---
title: "Go 事务通过 Context 透传由 DAO 层感知的设计"
date: 2024-08-30T10:30:00+08:00
draft: false
tags: ["事务","Context","DAO"]
categories: ["Go"]
description: "用 Context 透传 GORM 事务，让 Service 与 DAO 解耦"
---

## 问题背景

在 统一认证中心 的 Service/DAO 分层中，经常出现一个业务操作要跨多张表且必须原子的场景：创建应用时要同时写 apps、app_credentials、audit_logs；给用户授权时要写 user_roles 和 role_permissions 快照。

最直接的写法是 Service 层 `db.Transaction(func(tx *gorm.DB) error { ... })`，然后把 tx 作为参数传给 DAO。但这样 DAO 方法签名全部要带上 `tx *gorm.DB`，和普通查询混在一起很难看，而且嵌套调用时代码里到处是 tx 透传。我们想要的是：DAO 方法签名保持干净，能自动感知"当前是否在事务里"。

## 方案设计

利用 context.Context 携带事务句柄。Service 层开启事务时把 `tx` 放入 ctx，DAO 层从 ctx 取，如果取到就用 tx，否则用默认的 db。这样 DAO 签名只需要 `ctx context.Context`，和普通 RPC 风格一致。

封装一个 `TxManager`，提供 `WithTx(ctx, fn)` 方法：内部用 `db.WithContext(ctx).Transaction` 开启事务，把 tx 存入 ctx，fn 执行成功提交，panic 或 error 回滚。

DAO 层封装 `GetDB(ctx)` 辅助函数，优先从 ctx 取事务句柄。为了类型安全，用自定义 context key 而不是字符串。

## 关键代码

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

## 踩坑与权衡

- GORM 的 Transaction 回调里 panic 会被 recover 并回滚，但如果 fn 里起了 goroutine，goroutine 中的 panic 不会触发回滚，而且 goroutine 里用的 ctx 仍然指向原 tx，事务可能已提交或回滚。所以事务内不要把 ctx 传给异步任务，异步任务用 context.Background() 另起。
- 嵌套调用 WithTx 时，GORM 的 Transaction 基于 savepoint 实现嵌套事务，能正常工作，但要注意内层回滚只回滚到 savepoint，不会让外层整体回滚。如果内层 error 被吞掉，外层照样提交，代码里要显式 return error。
- 不要把 *gorm.DB 长期存在结构体里跨请求复用，GORM 的 Session 机制会复用语句状态。每次从 ctx 取出来后调用 WithContext(ctx) 是安全的。
- 这种模式的代价是事务边界隐式藏在 ctx 里，新人读代码时不容易看出"这个 DAO 调用在不在事务中"。我们通过 Code Review 把关，并在 Service 方法注释中标注事务边界。
- context.Context 携带非请求范围的数据一直有争议，但事务句柄确实是请求范围内的、且需要跨层透传，这个场景用 ctx 比把 tx 塞进每个方法签名更实用。

## 小结

通过 Context 透传事务，DAO 层保持了只依赖 ctx 的干净签名，Service 层用 WithTx 包裹业务逻辑就能保证原子性。配合 GORM 自带的 savepoint 嵌套事务，统一认证中心 里大部分多表写操作都能用这套模式覆盖，代码可读性和可测试性都比手动透传 tx 好。
