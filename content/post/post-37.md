---
title: "RAG 系统中的文档分块策略与效果对比"
slug: "post-37"
date: 2025-03-21T10:30:00+08:00
draft: false
image: /images/post-37-cover.jpg
tags: ["RAG", "分块", "Embedding"]
categories: ["AI"]
description: "固定窗口、语义分块、结构化分块在真实语料上的取舍"
---

## 问题背景

数据集管理服务承接了大量 PDF/Word 学术文档的解析与向量化，服务于知识库问答服务的知识问答。早期我们图省事，文档解析出纯文本后直接按 500 字符定长切分，效果很不稳定：表格被腰斩、段落中间被切开、跨页的章节标题和正文分到了不同块。召回时经常出现"答案明明在文档里但没召回到"的情况。

后来我主导重做了分块链路，对比了几种策略在学术 PDF 和制度类文档上的效果，这篇把做法和踩坑记录下来。

## 方案设计

我们把分块抽象成一个 `Chunker` 接口，上层按文档类型选择不同实现：

```go
type Chunk struct {
    ID       string
    Text     string
    Metadata map[string]any
}

type Chunker interface {
    Split(ctx context.Context, doc *ParsedDoc) ([]Chunk, error)
}
```

`ParsedDoc` 不是纯文本，而是解析阶段保留的结构化结果：段落、标题层级、表格、页码。这样分块时能利用文档结构。

我们落地了三种 Chunker：

**1. 固定窗口 + overlap**

```go
type FixedChunker struct {
    Size    int // 字符数
    Overlap int
}

func (c *FixedChunker) Split(_ context.Context, doc *ParsedDoc) ([]Chunk, error) {
    text := strings.Join(doc.Paragraphs, "\n")
    var chunks []Chunk
    for i := 0; i < len(text); i += c.Size - c.Overlap {
        end := i + c.Size
        if end > len(text) {
            end = len(text)
        }
        chunks = append(chunks, Chunk{Text: text[i:end]})
        if end == len(text) {
            break
        }
    }
    return chunks, nil
}
```

实现最简单，对纯文本类制度文档可用，但对学术 PDF 表格几乎无药可救。

**2. 递归字符分块**

按分隔符优先级（`\n## `、`\n### `、`\n\n`、`\n`、`。`）递归切，尽量在自然边界断开。我们参考 LangChain 的 `RecursiveCharacterTextSplitter` 思路写了 Go 版本，对带 Markdown 标题层级的文档效果明显优于固定窗口。

**3. 结构化分块**

这是我们最终对学术 PDF 的主策略。解析阶段 PDF 经 Layout 识别后，每个元素带类型（heading/paragraph/table）和层级。分块规则：

- 每个 chunk 以一个标题为起点，把其下的段落、表格、子标题内容聚合，直到超过最大 token 数；
- 表格整体作为一个独立 chunk，不与正文混切，表格前补一行"表 X：标题"作为上下文；
- chunk metadata 里写入 `title_path`（如"第三章 > 3.2 实验设计"），召回后拼 Prompt 时用上。

```go
func (s *StructuredChunker) splitByHeadings(blocks []Block) []Chunk {
    var chunks []Chunk
    var cur *ChunkBuf
    for _, b := range blocks {
        if b.Type == BlockHeading && b.Level <= s.MaxLevel {
            if cur != nil {
                chunks = append(chunks, cur.Build())
            }
            cur = NewChunkBuf(b.Text, b.Level)
            continue
        }
        if b.Type == BlockTable {
            chunks = append(chunks, Chunk{
                Text:     tableToText(b.Table),
                Metadata: map[string]any{"type": "table", "title": b.Table.Title},
            })
            continue
        }
        cur.Append(b.Text)
        if cur.TokenCount() > s.MaxTokens {
            chunks = append(chunks, cur.Build())
            cur = cur.CarryOver()
        }
    }
    if cur != nil {
        chunks = append(chunks, cur.Build())
    }
    return chunks
}
```

Embedding 阶段所有 chunk 统一过向量模型，写入向量库时带上 metadata，检索时用 metadata 做过滤和重排。

## 踩坑与权衡

**token 估算要和模型一致**。一开始按字符数估算长度，实际中文一个汉字往往对应 1 个以上 token，导致超长 chunk 被 embedding 接口截断。我们改用和 embedding 模型一致的 tokenizer 做长度控制。

**overlap 不是越大越好**。overlap 能缓解边界信息丢失，但也会让相邻 chunk 高度相似，召回时占满 top-k 却没提供新信息。我们在结构化分块里把 overlap 设为 0，靠标题路径提供上下文；只有固定窗口策略才保留 10%–15% 的 overlap。

**表格单独处理**。表格转文本时如果直接用空格拼接列，语义全乱。我们统一转成 Markdown 表格，并在前面加标题句；对超宽表格按列拆成多个子表。这一招对"某指标在某条件下的数值"类问题召回准确率提升最明显。

**chunk 元数据很关键**。`title_path`、页码、文档 ID 这些在检索后拼上下文时能显著减少幻觉，也方便做溯源和高亮。

## 小结

没有万能分块尺寸，分块策略要跟着文档类型走。结构化文档优先用结构信息，纯文本用递归字符分块兜底，表格单独成块。在数据集管理服务里我们按文档类型路由 Chunker，并把分块结果和 metadata 一起入库，知识库问答服务的问答命中率比定长切分有明显改善。

> 封面图：[duh.denise / Flickr](https://www.flickr.com/photos/36979168@N03/4437143239) · CC BY 2.0
