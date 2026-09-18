# F3 AI知识检索（RAG问答）— Feature Spec

| | |
| ---- | ---- |
| 编号 | F3 |
| 来源 | PRD §36；UI 页面23；PHASE1_FEATURES F3.1–F3.5 |
| 依赖 | F1.6（解析模型）、F2（语料与关联）、F10（审计/权限） |
| 被依赖 | F4（知识检索技能）、F7（FMEA 历史依据引用） |
| 里程碑 | M2 |

## 1. 概述

面向知识库的自然语言问答，答案必须携带可核验引用（来源文档、项目、时间、原文片段）；无命中时明确回答"未找到"，禁止无依据作答。典型场景（PRD §36）：密封失效历史案例 / 历史DFM问题 / 料号使用过的项目。

## 2. Feature Units

### F3.1 混合检索（Ingestion + 召回）

- **FR3.1.1** Ingestion：`PARSE_CONFIRMED` 的文档 → 章节感知分块（512–1024 token，表格序列化为"表头: 值"文本行）→ bge-m3 嵌入 → pgvector 入库；每个 chunk 携带 `doc_id / doc_version / section_id / page / bbox / kb_version`。
- **FR3.1.2** 文档新版本生效后，旧版本 chunk 标记 `superseded=true`，默认不参与检索。
- **FR3.1.3** 查询召回：向量 top50 + 关键词（tsvector）top50 → RRF 融合 → bge-reranker 重排 → top-k（默认 k=8）。
- **FR3.1.4** 权限过滤在召回阶段生效：无权限文档的 chunk 不进入候选池。
- **FR3.1.5** 检索范围可限定：全部知识库 / 当前项目关联文档。
- **AC3.1.1** 金标检索集（≥50 query-文档对）Recall@8 ≥ 85%（目标值见 Q1）。

### F3.2 带引用答案输出

- **FR3.2.1** 响应结构：`{answer, sources[], conversation_id}`；每个 source = `{document_id, doc_version, project, uploaded_at, snippet, page, bbox, quote}`。
- **FR3.2.2** Prompt 强制要求：每个事实性结论必须附引用编号 `[1][2]`；无引用支撑的句子仅允许通用性表述。
- **FR3.2.3** 引用后处理校验：`quote` 必须能在 source 文档解析模型中匹配到（精确或归一化模糊匹配）；校验失败的引用降级剔除并记录。
- **FR3.2.4** 答案流式输出（SSE），引用信息随流式末尾的 `sources` 事件下发。
- **AC3.2.1** 抽样审计 ≥50 条答案：引用准确率（引用确实支撑对应结论）可统计且达标（金标集上 ≥90%，见 Q3）。
- **AC3.2.2** 任一答案中的每个事实性结论都可点击定位到原文。

### F3.3 多轮追问

- **FR3.3.1** 会话内保留最近 N 轮上下文；追问时先做 query 改写（结合上下文改写为独立完整检索词），再做检索。
- **FR3.3.2** 会话历史持久化，可回到历史会话继续追问。

### F3.4 检索结果操作

- **FR3.4.1** 查看原文定位：前端 PDF 查看器跳转至 `page` 并按 `bbox` 高亮；Excel/Word 文档展示对应表格/段落快照。
- **FR3.4.2** 引用可"关联到当前 FMEA 条目 / 项目"：生成 link 记录（FMEA 行或 Project ↔ source），在目标对象侧可见"依据"。

### F3.5 无命中兜底

- **FR3.5.1** 重排后最高分低于阈值 → 不调用生成，直接返回固定模板："未在知识库中找到相关资料"，附 1–2 条改写建议。
- **FR3.5.2** 检索分数在灰区（阈值附近）时，答案顶部提示"以下内容供参考，匹配度较低"。
- **FR3.5.3** `no_hit` 事件独立记录，用于检索质量分析与语料缺口发现。
- **AC3.5.1** 金标"知识库中没有答案"类问题（≥10 条）误答率为 0（系统必须回答未找到）。

## 3. 数据模型（核心）

| 实体 | 关键字段 |
| ---- | ---- |
| `chunk` | id, doc_id, doc_version, section_id, page, bbox, text, embedding(vector), kb_version, superseded, tsv(tsvector) |
| `rag_conversation` | id, project_id, user_id, created_at |
| `rag_message` | conversation_id, role, content, sources(JSONB), no_hit, feedback? |
| `object_source_link` | src_type(fmea_row/project), src_id, document_id, page, bbox, quote —— F3.4.2 与 F7.3 共用 |

## 4. API 概要

```
POST /api/v1/rag/query            # SSE 流式（answer 增量 + sources 事件）
GET  /api/v1/rag/conversations    # 会话列表/详情
POST /api/v1/rag/feedback         # 点赞/点踩（质量追踪）
POST /api/v1/links                # 引用关联（F3.4.2）
```

## 5. 横切接入（F10）

- **审计**：`rag.query` 记录 query、改写后 query、模型与 prompt 版本、kb_version、citations[]、答案 id —— 这是"AI引用准确率可抽样审计" KPI 的数据来源。
- **KPI**：`rag.first_token`（首 token 耗时 P95 ≤ 5s）、`rag.no_hit_rate`、`rag.feedback`。
- **权限**：FR3.1.4 检索层权限过滤。

## 6. 非目标

跨语言检索、多模态（图片内容检索）、自动语料爬取、知识图谱推理。

## 7. 开放问题

- **Q1** Recall@8 / 引用准确率的验收目标值需与业务方共同核定（本稿 85% / 90% 为建议值）。
- **Q2** 历史版本文档是否可主动检索（默认否）。
- **Q3** 抽样审计的执行人与频率（建议 AI管理员每月抽样 ≥50 条）。
- **Q4** 检索阈值初值（上线前用金标集调参确定，写入配置）。
