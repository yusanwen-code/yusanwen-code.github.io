---
title: "gRPC 在宠物医疗 SaaS 微服务通信中的落地实践"
date: 2023-09-22T10:30:00+08:00
draft: false
tags: ["gRPC","go-zero","微服务"]
categories: ["微服务"]
description: "宠物医疗 SaaS 系统微服务拆分中 gRPC 通信的 proto 设计、拦截器与错误码实践"
---

## 问题背景

宠物医疗 SaaS 系统从单体迁到 go-zero 微服务后，挂号、诊疗、收费、库存四个服务之间调用频繁。最开始图省事，服务间直接用 HTTP+JSON 通信，结果很快遇到问题：接口字段没有强约束，收费服务改了个字段名，挂号服务没同步就直接 panic；JSON 序列化在病历这种嵌套结构上性能也不理想；更头疼的是没有统一的错误码，上游拿到 500 完全不知道是业务异常还是系统故障。

我们决定把内部通信统一切到 gRPC。

## 方案/设计

proto 设计上我们遵循一个原则：每个服务一个独立的 proto package，请求和响应消息都带 `BaseResp` 作为统一返回体，业务错误码不通过 gRPC status 传，而是放在 `BaseResp` 里。这样做的原因是 gRPC status 适合表达 RPC 层错误（超时、不可用），业务错误（宠物已建档、医生号源已满）走 status 会让拦截器很难区分。

```protobuf
syntax = "proto3";
package clinic;
option go_package = "./clinic";

message BaseResp {
  int32 code = 1;
  string msg = 2;
}

message CreateMedicalRecordReq {
  int64 pet_id = 1;
  int64 doctor_id = 2;
  string chief_complaint = 3;
  repeated string symptoms = 4;
}

message CreateMedicalRecordResp {
  BaseResp base = 1;
  int64 record_id = 2;
  string record_no = 3;
}

service ClinicService {
  rpc CreateMedicalRecord(CreateMedicalRecordReq) returns (CreateMedicalRecordResp);
}
```

go-zero 生成的服务端代码里，我们在 `etc/*.yaml` 配置了监听地址和 etcd 注册：

```yaml
Name: clinic.rpc
ListenOn: 0.0.0.0:8081
Etcd:
  Hosts:
    - etcd:2379
  Key: clinic.rpc
Timeout: 3000
```

客户端通过 `zrpc.MustNewClient` 拿到连接，自带轮询负载均衡和重试。我们额外加了一个客户端拦截器做统一的日志和错误处理：

```go
func UnaryClientInterceptor(ctx context.Context, method string,
    req, reply interface{}, cc *grpc.ClientConn,
    invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {

    start := time.Now()
    err := invoker(ctx, method, req, reply, cc, opts...)
    cost := time.Since(start)

    var code int32
    if err != nil {
        code = int32(codes.Code(err))
    }
    logx.WithContext(ctx).Infof("rpc call %s, code=%d, cost=%v", method, code, cost)
    return err
}
```

注册到客户端：

```go
client := zrpc.MustNewClient(c.ClinicRpc,
    zrpc.WithUnaryClientInterceptor(UnaryClientInterceptor),
)
```

## 踩坑/权衡

第一个坑是 proto 字段的兼容性。gRPC 要求新增字段必须用新的 tag 编号，不能复用已删除字段的编号。我们早期有同事为了"整洁"把废弃字段删掉后复用了编号，导致老客户端反序列化错乱。后来在 CI 里加了 `buf breaking` 检查，禁止不兼容变更合入主干。

第二个是大消息场景。病历里会附带影像图片（AI 判读结果），最开始直接用 bytes 塞进 gRPC 消息，超过 4MB 默认上限就报错。我们改成只传 S3 预签名 URL，影像文件走对象存储直传，gRPC 消息体控制在几十 KB。

第三个是错误处理的边界。业务错误码放 `BaseResp` 后，调用方必须每次检查 `base.code != 0`，容易漏。我们在 logic 层封装了一个 `ToBaseResp(err)` 方法，把业务 error 统一映射成错误码，上游只需要判断 err 是否为 nil 即可，不用再手动解 BaseResp。

## 小结

gRPC 在微服务内部通信上带来的强类型约束和性能提升是实打实的，尤其配合 go-zero 的 etcd 服务发现，基本不用自己处理连接管理。关键是 proto 设计要有纪律：字段编号一旦分配不可复用，业务错误和 RPC 错误分层处理，大载荷走对象存储而不是塞进消息体。
