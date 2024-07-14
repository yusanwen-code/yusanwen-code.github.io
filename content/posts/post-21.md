---
title: "Wire 依赖注入实战：Service/DAO 分层与接口解耦"
date: 2024-07-14T10:30:00+08:00
draft: false
tags: ["Wire","依赖注入","分层架构"]
categories: ["Go"]
description: "在 统一认证中心 等项目用 Wire 实现 Service/DAO 分层与接口解耦"
---

## 问题背景

我在某科技公司主导 统一认证中心、统一支付平台、数据治理服务 等后端项目时，初期用手写方式在 main 函数里层层初始化依赖：先 new DB，再 new DAO，再 new Service，再 new Controller。随着项目膨胀，构造函数参数越来越多，依赖关系变成一张网，改一个底层组件要顺着构造链改一圈，单元测试时想 mock 一个 DAO 也非常痛苦。我们需要一个依赖注入框架把对象的创建和使用分开，同时保持编译期类型安全，不接受运行时反射那种"启动才发现依赖错了"的方式。Google Wire 正好满足这个需求。

## 方案设计

我们的项目分层是 Handler/Controller 到 Service 到 DAO，每层依赖下一层的接口而不是具体实现。DAO 定义接口，具体是 GormDAO 实现；Service 依赖 DAO 接口，测试时可以换成 mock 实现。Wire 通过 Provider 函数声明每个类型怎么构造，通过 Injector 函数把整个依赖图拼起来，编译期生成代码 wire_gen.go，没有运行时反射。我们按模块组织 ProviderSet，比如 auth 模块的 Service、DAO、Provider 放一个 ProviderSet，顶层 wire.Build 汇总所有模块。

## 关键代码

```go
// dao/user_dao.go
type UserDAO interface {
    GetByID(ctx context.Context, id int64) (*User, error)
}

type userDAO struct {
    db *gorm.DB
}

func NewUserDAO(db *gorm.DB) UserDAO {
    return &userDAO{db: db}
}

// service/user_service.go
type UserService struct {
    userDAO dao.UserDAO
    sms     SMSProvider
}

func NewUserService(u dao.UserDAO, s SMSProvider) *UserService {
    return &UserService{userDAO: u, sms: s}
}

// wire.go
//go:build wireinject

func InitApp() *App {
    wire.Build(
        NewDB,
        dao.NewUserDAO,
        NewTencentSMSProvider,
        service.NewUserService,
        handler.NewUserHandler,
        NewApp,
    )
    return nil
}
```

如果构造函数返回具体类型但上层依赖接口，可以用 wire.Bind 显式绑定；我们的约定是构造函数直接返回接口类型，减少 Bind 的使用。测试时手写 mock 实现传入构造函数，不需要 Wire 参与，比如 `NewUserService(&mockUserDAO{}, &mockSMS{})`。

## 踩坑与权衡

Wire 最大的坑是"依赖循环"——ServiceA 依赖 ServiceB，ServiceB 又间接依赖 ServiceA，Wire 会直接报错。这逼着我们重新审视分层：把共享逻辑下沉到独立的内部包，或者用接口在同一层解耦。另一个常见问题是接口绑定找不到实现，我们约定构造函数直接返回接口类型来规避。还有 wire_gen.go 要提交到仓库，不然 CI 里没装 wire 命令会编译失败，我们在 Makefile 里加了 make wire 步骤，开发时改了 wire.go 手动跑一次。值不值得引入 Wire？对于几十个 Service 的中大型项目收益明显，小项目手写初始化可能更快，不要为了用而用。

## 小结

Wire 让 统一认证中心、统一支付平台 这些项目的依赖关系从隐式变成显式，构造链由 Wire 生成代码管理，Service 只依赖接口，单测时随便换 mock。编译期检查也比运行时 DI 框架更让人安心。配合清晰的 Service/DAO 分层和 ProviderSet 模块化，项目即使增长到几十个组件，main 函数依然干净可维护，这也是我们团队后来所有 Go 后端项目的标准做法。
