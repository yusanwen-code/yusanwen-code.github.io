---
title: "S3 预签名上传在大文件治理场景的实践"
date: 2024-10-01T10:30:00+08:00
draft: false
tags: ["S3","预签名","对象存储"]
categories: ["存储"]
description: "用预签名 URL 让客户端直传 S3，减轻后端带宽压力"
---

## 问题背景

数据治理服务 接收的论文 PDF、数据集文件普遍在几十到几百 MB，早期走"客户端 → 后端 → MinIO"的中转上传，后端服务的带宽和内存压力很大：Go 的 `c.FormFile` 会把 multipart 内容写临时文件，并发一上来磁盘 IO 和 GC 都吃紧，大文件上传中断后还得从头重来。

更合理的做法是客户端直接把文件 PUT 到对象存储，后端只负责签发上传 URL 和记录元信息。S3 兼容协议（我们用 MinIO）提供的预签名 URL 正好做这件事。

## 方案设计

后端提供一个 `POST /files/presign` 接口，入参是文件名、大小、MIME、内容 SHA256，后端：
1. 生成全局 file_id 和 object key（`raw/{tenant}/{yyyy}/{mm}/{file_id}.ext`）；
2. 调用 S3 SDK 生成一个 15 分钟有效的 PUT 预签名 URL，绑定 Content-Type；
3. 在 file_objects 表插入一条 status=uploading 的记录；
4. 把 URL 和 file_id 返回给客户端。

客户端用这个 URL 直接 PUT 文件到 MinIO，上传完成后回调 `POST /files/{id}/complete`，后端校验对象是否真实存在、大小是否匹配，然后把状态置为 uploaded 并投递解析任务。

对超过 100MB 的文件，我们走分片上传（CreateMultipartUpload → 各分片预签名 → CompleteMultipartUpload），支持断点续传。

## 关键代码

```go
import (
    "context"
    "time"
    "github.com/aws/aws-sdk-go-v2/aws"
    "github.com/aws/aws-sdk-go-v2/service/s3"
)

type PresignReq struct {
    FileName string `json:"file_name"`
    Size     int64  `json:"size"`
    MIMEType string `json:"mime_type"`
    Sha256   string `json:"sha256"`
}

func (h *FileHandler) Presign(c *gin.Context) {
    var req PresignReq
    c.ShouldBindJSON(&req)

    fileID, _ := h.sf.NextID()
    key := buildKey(c.GetInt64("tenant_id"), fileID, req.FileName)

    input := &s3.PutObjectInput{
        Bucket:      aws.String(h.bucket),
        Key:         aws.String(key),
        ContentType: aws.String(req.MIMEType),
        Metadata: map[string]string{
            "sha256":  req.Sha256,
            "file-id": strconv.FormatInt(fileID, 10),
        },
    }

    presignClient := s3.NewPresignClient(h.s3Client,
        func(o *s3.PresignOptions) { o.Expires = 15 * time.Minute })

    resp, err := presignClient.PresignPutObject(c.Request.Context(), input)
    if err != nil {
        c.JSON(500, gin.H{"msg": "presign failed"})
        return
    }

    h.db.Create(&FileObject{
        ID: fileID, TenantID: c.GetInt64("tenant_id"),
        FileKey: key, FileName: req.FileName,
        Size: req.Size, MIMEType: req.MIMEType,
        Hash: req.Sha256, Status: "uploading",
    })

    c.JSON(200, gin.H{
        "file_id":    fileID,
        "upload_url": resp.URL,
        "method":     resp.Method,
        "headers":    resp.SignedHeader,
    })
}
```

Complete 时用 HeadObject 校验：

```go
func (h *FileHandler) Complete(c *gin.Context) {
    id, _ := strconv.ParseInt(c.Param("id"), 10, 64)
    var obj FileObject
    h.db.First(&obj, id)

    out, err := h.s3Client.HeadObject(c.Request.Context(), &s3.HeadObjectInput{
        Bucket: aws.String(h.bucket),
        Key:    aws.String(obj.FileKey),
    })
    if err != nil || *out.ContentLength != obj.Size {
        h.db.Model(&obj).Update("status", "failed")
        c.JSON(400, gin.H{"msg": "upload verify failed"})
        return
    }
    h.db.Model(&obj).Update("status", "uploaded")
    h.publishParseTask(obj.ID)
    c.JSON(200, gin.H{"msg": "ok"})
}
```

## 踩坑与权衡

- 预签名 URL 绑定了 HTTP 方法和 headers，客户端必须原样使用。前端最常见的错误是 PUT 时手动加了 `Content-Type` 但值和签名时不一致，S3 直接返回 SignatureDoesNotMatch。要么严格对齐，要么签名时不指定 ContentType 由客户端自定，但这样有被篡改类型的风险。
- 预签名 URL 本身不鉴权，拿到的人都能上传。我们把有效期压到 15 分钟，并且 object key 用不可猜的 Snowflake ID，避免被枚举。
- 大文件必须走分片。单片 PUT 虽然简单，但 500MB 文件断一次就要重传，体验很差。分片上传每片 16MB，并发上传，单片失败只需重传那片。
- HeadObject 校验不能省。客户端可能拿到 URL 后不传或传一半就调 complete，必须从 S3 侧确认对象真实存在且大小匹配。
- MinIO 的预签名 v4 和 AWS S3 行为基本一致，但部分老版本 MinIO 对带 Metadata 的签名有兼容问题，升级到最新稳定版即可。

## 小结

预签名上传把后端从数据通路中摘出来，只做签名和校验，带宽压力下降明显，客户端还能享受对象存储的分片和断点续传能力。配合 file_objects 表的状态机，上传、校验、解析三步衔接清晰，是大文件场景值得采用的模式。
