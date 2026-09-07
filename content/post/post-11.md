---
title: "Excelize 流式导出百万级支付对账数据"
slug: "post-11"
date: 2024-02-09T10:30:00+08:00
draft: false
image: /images/post-11-cover.jpg
tags: ["Excelize", "流式处理", "性能优化"]
categories: ["Go"]
description: "统一支付平台对账文件用 Excelize StreamWriter 百万行导出实战"
---

## 导出一次，OOM 一次

统一支付平台每月初要给商户出对账单，大商户一个月的流水能到百万行量级。最早的版本用 `excelize.NewFile` + `SetSheetRow` 一行行写，跑一次导出，内存直接吃掉几个 G，OOM 被杀是常事，运营还老过来催："怎么还没生成好？"

我当时要做的，就是把这个导出改造成稳定跑百万行、内存可控、耗时可接受。选型上我们本来就在用 xuri/excelize，它的 `StreamWriter` 就是为这种场景设计的。真正的问题不在库，在于整条链路都得改成流式。

## 读、写、传，全改成流式

核心思路三条：

1. 数据库游标分页读取，用 ID 翻页而不是 `OFFSET`，避开深分页；
2. Excelize StreamWriter 按行写入，写完立即刷盘，不在内存里攒所有行；
3. 文件边写边传 S3/MinIO，用 `io.Pipe` 把 Excelize 的输出直接对接 SDK 的上传流，不落本地磁盘。

再用 goroutine 把"读 DB"和"写 Excel"做成生产者-消费者，通道容量控制在几千行，背压自然形成。

![百万行导出：整条链路都流式](/images/post-11-stream-export.svg)

## 落到代码上

StreamWriter 的基础用法是这样，关键是记得 `Flush` 结束：

```go
f := excelize.NewFile()
defer f.Close()

sw, err := f.NewStreamWriter("Sheet1")
if err != nil {
    return err
}
styleID, _ := f.NewStyle(&excelize.Style{Font: &excelize.Font{Bold: true}})
_ = sw.SetRow("A1", []interface{}{
    excelize.Cell{Value: "订单号", StyleID: styleID},
    excelize.Cell{Value: "交易时间", StyleID: styleID},
    excelize.Cell{Value: "金额", StyleID: styleID},
    excelize.Cell{Value: "手续费", StyleID: styleID},
    excelize.Cell{Value: "状态", StyleID: styleID},
})
```

生产者按 ID 游标翻页：

```go
func streamOrders(ctx context.Context, db *gorm.DB, merchantID string, month string,
    ch chan<- []Order) error {
    defer close(ch)
    var lastID int64
    const pageSize = 2000
    for {
        var rows []Order
        err := db.WithContext(ctx).
            Where("merchant_id = ? AND month = ? AND id > ?", merchantID, month, lastID).
            Order("id ASC").Limit(pageSize).Find(&rows).Error
        if err != nil {
            return err
        }
        if len(rows) == 0 {
            return nil
        }
        select {
        case ch <- rows:
        case <-ctx.Done():
            return ctx.Err()
        }
        lastID = rows[len(rows)-1].ID
        if len(rows) < pageSize {
            return nil
        }
    }
}
```

消费者拿到一批就调 `SetRow`，注意行号要自己维护：

```go
rowIdx := 2
for batch := range ch {
    for _, o := range batch {
        cell := []interface{}{
            o.OutTradeNo,
            o.CreatedAt.Format("2006-01-02 15:04:05"),
            o.Amount.StringFixed(2),
            o.Fee.StringFixed(2),
            o.Status,
        }
        cellRef, _ := excelize.CoordinatesToCellName(1, rowIdx)
        if err := sw.SetRow(cellRef, cell); err != nil {
            return err
        }
        rowIdx++
    }
}
if err := sw.Flush(); err != nil {
    return err
}
```

最关键的一步是边写边传 S3。`io.Pipe` 把 Write 变成 Reader：

```go
pr, pw := io.Pipe()
go func() {
    err := f.Write(pw)
    pw.CloseWithError(err)
}()

_, err = s3Client.PutObject(ctx, &s3.PutObjectInput{
    Bucket: aws.String(bucket),
    Key:    aws.String(key),
    Body:   pr,
})
```

`f.Write(pw)` 会在 StreamWriter 刷盘时往 Pipe 里写，S3 SDK 那头并发读，全程磁盘上不产生临时文件。

## 五个坑

第一，单个 sheet 行数上限。Excel 一个 sheet 最多 1048576 行，写到 100 万行时主动新建 Sheet2、Sheet3，表头重复写一次。StreamWriter 在 sheet 之间切换要先 Flush 旧的再 NewStreamWriter 新的。

第二，时间格式和数字格式。直接写字符串虽然省事，但商户拿到后没法在 Excel 里求和。金额我加了数字格式：

```go
moneyStyle, _ := f.NewStyle(&excelize.Style{NumFmt: 2}) // 0.00
_ = sw.SetColStyle("C", moneyStyle)
_ = sw.SetColStyle("D", moneyStyle)
```

第三，GORM 的游标内存。即使分页 2000，GORM 默认会把结果映射到结构体切片，只要及时释放引用，GC 能正常回收。但要注意别在循环外持有 `rows` 的引用，否则整批都不释放。

第四，Pipe 的错误传播。如果 S3 上传失败，`pr` 会先被关闭，但 `f.Write(pw)` 那一侧还在写，必须通过 `pw.CloseWithError(err)` 让它感知到，否则 goroutine 泄漏。生产里我还加了一个 `context.AfterFunc` 做兜底。

第五，耗时与内存的权衡。4C8G 的 Pod 里测下来，百万行导出稳定在 100MB 内存以内，耗时约 40 秒。想再快，可以按商户分 shard 并行导出多个文件再合并，但运维复杂度上来了，当前规模没必要。

## 改造之后

改造后对账导出再没 OOM 过，运营也不再追着要文件。回头看，百万行 Excel 导出的关键根本不是哪个库的神技，而是整条链路都流式：数据库流式读、Excel 流式写、对象存储流式传，任何一环攒在内存里都会爆。Excelize 的 StreamWriter 已经把最难的 XML 分片写做掉了，应用层只要把生产和消费解耦，加上背压，就能稳定跑下来。

> 封面图：[NYC Wanderer / Flickr](https://www.flickr.com/photos/10183029@N00/3631902258) · CC BY-SA 2.0
