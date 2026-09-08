---
title: "S3 对象存储体系：文档与数据的高性能上传"
slug: "post-43"
date: 2025-06-23T10:30:00+08:00
draft: false
image: /images/post-43-cover.jpg
tags: ["S3","对象存储","上传"]
categories: ["存储"]
description: "从预签名到分片上传，聊聊数据集服务里的 S3 实战"
---

## 文件一大，后端先扛不住

数据治理服务和数据集管理服务这两个项目，每天要接收大量文档：论文 PDF、Word 报告、扫描件，还有向量化后生成的二进制向量文件。早期图省事，直接让客户端把文件 POST 到后端，后端再 `io.Copy` 进 MinIO。文件一大就露馅：后端内存和带宽立刻吃紧，Gin 的 `c.Request.Body` 碰上百兆文件还会触发 OOM。

权限是另一摊麻烦。数据集属于不同 AppRole 团队，不能谁拿到 URL 就能下载。我当时的思路是把"上传通道"和"业务权限"解耦：后端只签发临时凭证，客户端直传 S3，文件落桶之后再由后端登记元数据。

## 让字节流绕开业务后端

核心是 S3 Presigned URL。客户端先调后端的"申请上传"接口，后端校验团队配额、文件大小、MIME 类型，然后签发一个带时效的 PUT URL。客户端拿着 URL 直传对象存储，业务后端全程不碰字节流。

超过一定阈值的文件（我们设的 32MB）走分片上传（Multipart Upload）：客户端先申请 UploadID，并发上传各个 Part，最后发一个 Complete 请求。断点续传和失败重试都在客户端做掉，后端压力一下子小了很多。

![S3 上传体系：控制面与数据面分开，字节流直达对象存储](/images/post-43-s3-presign-upload.svg)

## 预签名和分片的代码

后端用的是 AWS SDK for Go v2，MinIO 和各家云厂商的 S3 都兼容这套 API：

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

分片上传的初始化，和为每个 Part 签发预签名 URL：

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

## CORS、分片大小和孤儿分片

第一个坑是 CORS。浏览器直传 S3 必须配 CORSRule，AllowedHeader 要放行 `Content-Type` 和 `x-amz-*`，否则预检直接挂。我们一开始只在云控制台配了个 `*`，结果带签名头的 PUT 照样被拦；排查了半天才发现是 ExposeHeader 没配 `ETag`，前端拿不到分片 ETag，Complete 发不出去。

第二个坑是分片大小。S3 要求除最后一个 Part 外每个 Part 不小于 5MB，太小直接被拒；太大则单个 Part 失败重试的成本高。我们最后固定 8MB，配 pond worker pool 把并发控制在 5，既跑满带宽，又不至于把客户端网卡打满。

第三个是孤儿分片。客户端传一半放弃了，UploadID 不会自动消失，这些 Part 会一直计费。我们用定时任务扫 `ListMultipartUploads`，超过 24 小时未完成的一律 `AbortMultipartUpload` 掉。

下载侧同理走预签名 GET URL，不过我们多加了一层：敏感数据集的 URL 只给 5 分钟有效期，URL 里还绑上下载者的用户 ID 当查询参数，签发之前后端会再校验一遍 RBAC 权限。

## 数据面和控制面

S3 预签名上传说到底是把"数据面"和"控制面"分开：业务后端只管鉴权和元数据，字节流直接走对象存储。配上分片上传和定时清理，数据集管理服务里大量文档并发入库是稳的，后端的内存和带宽基本不再跟着文件大小涨。

> 封面图：[jdnx / Flickr](https://www.flickr.com/photos/21442511@N08/4423023837) · CC BY 2.0
