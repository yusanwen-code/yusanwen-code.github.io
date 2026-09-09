---
title: "Wire 依赖注入实战：Service/DAO 分层与接口解耦"
slug: "post-21"
date: 2024-07-14T10:30:00+08:00
draft: false
image: /images/post-21-cover.jpg
tags: ["Wire","依赖注入","分层架构"]
categories: ["Go"]
description: "在统一认证中心等项目用 Wire 实现 Service/DAO 分层与接口解耦"
---

## main 函数先垮掉

统一认证中心、统一支付平台这些项目刚起步的时候，main 函数没什么讲究：先 new DB，再 new DAO，再 new Service，再 new Controller，一层层往下 new。手写初始化，直观，也够用。

坏在项目会膨胀。构造函数参数越攒越多，依赖关系慢慢织成一张网，改一个底层组件，得顺着构造链改一整圈。单测想 mock 一个 DAO 也痛苦，mock 塞不进构造链。

我想要的其实就两条：把对象的创建和使用分开；保持编译期类型安全。运行时反射那种 DI 我不接受，依赖错了要等启动才炸出来。Google Wire 正好对上这两条。

## Wire 管拼装，代码管声明

分层还是老三样：Handler 到 Service 到 DAO。规矩一条：每层依赖下一层的接口，不依赖具体实现。DAO 定义接口，线上跑的是 GormDAO 实现；Service 只认 DAO 接口，测试时想换成什么就换什么。

Wire 这边分工也简单。每个类型怎么构造，用 Provider 函数声明；整张依赖图怎么拼，交给 Injector，编译期生成 wire_gen.go。没有运行时反射，依赖缺了、错了，编译器先说话。

Provider 我们按模块收拢成 ProviderSet，比如 auth 模块的 Service、DAO、Provider 放一个 set，顶层一个 wire.Build 全部汇总。

![Wire 在编译期拼装依赖图，运行时每层只依赖接口](/images/post-21-wire-di.svg)

## 构造函数直接返回接口

构造函数返回具体类型、上层依赖接口时，得靠 wire.Bind 显式绑一下，多一道手续。我们的做法是让构造函数直接返回接口类型，Bind 基本就用不上了。

单测也不需要 Wire 参与。手写个 mock 塞进构造函数就行：`NewUserService(&mockUserDAO{}, &mockSMS{})`。

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

## 三个坑

第一个是依赖循环。ServiceA 依赖 ServiceB，ServiceB 又间接绕回 ServiceA，Wire 不会帮你绕，直接报错。现在回头看这反而是好事，它逼着我们重新审视分层：把共享逻辑下沉到独立的内部包，或者用接口在同一层解耦。

第二个是接口绑定找不到实现，前面说的"构造函数直接返回接口"就是用来绕开它的。

第三个在 CI。wire_gen.go 必须提交到仓库，不然哪天 CI 环境里没装 wire 命令，编译直接挂。我们在 Makefile 里加了 make wire 步骤，改了 wire.go 手动跑一次生成。

## 值不值得上

引入 Wire 之后，依赖关系从隐式变成了显式：构造链由生成的代码管着，Service 只依赖接口，单测随便换 mock，编译期检查也比运行时 DI 让人安心。配合 Service/DAO 分层和 ProviderSet 模块化，项目涨到几十个组件，main 函数依然干净。

值不值得为此引一个框架，我的判断看规模：几十个 Service 的中大型项目收益明显；小项目手写初始化可能反而更快，别为了用而用。这套做法后来成了我们团队所有 Go 后端项目的标准做法。

> 封面图：[Unhindered by Talent / Flickr](https://www.flickr.com/photos/26406919@N00/461050192) · CC BY-SA 2.0
