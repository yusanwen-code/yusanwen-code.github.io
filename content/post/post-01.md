---
title: "从 fasthttp 迁移到 go-zero：一次 C/S 到 B/S 的架构重构实录"
slug: "post-01"
date: 2023-09-06T10:30:00+08:00
draft: false
tags: ["go-zero","fasthttp","架构迁移"]
categories: ["架构"]
description: "宠物医疗 SaaS 系统从 fasthttp 长连接到 go-zero B/S 微服务的迁移过程与踩坑"
---

## 问题背景

我在某 SaaS 公司做宠物医疗 SaaS 系统时，老版本是典型的 C/S 架构：Windows 客户端通过 fasthttp 与服务端保持长连接，自定义二进制协议做消息分发。这套架构早期跑得很稳，但随着宠物医院门店扩张到数千家，问题逐渐暴露：客户端发版困难、协议升级要双端兼容、服务端无法水平扩容（长连接绑定节点），而且业务逻辑全部塞在一个单体里，改一个挂号流程要全量回归。

2023 年我们决定把宠物医疗 SaaS 系统迁移到 B/S 架构，浏览器直接访问，后端选型用了 go-zero。

## 方案/设计

go-zero 吸引我的点是它自带的微服务治理能力：熔断、限流、降级、超时控制都是开箱即用，不用自己在业务代码里堆中间件。整体拆成了 API 网关层和 RPC 服务层：

- API 层用 go-zero 的 `.api` 文件定义 RESTful 接口，通过 `goctl` 生成路由、handler、types 骨架。
- RPC 层用 `goctl rpc new` 生成 gRPC 服务，按领域拆成挂号、诊疗、收费、库存四个服务。
- 服务注册用 etcd，网关通过 `zrpc` 直连 RPC 客户端，带客户端负载均衡。

下面是 `.api` 文件的一个片段：

```go
syntax = "v1"

type (
    RegisterRequest {
        PetId    int64  `json:"pet_id"`
        DoctorId int64  `json:"doctor_id"`
        DeptCode string `json:"dept_code"`
    }
    RegisterResponse {
        OrderNo string `json:"order_no"`
        Status  int    `json:"status"`
    }
)

service clinic-api {
    @handler RegisterHandler
    post /api/v1/register (RegisterRequest) returns (RegisterResponse)
}
```

生成的 handler 只做参数校验和调用 logic，业务全部下沉到 logic 层，再通过 `zrpc` 调用下游：

```go
func (l *RegisterLogic) Register(req *types.RegisterRequest) (*types.RegisterResponse, error) {
    resp, err := l.svcCtx.ClinicRpc.Register(l.ctx, &clinic.RegisterReq{
        PetId:    req.PetId,
        DoctorId: req.DoctorId,
        DeptCode: req.DeptCode,
    })
    if err != nil {
        return nil, err
    }
    return &types.RegisterResponse{OrderNo: resp.OrderNo, Status: int(resp.Status)}, nil
}
```

`zrpc` 的客户端在 `servicecontext.go` 里初始化，自带 etcd 服务发现和中间件：

```go
type ServiceContext struct {
    Config    config.Config
    ClinicRpc clinic.ClinicClient
}

func NewServiceContext(c config.Config) *ServiceContext {
    return &ServiceContext{
        Config:    c,
        ClinicRpc: clinic.NewClinicClient(zrpc.MustNewClient(c.ClinicRpc).Conn()),
    }
}
```

## 踩坑/权衡

第一是长连接下线的过渡。老客户端还有存量门店在用，我们在网关侧做了一层协议适配：fasthttp 接收老协议，转成 gRPC 调用新服务，灰度了两个月才彻底切掉。期间最麻烦的是老协议没有 trace 字段，我们在适配层强制注入了 traceId，否则跨协议排查问题完全是黑盒。

第二是 go-zero 的 `goctl` 模板定制。默认生成的代码结构和我们团队的 DAO 规范有出入，我们 fork 了一份 template，把 GORM 和 Zap 日志注入进去，后续新服务直接用定制模板生成，省了不少重复劳动。

第三是超时配置。go-zero 的超时是分层的，API 层、RPC 客户端、RPC 服务端都要设，而且要呈"倒金字塔"——外层超时必须大于内层，否则会出现上游已经返回超时、下游还在执行的空转。我们把 API 设成 5s，RPC 设成 3s，DB 查询设成 1s，基本覆盖了业务场景。

## 小结

从 fasthttp C/S 迁到 go-zero B/S，最大的收益不是性能，而是交付节奏：浏览器即开即用，发版不再依赖客户端升级；微服务拆分后，单个服务可以独立部署。go-zero 的工具链和治理能力让我们在没有专职中间件团队的情况下也能把微服务跑起来，这对中小团队很实在。
