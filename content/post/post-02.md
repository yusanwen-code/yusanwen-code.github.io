---
title: "gRPC 在宠物医疗 SaaS 微服务通信中的落地实践"
slug: "post-02"
date: 2023-09-22T10:30:00+08:00
draft: false
image: /images/post-02-cover.jpg
tags: ["gRPC","go-zero","微服务"]
categories: ["微服务"]
description: "宠物医疗 SaaS 系统微服务拆分中 gRPC 通信的 proto 设计、拦截器与错误码实践"
---

## HTTP+JSON 顶了一阵，问题也攒了一阵

宠物医疗 SaaS 拆成 go-zero 微服务后，挂号、诊疗、收费、库存四个服务之间调用很频繁。最开始图省事，服务间直接用 HTTP+JSON 通信，结果问题很快就来了：接口字段没有强约束，收费服务改了个字段名，挂号服务没同步，直接 panic；JSON 序列化在病历这种嵌套结构上性能也不理想；更头疼的是没有统一的错误码，上游拿到一个 500，完全分不清是业务异常还是系统故障。

我们决定把内部通信统一切到 gRPC。

## proto 怎么设计

设计上我们守着一条大原则：每个服务一个独立的 proto package。请求和响应消息都带 `BaseResp` 作为统一返回体，业务错误码不通过 gRPC status 传，而是放在 `BaseResp` 里。

为什么不走 status？gRPC status 适合表达 RPC 层的错误，比如超时、服务不可用；业务错误——宠物已建档、医生号源已满这类——要走 status 的话，拦截器很难把两类区分开。

![业务错误与 RPC 错误分层处理](/images/post-02-grpc-error-layers.svg)

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

## 三个坑

第一个坑是 proto 字段的兼容性。gRPC 要求新增字段必须用新的 tag 编号，不能复用已删除字段的编号。我们早期有同事为了"整洁"，把废弃字段删掉后复用了编号，结果老客户端反序列化错乱。后来在 CI 里加了 `buf breaking` 检查，禁止不兼容变更合入主干。

第二个坑是大消息场景。病历里会附带影像图片（AI 判读结果），最开始直接用 bytes 塞进 gRPC 消息，超过 4MB 默认上限就报错。改法倒不复杂：消息里只传 S3 预签名 URL，影像文件走对象存储直传，gRPC 消息体控制在几十 KB。

第三个坑是错误处理的边界。业务错误码放 `BaseResp` 之后，调用方每次都得检查 `base.code != 0`，很容易漏。最后我们在 logic 层封装了一个 `ToBaseResp(err)` 方法，把业务 error 统一映射成错误码，上游只需要判断 err 是否为 nil，不用再手动解 BaseResp。

## 回头看

gRPC 在微服务内部通信上，强类型约束和性能提升都是实打实的。配合 go-zero 的 etcd 服务发现，连接管理基本不用自己碰。真正费心思的其实是 proto 设计的纪律：字段编号一旦分配不可复用，业务错误和 RPC 错误分层处理，大载荷走对象存储而不是塞进消息体。

> 封面图：[David Davies / Flickr](https://www.flickr.com/photos/44124390461@N01/5339417741) · CC BY-SA 2.0
