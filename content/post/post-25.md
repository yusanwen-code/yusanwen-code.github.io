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

## 文件杂、体积大、质量参差

某科技公司的数据平台要处理的东西很杂：客户上传的论文 PDF、期刊数据包，还有从 OpenAlex 同步来的学术数据。目标只有一个，把它们统一治理成可检索、可分析的结构化资产。

麻烦在于文件来源杂、体积大（单文件几十到几百 MB），质量还参差不齐。有的 PDF 是扫描件，得走 OCR；有的元数据干脆缺失；作者机构的写法五花八门。

我在数据治理服务里设计了一条从原始文件入库到结构化元数据落地的链路。思路不复杂：把「文件存储」「解析」「元数据管理」三件事拆开，每一步都能独立重试和替换。

## 四层流水线

整体分四层：

1. 原始文件层：文件通过 S3 预签名直传到 MinIO，路径按 `raw/{tenant}/{yyyy}/{mm}/{id}.pdf` 组织，元信息写 file_objects 表。
2. 解析层：异步 Worker 消费解析任务，按文件类型路由到不同 parser。文本型 PDF 用 pdfplumber 提取文本和章节结构，扫描件走 OCR；论文元数据通过 GROBID 或正则从首页抽取标题、作者、摘要、DOI、参考文献。
3. 清洗层：作者名标准化、机构归一化、DOI 校验去重，用 Temporal 工作流编排（下一篇会展开规则引擎）。
4. 元数据层：结构化结果落 MySQL 作为权威库，同时同步到 StarRocks 做分析查询，全文索引进 Elasticsearch。

各层之间通过任务表和消息队列解耦。**原始文件永远不修改**，所有解析结果挂在 file_id 下，出了问题随时能追溯。

![数据治理四层链路：原始文件、解析、清洗、元数据](/images/post-25-governance-pipeline.svg)

## 文件对象与解析路由

文件在系统里的身份，是这么记录的：

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

解析任务的分发在 Python Worker 端，按 MIME 类型路由：

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

## 解析是最脆的一环

PDF 解析是整条链路里最脆弱的一环。pdfplumber 对双栏排版、数学公式、上下标经常串行；GROBID 基于 CRF 模型，效果好但部署重，单篇解析要 5 到 10 秒。我们的做法是默认走 pdfplumber 粗解析，关键客户的高价值文件再回灌 GROBID 精修，两边各取所长。

扫描件必须 OCR，但 OCR 错误率高、成本也大。好在可以省着用：看首页有没有可选文本层，有就直接解析，没有才进 OCR 队列，不把算力浪费在本来就有文本层的 PDF 上。

去重也有一层妥协。元数据去重以 DOI 为主键，可 DOI 会缺失、会写错。没有 DOI 的论文，就用标题加首作者加年份做 SimHash 近似去重，阈值得跟着数据调。

还有两条底线。一是原始文件不可变：所有清洗都基于副本生成新版本，解析出问题随时重跑，不会污染原始数据。二是 OpenAlex 数据量太大，全量同步不现实，我们用 SeaTunnel 做增量同步，按 update_date 分批拉，避免一次性打满源库带宽。

## 后来

数据治理没有银弹。这套架构真正起作用的地方，是把脏活拆成了可观测、可重试、可替换的阶段：原始文件不变，解析与清洗分离，元数据多态存储。面对来源各异的学术数据，加规则是渐进的事，不用推倒重来。

> 封面图：[Barta IV / Flickr](https://www.flickr.com/photos/98640399@N08/10030588973) · CC BY 2.0
