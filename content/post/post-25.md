---
title: "数据治理服务架构：原始文件、PDF 解析与论文元数据管理"
slug: "post-25"
date: 2024-09-15T10:30:00+08:00
draft: false
image: /images/post-25-cover.jpg
tags: ["数据治理","PDF解析","架构"]
categories: ["数据"]
description: "数据治理服务中原始文件到结构化论文元数据的治理链路"
---

## 问题背景

某科技公司的数据平台需要把客户上传的论文 PDF、期刊数据包、OpenAlex 同步的学术数据统一治理成可检索、可分析的结构化资产。这些文件来源杂、体积大（单文件几十到几百 MB）、质量参差不齐：有的 PDF 是扫描件需要 OCR，有的元数据缺失，有的作者机构写法不统一。

我在数据治理服务里设计了一条从原始文件入库到结构化元数据落地的治理链路，核心是把"文件存储""解析""元数据管理"三件事解耦，每一步可独立重试和替换。

## 方案设计

整体分四层：

1. 原始文件层：文件通过 S3 预签名直传到 MinIO，路径按 `raw/{tenant}/{yyyy}/{mm}/{id}.pdf` 组织，元信息写 file_objects 表。
2. 解析层：异步 Worker 消费解析任务，按文件类型路由到不同 parser。文本型 PDF 用 pdfplumber 提取文本和章节结构，扫描件走 OCR；论文元数据通过 GROBID 或正则从首页抽取标题、作者、摘要、DOI、参考文献。
3. 清洗层：作者名标准化、机构归一化、DOI 校验去重，用 Temporal 工作流编排（下一篇会展开规则引擎）。
4. 元数据层：结构化结果落 MySQL 作为权威库，同时同步到 StarRocks 做分析查询，全文索引进 Elasticsearch。

各层之间通过任务表和消息队列解耦，原始文件永远不修改，所有解析结果挂在 file_id 下可追溯。

## 关键代码

文件对象记录：

```go
type FileObject struct {
    ID         int64     `gorm:"primaryKey"`
    TenantID   int64
    FileKey    string    // S3 object key
    FileName   string
    Size       int64
    MIMEType   string
    Hash       string    // sha256，用于秒传和去重
    Status     string    // uploaded/parsing/done/failed
    ParsedMeta *string   // JSON，解析出的标题作者等
    CreatedAt  time.Time
}
```

解析任务路由（Python Worker 端）：

```python
PARSERS = {
    "application/pdf": "pdf",
    "application/epub+xml": "jats",
}

async def dispatch_parse(file_obj: dict):
    parser_type = PARSERS.get(file_obj["mime_type"])
    if parser_type == "pdf":
        meta = await parse_pdf(file_obj["file_key"])
    elif parser_type == "jats":
        meta = parse_jats(file_obj["file_key"])
    else:
        meta = {}
    await update_metadata(file_obj["id"], meta)

async def parse_pdf(key: str) -> dict:
    local = await s3_download_to_tmp(key)
    with pdfplumber.open(local) as pdf:
        first_page = pdf.pages[0].extract_text() or ""
        return {
            "title": extract_title(first_page),
            "authors": extract_authors(first_page),
            "doi": extract_doi(first_page),
            "abstract": extract_abstract(pdf),
            "page_count": len(pdf.pages),
        }
```

## 踩坑与权衡

- PDF 解析是整个链路最脆弱的一环。pdfplumber 对双栏排版、数学公式、上下标经常串行；GROBID 基于 CRF 模型效果更好但部署重、单篇解析 5-10 秒。我们的策略是默认走 pdfplumber 做粗解析，关键客户的高价值文件再回灌 GROBID 精修。
- 扫描件必须 OCR，但 OCR 错误率高且成本大。我们通过首页是否含可选文本层来判断是否扫描件，只有扫描件才进 OCR 队列，避免对所有 PDF 浪费算力。
- 元数据去重以 DOI 为主键，但 DOI 可能缺失或写错。对无 DOI 的论文，用标题+首作者+年份做 SimHash 近似去重，阈值需要根据数据调整。
- 原始文件不可变是关键设计。所有清洗都是基于副本生成新版本，出问题可以重跑解析，不会污染原始数据。
- OpenAlex 数据量巨大，全量同步不现实，我们用 SeaTunnel 做增量同步，按 update_date 分批拉取，避免一次性打满源库带宽。

## 小结

数据治理没有银弹，核心是把脏活拆成可观测、可重试、可替换的阶段。原始文件不变、解析与清洗分离、元数据多态存储，这套架构让我们在面对不同来源的学术数据时能逐步加规则而不推倒重来。

> 封面图：[Barta IV / Flickr](https://www.flickr.com/photos/98640399@N08/10030588973) · CC BY 2.0
