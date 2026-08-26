---
title: "S3 对象存储体系：文档与数据的高性能上传"
date: 2025-06-23T10:30:00+08:00
draft: false
tags: ["S3","对象存储","上传"]
categories: ["存储"]
description: "从预签名到分片上传，聊聊数据集服务里的 S3 实战"
---

## 问题背景

在数据治理服务和数据集管理服务两个项目里，我们每天要接收大量文档：论文 PDF、Word 报告、扫描件，还有向量化后生成的二进制向量文件。早期我们图省事，直接让客户端把文件 POST 到后端，后端再 `io.Copy` 到 MinIO。结果文件一大，后端内存和带宽立刻吃紧，Gin 的 `c.Request.Body` 遇到百兆文件时还会触发 OOM。

更麻烦的是权限：数据集属于不同 AppRole 团队，不能谁拿到 URL 就能下载。我当时的做法是把"上传通道"和"业务权限"解耦——后端只签发临时凭证，客户端直传 S3，文件落桶后再由后端登记元数据。

## 方案设计

核心是 S3 Presigned URL。客户端先调后端的"申请上传"接口，后端校验团队配额、文件大小、MIME 类型，然后生成一个有时效的 PUT URL。客户端拿着这个 URL 直传对象存储，完全不经过业务后端。

对于超过一定阈值（我们设的 32MB）的文件，走分片上传（Multipart Upload）：客户端先申请 UploadID，并发上传各个 Part，最后发 Complete 请求。这样断点续传和失败重试都能在客户端做掉，后端压力骤降。

## 关键代码

后端用的是 AWS SDK for Go v2，MinIO 和云厂商的 S3 都兼容这套 API：

```go
// PresignClient 封装预签名逻辑
type PresignClient struct {
    s3 *s3.Client
    presign *s3.PresignClient
    bucket string
}

func (p *PresignClient) PresignPut(ctx context.Context, key, contentType string, size int64) (string, error) {
    input := &s3.PutObjectInput{
        Bucket:      aws.String(p.bucket),
        Key:         aws.String(key),
        ContentType: aws.String(contentType),
        // 服务端加密，防止桶策略误配导致明文泄露
        ServerSideEncryption: types.ServerSideEncryptionAes256,
    }
    // 15 分钟有效期，够大文件传完
    resp, err := p.presign.PresignPutObject(ctx, input,
        s3.WithPresignExpires(15*time.Minute))
    if err != nil {
        return "", err
    }
    return resp.URL, nil
}
```

分片上传的初始化和完成接口：

```go
// 申请分片上传
func (p *PresignClient) InitMultipart(ctx context.Context, key string) (string, error) {
    out, err := p.s3.CreateMultipartUpload(ctx, &s3.CreateMultipartUploadInput{
        Bucket: aws.String(p.bucket),
        Key:    aws.String(key),
    })
    if err != nil { return "", err }
    return *out.UploadId, nil
}

// 为每个 Part 生成预签名 URL
func (p *PresignClient) PresignPart(ctx context.Context, key, uploadID string, partNum int32) (string, error) {
    out, err := p.presign.PresignUploadPart(ctx, &s3.UploadPartInput{
        Bucket:     aws.String(p.bucket),
        Key:        aws.String(key),
        UploadId:   aws.String(uploadID),
        PartNumber: partNum,
    }, s3.WithPresignExpires(30*time.Minute))
    if err != nil { return "", err }
    return out.URL, nil
}
```

Hertz 路由层只做参数校验和登记：

```go
func (h *UploadHandler) ApplyUpload(ctx context.Context, c *app.RequestContext) {
    var req ApplyUploadReq
    if err := c.BindAndValidate(&req); err != nil { c.JSON(400, err); return }

    // 校验 AppRole 团队配额
    if err := h.quota.Check(ctx, req.TeamID, req.Size); err != nil {
        c.JSON(403, map[string]string{"msg": err.Error()}); return
    }

    key := buildKey(req.TeamID, req.FileName)
    url, err := h.presign.PresignPut(ctx, key, req.ContentType, req.Size)
    if err != nil { c.JSON(500, err); return }

    // 落一条"待确认"记录，回调后变正式
    h.meta.CreatePending(ctx, key, req.Size, req.TeamID)
    c.JSON(200, map[string]string{"url": url, "key": key})
}
```

## 踩坑与权衡

第一个坑是 CORS。浏览器直传 S3 必须配 CORSRule，AllowedHeader 要放行 `Content-Type` 和 `x-amz-*`，否则预检直接挂。我们一开始只在云控制台配了 `*`，结果带签名头的 PUT 被拦，排查了半天才发现是 ExposeHeader 没配 `ETag`，前端拿不到分片 ETag 无法 Complete。

第二个坑是分片大小。S3 要求除最后一个 Part 外每个 Part 不小于 5MB，太小会被拒；太大则单 Part 失败重试成本高。我们最终固定 8MB，配合 pond  worker pool 控制并发数为 5，既跑满带宽又不会把客户端网卡打满。

第三个是孤儿分片清理。客户端如果传了一半放弃，UploadID 不会自动消失，这些 Part 会计费。我们用定时任务扫 `ListMultipartUploads`，把超过 24 小时未完成的 `AbortMultipartUpload` 掉。

下载侧同理用预签名 GET URL，但我们额外做了一层：敏感数据集的 URL 只有 5 分钟有效期，且在 URL 里绑定了下载者的用户 ID 作为查询参数，后端在签发前会再校验一次 RBAC 权限。

## 小结

S3 预签名上传本质上是把"数据面"和"控制面"分开：业务后端只管鉴权和元数据，字节流直接走对象存储。配合分片上传和定时清理，我们在数据集管理服务里稳定支撑了大量文档的并发入库，后端服务的内存和带宽几乎不再受文件大小影响。
