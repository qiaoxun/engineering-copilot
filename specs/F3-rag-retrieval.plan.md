# F3 AI知识检索（RAG问答）— 技术方案（Plan）

| | |
| ---- | ---- |
| Feature | F3-rag-retrieval |
| 输入 | specs/F3-rag-retrieval.md、specs/F3-rag-retrieval.clarifications.md（冲突时以其为准）、PHASE1_SPEC.md、PHASE1_FEATURES.md、specs/README.md |
| 关联 | specs/F1-document-parsing.plan.md（统一解析模型、原文定位端点）、specs/F2-knowledge-base.plan.md（ingestion 事件/kb_revision/可见性谓词/zhparser 配置）、specs/F10-platform-governance.plan.md（LLMGateway/prompt_registry/审计/KPI/RBAC）、specs/F7-fmea-generation.md（object_source_link 共用，F7.3） |
| 阶段 | speckit-plan（仅设计，不写代码） |
| 里程碑 | M2 |

> 本 plan 中所有设计决策均标注溯源（FR/AC/Q 编号）。clarifications（Q1–Q4 决策）全文有效，本文引用处标注为「C-Qx」。

---

## 1. 架构与模块落点

### 1.1 总体架构

对齐既定技术栈：**后端 FastAPI 模块化单体 + Celery + PostgreSQL(pgvector) + MinIO；前端 React + TypeScript + Ant Design**。F3 落在独立顶层模块 `modules/rag/`（与 F2 plan §1.1 模块清单一致），内部分为 **Ingestion（离线写入）** 与 **Retrieval+Generation（在线查询）** 两条通路：Ingestion 订阅 F2 生命周期事件（`document.ingestable / superseded / delisted`），消费 F1.6 统一解析模型产出 chunk + bge-m3 嵌入入 pgvector；在线通路执行 混合召回 → 重排 → 生成（带引用、SSE 流式），全部生成调用经 F10 `LLMGateway`（FR3.1.1、FR3.1.3、FR3.2.1；F2 plan A5、F10 plan §4 挂点）。

```text
apps/backend/
├── app/
│   ├── core/                        # F10 平台地基（F10 plan）
│   ├── modules/
│   │   ├── documents/               # F1：解析模型（F3 ingestion 唯一文本来源，禁自解析）
│   │   ├── kb/                      # F2：文档/版本/kb_revision（F3 订阅其事件、复用其可见性谓词）
│   │   ├── rag/                     # ← F3 本体
│   │   │   ├── api/                 # query(SSE)/conversations/feedback/links 路由
│   │   │   ├── ingestion/           # F3.1：chunker（章节感知分块+表格序列化）→ embedder → pgvector 写入
│   │   │   ├── ingestion/events.py  # 订阅 F2 document.ingestable/superseded/delisted → 任务编排（F2 plan A5）
│   │   │   ├── retrieval/           # F3.1：向量召回 + tsvector 召回 + RRF 融合 + bge-reranker + 阈值带
│   │   │   ├── retrieval/filters.py # FR3.1.4 权限过滤 + FR3.1.5 范围过滤 + include_superseded（C-Q2）
│   │   │   ├── generation/          # F3.2：prompt 渲染、SSE 流式、引用后处理校验（quote grounding）
│   │   │   ├── conversation/        # F3.3：会话/消息持久化、上下文窗口、query 改写
│   │   │   ├── links/               # F3.4.2：object_source_link（与 F7.3 共用表）
│   │   │   └── evals/               # 金标评测入口（调 rag.eval 离线脚本，A9）
│   │   └── platform/                # F10：audit/rbac/kpi/prompts/objects（见 F10 plan）
│   ├── worker/                      # Celery：rag 队列（ingestion 任务；在线查询同步流式不入队）
│   └── main.py
└── alembic/
apps/frontend/
└── src/
    ├── pages/rag/                   # UI 页面23：会话列表 + 对话区 + 来源卡片列表
    ├── features/rag-chat/           # 提问框、流式答案渲染（[n]角标可点击）、灰区提示条、no_hit 模板、
    │                                #   「包含历史版本」开关（C-Q2）、点赞点踩、追问输入
    ├── features/source-card/        # source 卡片（文档/项目/时间/片段/页码）+ [查看原文][关联到当前FMEA/项目]
    ├── features/pdf-viewer/         # pdf.js：跳转 page + bbox 高亮（FR3.4.1；与 F1 校对视图复用 bbox 渲染）
    └── features/parse-snapshot/     # Excel/Word 命中：按 section_id 渲染表格/段落快照（复用 F1 parse-viewer）
```

### 1.2 核心流程

```text
Ingestion（F3.1，离线）：
  F2 发布 document.ingestable（PARSE_CONFIRMED 版本）→ Celery rag 队列任务
  → 读 F1 统一解析模型（GET .../parse 合并视图）→ 章节感知分块（目标 512、上限 1024 token，
    表格序列化为「表头: 值」文本行）→ bge-m3 批量嵌入 → chunks 入库（含 kb_version）
  → 回调 F2 kb_revision_service.record(INGEST) → kb_version+1（F2 plan A5）

新版本生效：F2 发布 document.superseded → UPDATE chunks SET superseded=true
  WHERE doc_id AND doc_version=旧版 → kb_revision(SUPERSEDE)+1（FR3.1.2、C-Q4）
下架：F2 发布 document.delisted → chunk 置 delisted=true，全通道召回排除（F2 plan A4）

在线查询（F3.1–F3.5，同步 SSE）：
  POST /rag/query → 权限检查（require_perm("rag.query")）
  → [多轮时] query 改写（f3.query_rewrite，结合最近 N 轮 → 独立完整检索词）（FR3.3.1）
  → 召回：候选池 SQL（可见性谓词 + 范围 + superseded/delisted 过滤，FR3.1.4/3.1.5、C-Q2）
      向量 top50（pgvector HNSW）∪ tsvector top50（zhcfg，与 F2.4 同一配置，F2 plan A7）
  → RRF 融合 → bge-reranker 重排 → top-k（k=8，配置可调）（FR3.1.3）
  → 阈值判定：最高分 < no_hit 阈值 → 不调 LLM，直接下发 no_hit 固定模板 + 改写建议（FR3.5.1、C-Q4）
                灰区（no_hit ≤ 分 < 灰区上界）→ 答案顶部"匹配度较低"提示（FR3.5.2、C-Q4）
  → 生成：f3.rag_answer（检索片段 + 编号引用指令）→ LLM 流式输出，answer 增量事件实时下发（FR3.2.4）
  → 引用后处理校验：每条引用 quote 与 source chunk 原文精确/归一化模糊匹配；
      失败引用降级剔除并记录（FR3.2.3）→ sources 事件随流末尾下发（FR3.2.1、FR3.2.4）
  → rag_message 持久化 + 审计 rag.query（query/改写 query/模型/prompt 版本/kb_version/citations）
      + KPI rag.first_token / rag.no_hit 事件（FR3.5.3、spec §5）
```

### 1.3 关键架构决策

| # | 决策 | 溯源 |
| ---- | ---- | ---- |
| A1 | **Ingestion 事件驱动、文本只来自 F1 解析模型**：F3 不读 MinIO 原件、不自建解析（复用 F1.6 契约与 `GET .../parse` 读视图，含人工 override——人工校对结论即时进入检索语料）；分块以统一模型的 section 为一级边界，chunk 携带 `section_id/page/bbox` 使引用可回溯到解析模型 | FR3.1.1；F1 plan A3/A4、FR1.6.2（禁绕过）；AC3.2.2 |
| A2 | **双通道混合检索 + RRF + 重排**：向量通道（pgvector HNSW、cosine、bge-m3 1024 维）与关键词通道（`chunks.tsv`，zhparser `zhcfg`——与 F2.4 共用同一 text search configuration 与自定义词典，F2 plan A7）各取 top50，RRF（k=60）融合后送 bge-reranker（bge-reranker-v2-m3，私有化部署）重排取 top-k=8。两通道互补覆盖"语义问法"与"料号/型号精确词"两类工程查询 | FR3.1.3；AC3.1.1 |
| A3 | **权限/范围/版本过滤全部在召回 SQL 层**：候选池查询直接内联 F2 可见性谓词生成函数（同一函数、同一配置源，F2 plan A6），`superseded=false AND delisted=false` 为默认谓词；`include_superseded=true`（请求级参数，默认 false，C-Q2）时放开 superseded 并强制 source 标注 `doc_version` +「历史版本」提示。无权限文档的 chunk 物理上不进入候选池，而非事后过滤 | FR3.1.4、FR3.1.5、FR3.1.2；C-Q2；AC2.6.1 同源原则 |
| A4 | **在线查询为同步 SSE 流式响应，非异步任务**：QA 对话要求首 token 体感，不走 `task_id`/`GET /tasks/{id}/events` 任务模式；`POST /api/v1/rag/query` 直接返回 `text/event-stream`，事件序列 `meta → answer*（增量）→ sources → done`，异常以 `error` 事件 + 统一错误体语义下发。与 specs/README"生成/比对/解析类走异步任务"不冲突——RAG 问答属流式交互类，spec §4 明确其 SSE 形态 | FR3.2.4、FR3.2.1；spec §4；specs/README（异步任务约定适用于任务类操作） |
| A5 | **阈值带判定在生成前置位**：重排分数归一化后与运行时配置比对——`< no_hit 阈值（调参锚点 0.30）`→ 不调用 LLM、返回固定模板"未在知识库中找到相关资料"+ 1–2 条改写建议（模板文本代码生成，非 LLM 生成，杜绝幻觉路径）；`[no_hit, 灰区上界 0.45)` → 照常生成但 `meta.gray_zone=true`，前端顶部提示。阈值由 AI管理员经配置接口调整，每次修改 emit `rag.threshold.updated` 审计并记录当时 kb_version | FR3.5.1、FR3.5.2；C-Q4；AC3.5.1 |
| A6 | **引用后处理校验是代码强制、非 prompt 约定**：LLM 输出的每条 citation 的 `quote` 先与对应 chunk 文本精确匹配，失败则归一化匹配（去空白/标点/全半角、英文小写）后模糊比率 ≥0.85（rapidfuzz）视为通过；仍失败则该引用从 `sources` 中降级剔除、答案文本中对应 `[n]` 角标改标 `[n]†`（"引用未通过核验"脚注），并计入审计 `citations_dropped`。方向与 F1 A6 grounding 一致："引用必须能在文档中找到"由代码保证 | FR3.2.3；AC3.2.1；F1 plan A6（同构决策） |
| A7 | **多轮 = 改写后检索，不改写生成上下文**：会话保留最近 N 轮（默认 3 轮，配置可调）仅用于 ① LLM query 改写（f3.query_rewrite，把"那它的扭矩呢"改写为独立完整检索词）与 ② 生成 prompt 中的极简对话摘要（通用性表述允许）；检索本身永远只用改写后的独立查询，避免历史片段污染召回。首轮不改写（省一次 LLM 调用，利于首 token SLO） | FR3.3.1、FR3.3.2；spec §5（rag.first_token P95 ≤ 5s） |
| A8 | **object_source_link 为 F3/F7 共用单一表**：F3.4.2 的"引用关联到 FMEA 行/项目"与 F7.3 的"历史依据引用"共用 spec §3 的 `object_source_link`（src_type ∈ {fmea_row, project}），F3 负责写入入口与目标侧"依据"查询 API，F7 只读消费；link 是人工操作产物（非 AI 生成物），不设状态机，但写审计 `rag.link.created` | FR3.4.2；spec §3（F3.4.2 与 F7.3 共用）；F7.3 |
| A9 | **金标评测离线化、指标写入配置**：`evals/rag/` 脚本对 `golden_set_rag_v1`（复用 F1 `golden_sets` 表，新增 `kind` 列区分，FR10.1.4 只增不删）跑检索与端到端评测，输出 Recall@8 / 引用准确率 / 无答案类误答率报告，作为上线调参（阈值、k、N 轮数）输入；验收目标值（85%/90%）与阈值锚点均落运行时配置，调整需 AI管理员确认并入审计 | AC3.1.1、AC3.2.1、AC3.5.1；C-Q1、C-Q3、C-Q4 |

---

## 2. 数据模型

> 全部主键 UUIDv7、时间戳 UTC（specs/README 约定）。`rag_conversations`/`rag_messages` 继承 F10 BaseEntity 公共列（FR10.1.3：id/project_id/created_by/created_at/updated_at/state/audit_ref）；`chunks` 为技术衍生表（非业务对象），不注册 OBJECT_REGISTRY、不占用 state。

### 2.1 chunks（spec §3）

```text
chunks(
  id UUIDv7 PK,
  doc_id→documents, doc_version INT,      # 对应 document_versions.version（FR3.1.1）
  section_id VARCHAR,                     # F1 统一模型 section 标识（A1）
  page INT NULL, bbox JSONB NULL,         # 原文定位（FR3.2.1 source、FR3.4.1）；表格序列化块可空页码
  chunk_index INT, token_count INT,       # 章节内顺序与规模（分块器输出）
  text TEXT,                              # chunk 正文（表格块为「表头: 值」行，FR3.1.1）
  embedding VECTOR(1024),                 # bge-m3（FR3.1.1）；HNSW (vector_cosine_ops) 索引
  tsv TSVECTOR GENERATED ALWAYS AS (to_tsvector('zhcfg', text)) STORED,
                                          # 关键词通道（FR3.1.3）；GIN 索引；zhcfg 与 F2.4 同源（A2、F2 A7）
  kb_version INT NOT NULL,                # 入库时 kb_revision 值（FR3.1.1；审计回溯）
  embed_model VARCHAR,                    # 嵌入模型实测标识（模型更换复嵌入的判别键，C-Q4 Assumptions）
  superseded BOOLEAN DEFAULT false,       # FR3.1.2；delisted（F2 plan A4 下架标记）
  delisted BOOLEAN DEFAULT false,
  ingest_task_id UUID NULL                # 关联 ingestion 任务（幂等去重/重触发，F2 plan A5 风险表）
)
-- 索引：HNSW(embedding cosine)；GIN(tsv)；btree(doc_id, doc_version)；
--       部分索引 btree(kb_version) WHERE superseded=false AND delisted=false（召回主路径）
-- 幂等：UNIQUE(doc_id, doc_version, chunk_index)，任务重触发先删后插同键行
```

### 2.2 会话与消息（spec §3）

```text
rag_conversations(                        # BaseEntity 公共列：id/project_id/created_by/created_at/...
  title VARCHAR NULL,                     # 首问截断生成（确定性截取，非 LLM）
  last_message_at TIMESTAMPTZ
)
rag_messages(
  id UUIDv7 PK, conversation_id→rag_conversations,
  role VARCHAR,                           # user | assistant
  content TEXT,                           # 答案正文（含 [n] 角标原文）
  sources JSONB,                          # FR3.2.1 结构；post-validation 后的最终下发版（A6）
  citations_dropped JSONB NULL,           # 校验失败被剔除的引用（FR3.2.3 记录要求）
  no_hit BOOLEAN DEFAULT false,           # FR3.5.1 兜底答案标记（FR3.5.3 统计源）
  gray_zone BOOLEAN DEFAULT false,        # FR3.5.2 灰区提示标记
  rewritten_query TEXT NULL,              # 改写后检索词（FR3.3.1；审计同源）
  model VARCHAR NULL, prompt_id VARCHAR NULL, prompt_version VARCHAR NULL,
  kb_version INT NULL,                    # 回答时点快照（spec §5 审计字段的消息侧冗余）
  feedback VARCHAR NULL,                  # up | down | null（FR §4 feedback；写入 kpi_events 后回填）
  feedback_comment TEXT NULL
)
```

### 2.3 object_source_link（spec §3，F3.4.2 与 F7.3 共用，A8）

```text
object_source_link(
  id UUIDv7 PK,
  src_type VARCHAR,                       # fmea_row | project（FR3.4.2；F7.3 预留）
  src_id UUID,                            # fmea_rows.id / projects.id
  document_id→documents, doc_version INT,
  page INT NULL, bbox JSONB NULL, quote TEXT,
  created_by→users, created_at
)
-- 索引 (src_type, src_id)；目标对象侧"依据"列表经 GET /api/v1/links?src_type=&src_id= 查询
-- UNIQUE(src_type, src_id, document_id, doc_version, page, quote_digest) 防重复关联
```

### 2.4 金标集扩展（C-Q1、A9）

```text
golden_sets + 新增列 kind VARCHAR DEFAULT 'parse'   # FR10.1.4 只增可空列；'rag' 为检索金标
rag 金标行 expected JSONB：
  {expected_doc_ids: [...], is_unanswerable: bool}  # ≥50 条 query-文档对 + ≥10 条无答案类（C-Q1）
```

### 2.5 横切接入（F10）

- **对象模型**：`rag_conversations/rag_messages` 继承 BaseEntity（project 绑定支撑 FR3.1.5 项目范围与审计维度）；`object_source_link` 连接 RAG 引用与 F10.1 对象图（FmeaRow/Project/Document）。
- **审计**（事件全部 `<domain>.<verb>`，FR10.3.3）：`rag.query`（核心事件——query、改写后 query、model/prompt 版本、kb_version、citations[]、ai_output_id→rag_message、citations_dropped、no_hit/gray_zone 标记；即"AI引用准确率可抽样审计"KPI 的数据来源，spec §5）、`rag.no_hit`（FR3.5.3 独立事件，含改写建议文本）、`rag.link.created`（FR3.4.2）、`rag.threshold.updated`（C-Q4）、`rag.conversation.opened`（C-Q2 开关状态随 rag.query 的 input 记录，不单列）。
- **状态机**：RAG 答案是即时交互产物，非 DRAFT→APPROVED 生成物（specs/README [AI] 草稿语义适用于"产物类"输出；答案无定版动作）；`state` 保留默认值，不注册 transition 配置。
- **KPI**（kpi_events，FR10.6.1）：`rag.first_token`（duration_ms，P95 ≤ 5s）、`rag.no_hit`（支撑 `rag.no_hit_rate` 报表）、`rag.feedback`（up/down）；三者进 F10 plan §2.5 的 KPI SQL 视图。
- **权限**：新权限点 `rag.query`（问答）、`rag.link.manage`（关联操作，工程师+）、`rag.config.manage`（阈值调整，仅 AI管理员，C-Q4）；检索层过滤复用 F2 可见性谓词（A3，FR3.1.4）。

---

## 3. API 设计（遵循 specs/README：REST /api/v1、统一错误体、异步任务 SSE）

### 3.1 端点清单

```text
POST /api/v1/rag/query                    # SSE 流式问答（A4）。body:
                                          #   {query, conversation_id?, scope: "all"|"project"(默认 all),
                                          #    include_superseded: false, top_k?: ≤20}
                                          # 事件流（text/event-stream）：
                                          #   meta      {conversation_id, message_id, gray_zone, rewritten_query?}
                                          #   answer    {delta}                          —— FR3.2.4 增量
                                          #   sources   {sources:[FR3.2.1 结构], degraded:[被剔除引用标记]}
                                          #   done      {message_id, no_hit}
                                          #   error     统一错误体（流中断语义）
                                          # no_hit 路径：meta(no_hit=true) → answer(模板+改写建议) → done
GET  /api/v1/rag/conversations            # 会话列表 ?page&page_size&project_id → {items,total,page}（FR3.3.2）
GET  /api/v1/rag/conversations/{id}       # 会话详情 + 消息历史（含 sources，FR3.3.2 回到历史会话）
POST /api/v1/rag/feedback                 # {message_id, rating: "up"|"down", comment?}（FR §4）
                                          # → kpi_events(rag.feedback) + rag_messages.feedback 回填
POST /api/v1/links                        # 引用关联（FR3.4.2）：{src_type, src_id, document_id,
                                          #   doc_version, page?, bbox?, quote}
GET  /api/v1/links?src_type=&src_id=      # 目标对象侧"依据"列表（F3.4.2 目标可见、F7.3 消费，A8）
DELETE /api/v1/links/{id}                 # 撤销关联（created_by 本人或项目经理）→ rag.link.deleted
PUT  /api/v1/rag/config                   # 检索运行时配置（AI管理员）：no_hit 阈值/灰区上界/top_k/
                                          #   上下文轮数 N → 审计 rag.threshold.updated（C-Q4）
GET  /api/v1/rag/config                   # 当前配置（前端开关/提示条读取灰区带展示逻辑）
```

- **source 结构**（FR3.2.1 全字段 + 定位扩展）：`{document_id, doc_version, project, uploaded_at, snippet, page, bbox, quote, chunk_id, score, is_superseded(历史版本标记+前端提示，C-Q2), quote_verified}`。
- **原文定位**：前端以 `document_id` 取文件下载 URL（F2 文档详情既有能力），pdf.js 渲染跳转 `page`、按 `bbox` 高亮（FR3.4.1）；Excel/Word 经 F1 `GET .../parse` 按 `section_id` 渲染表格/段落快照（复用 F1 parse-viewer 组件，A1）；bbox 需原文定位详情时复用 F1 `GET .../parse/blocks/{id}/source`（F1 plan §3.1）。

### 3.2 语义与错误

- 统一错误体 `{"code","message","detail"}`；本 feature 新增错误码：`QUERY_EMPTY` / `QUERY_TOO_LONG`（输入校验，全局规则边界校验）、`CONVERSATION_NOT_FOUND`、`MESSAGE_NOT_FOUND`（feedback）、`LINK_TARGET_NOT_FOUND`（src_id 不存在）、`LINK_DUPLICATE`、`RAG_CONFIG_FORBIDDEN`（非 AI管理员调配置，403）。
- **权限拒绝一律 403 + 统一错误体**（F10.5）；会话/消息可见性 = 创建人本人 + 项目成员（project 维度），列表接口注入与 A3 同源的可见性谓词。
- **no_hit 不是错误**：HTTP 200，`done.no_hit=true` + 固定模板答案（FR3.5.1），便于前端统一渲染与 no_hit 率统计。
- **异步边界**：仅 ingestion 走 Celery `rag` 队列（task_id 经 `GET /api/v1/tasks/{id}/events` 可观测，对齐 specs/README 任务约定）；在线问答全链路同步 SSE（A4）；目标 `rag.first_token` P95 ≤ 5s（spec §5 KPI）。
- 分页 `{items,total,page}`、复数资源名、UUIDv7、UTC ISO-8601 全局约定适用于全部端点。

---

## 4. AI/LLM 使用点

| 项 | 设计 | 溯源 |
| ---- | ---- | ---- |
| 模型清单 | ① **bge-m3**（嵌入，ingestion 与 query 同模型，1024 维）；② **bge-reranker-v2-m3**（重排）；③ **生成式 LLM**（答案生成 + query 改写）——均私有化部署、经 F10 `LLMGateway`/本地推理服务调用，数据不出企业域（PRD §53）；模型/版本走配置，审计记录运行时实测值 | FR3.1.1、FR3.1.3、FR3.2.1；F10 plan §4 挂点 2 |
| Prompt 策略 | Prompt 注册表管理，禁止裸字符串（FR10.3.4）：`f3.rag_answer`（结构：① 系统指令——"仅基于提供的检索片段作答；每个事实性结论必须附引用编号 [n]；无引用支撑的句子仅允许通用性表述；片段不足以回答时输出'未在知识库中找到相关资料'"；② 编号片段列表——每片段带 [n]、来源文档/项目/时间元信息；③ 可选最近 N 轮摘要）、`f3.query_rewrite`（输入最近 N 轮对话 + 当前问题，输出单一独立完整检索词，温度 0） | FR3.2.2、FR3.3.1；FR10.3.4 |
| 结构化输出 schema | 生成主输出为**流式纯文本**（含 [n] 角标），流结束后由确定性后处理组装 sources（FR3.2.1 结构），并强制 JSON Schema 校验后入审计 `final_result`：`{answer, citations:[{n, chunk_id, quote}], schema_version:"1.0"}`。citations 由答案中 [n] 角标 + 对应片段的句子级对齐确定性抽取，quote 为答案句中受支撑的最小原文跨度（A6 校验对象）；query 改写输出 schema `{rewritten_query}` 单字段校验 | FR3.2.1、FR3.2.3、FR3.2.2；F10 plan §4 挂点 3 |
| 引用后处理校验 | A6：quote ↔ chunk 文本 精确 → 归一化（去空白/标点、全半角折一、小写）→ rapidfuzz 比率 ≥0.85；失败引用剔除 + `[n]†` 脚注 + `citations_dropped` 落库入审计。抽样审计（C-Q3）以此为辅助证据，人工逐条核验"引用确实支撑对应结论"仍为最终口径 | FR3.2.3；AC3.2.1；C-Q3 |
| 兜底与灰区 | 不经 LLM 的固定模板（A5）：no_hit 文本 + 改写建议（模板槽位填充，如"尝试补充料号/文档名/时间范围"）；灰区答案 `meta.gray_zone=true` 触发前端提示条 | FR3.5.1、FR3.5.2；C-Q4 |
| 审计接入 | 每次 query 经 LLMGateway emit `rag.query`（全字段，spec §5）；`rag.no_hit`、`rag.link.created`、`rag.threshold.updated` 见 §2.5；嵌入/重排为 AI 组件，模型标识随 kb_revision ingestion 记录与 chunks.embed_model 留痕 | spec §5；FR10.3.1、FR10.3.3；C-Q4 Assumptions |
| 评测方式 | ① **golden_set_rag_v1**（C-Q1：≥50 条 query-文档对，覆盖密封失效/历史DFM/料号项目三类场景 + ≥10 条无答案类，双人标注+仲裁，版本化）：离线脚本分层评测——检索层 Recall@8 ≥ 85%、端到端引用准确率 ≥ 90%、无答案类误答率 = 0（AC3.5.1 硬门槛）；② 阈值/k/N 上线前网格调参（C-Q4），调参报告版本化；③ 模型或词典变更后全量回归（C-Q4 Assumptions：视同 kb/模型版本变更）；④ 线上抽样审计按 C-Q3：AI管理员每月 ≥50 条分层抽样（有答案/灰区/no_hit），<90% 或误答 >0 触发专项复检与调优记录 | AC3.1.1、AC3.2.1、AC3.5.1；C-Q1–C-Q4 |

---

## 5. 测试策略

| 层级 | 内容 | 溯源 |
| ---- | ---- | ---- |
| 单元 | 分块器：章节边界切分、512 目标合并/1024 上限句子级拆分、表格序列化「表头: 值」、token 计数边界；RRF 融合排序；阈值带判定（<0.30 / 0.30–0.45 / ≥0.45 三分支）；quote 归一化匹配器（精确/归一化/模糊三级、全半角与标点用例）；引用角标抽取与剔除后角标重标；改写触发条件（首轮跳过、N 轮窗口截断） | FR3.1.1、FR3.1.3、FR3.2.3、FR3.3.1、FR3.5.1/3.5.2；C-Q4 |
| 集成（ingestion） | PARSE_CONFIRMED 事件 → chunk 入库携带 doc_id/doc_version/section_id/page/bbox/kb_version 全字段（FR3.1.1）；含表格文档的序列化正确性；kb_revision(INGEST) 回调 +1 且幂等（同任务重触发不重复计数，F2 A5）；新版本生效 → 旧版 chunk superseded=true + kb_revision(SUPERSEDE)（FR3.1.2、C-Q4）；下架 → delisted=true 且三通道（检索/推荐/召回）不可见（F2 plan A4 联动） | FR3.1.1、FR3.1.2；C-Q4；F2 plan A5 |
| 集成（检索与权限） | 混合召回：语义问法命中案例类、料号精确词命中 tsvector 通道（FR3.1.3）；**权限过滤在 SQL 层**——无项目权限用户的候选池不含该文档 chunk（池内计数断言，非结果过滤）（FR3.1.4）；scope=all/project 两分支（FR3.1.5）；include_superseded=false 默认排除、true 时命中且 source 带历史版本标记 + 开关状态入 rag.query 审计（C-Q2） | FR3.1.2–FR3.1.5；C-Q2；AC2.6.1 同源 |
| 集成（生成与引用） | 答案流式事件序列契约 meta→answer*→sources→done（FR3.2.4）；sources 字段完备性（document_id/doc_version/project/uploaded_at/snippet/page/bbox/quote，FR3.2.1）；quote 校验三级匹配与降级剔除（citations_dropped 落库）（FR3.2.3）；no_hit 路径不调用 LLM（stub 断言零调用）+ 模板与改写建议（FR3.5.1）；灰区标记（FR3.5.2）；无答案类金标问题端到端误答率 = 0（AC3.5.1）；审计 rag.query 字段完备性 schema 校验（F10 plan §5 同款门槛） | FR3.2.1–FR3.2.4、FR3.5.1–FR3.5.3；AC3.5.1；C-Q4 |
| 集成（会话/反馈/关联） | 追问改写：第二轮以指代问法触发改写、改写词入消息与审计（FR3.3.1）；历史会话恢复追问（FR3.3.2）；feedback 落 kpi_events + 消息回填；link 创建/查询/删除与 UNIQUE 防重（FR3.4.2、A8）；F7 消费侧契约测试（fmea_row 侧"依据"列表可读，AC1.6.1 式桩测试精神） | FR3.3.1、FR3.3.2、FR3.4.2；F7.3 |
| 金标评测 | golden_set_rag_v1 全量脚本：Recall@8 ≥ 85%、引用准确率 ≥ 90% 作为 M2 Exit 硬门槛（C-Q1）；分场景（三类典型问法）分项报表；阈值网格调参产出 C-Q4 锚点验证报告；嵌入模型替换回归流程演练 | AC3.1.1、AC3.2.1、AC3.5.1；C-Q1、C-Q4 |
| API 契约 | SSE 事件 payload schema 与错误流语义；统一错误体/分页信封；POST /rag/query 输入校验（空/超长）；配置接口权限矩阵（AI管理员 vs 工程师 403） | specs/README；C-Q4；FR3.5.1 |
| 性能 | 压测：语料 10 万 chunk 规模下召回+重排+首 token P95 ≤ 5s（spec §5）；SSE 长连接并发下的连接池与超时策略；pgvector HNSW 参数（ef_search）与召回率权衡记录 | spec §5 KPI（rag.first_token） |
| 前端 | 流式答案渲染与 [n] 角标点击定位 source 卡片（AC3.2.2 可点击定位）；source 卡片四要素展示 + [查看原文]（pdf.js page 跳转 + bbox 高亮；Excel/Word 快照）（FR3.4.1）；[关联到当前FMEA/项目] 对话框与目标侧"依据"展示（FR3.4.2）；no_hit 模板与改写建议展示；灰区提示条；「包含历史版本」开关 + 历史版本徽标（C-Q2）；点赞点踩；会话列表/历史恢复（FR3.3.2） | AC3.2.2、FR3.4.1、FR3.4.2、FR3.5.1/3.5.2；C-Q2 |

覆盖率目标遵循全局规则（新增模块 ≥80%）。

---

## 6. 风险与非目标

### 风险

| 风险 | 影响 | 缓解 |
| ---- | ---- | ---- |
| 首 token P95 ≤ 5s 失守（改写 + 召回 + 重排 + LLM 首字串行叠加） | spec §5 KPI 失败 | 首轮跳过改写（A7）；HNSW 近似召回 + 两通道并行执行；重排批量一次推理；first_token 埋点分阶段计时（recall/rerank/llm 分段 duration 入 meta.meta），超标段可定位；SLO 持续失守时引入 query 缓存与常见问法缓存 |
| LLM 引用格式漂移（漏标 [n]、编造编号） | 引用准确率/AC3.2.2 失守 | A6 代码级校验兜底（编造编号无对应 chunk 直接剔除）；prompt 少样例强化；citations_dropped 率进抽样审计观测，>5% 触发 prompt 调优记录（C-Q3 闭环） |
| 阈值锚点（0.30/0.45）不适配实际语料分布 | 误杀（该答未答）或漏杀（AC3.5.1 误答 >0） | C-Q4 明确锚点仅为调参起点；上线前金标网格调参定值入配置；灰区带提供缓冲；误答率为硬门槛、上线检查表含 ≥10 条无答案类回归用例 |
| 嵌入/重排模型更换导致全量向量失效 | 检索质量退化、阈值失效 | chunks.embed_model 留痕；模型更换视同 kb/模型版本变更：全量复嵌入 + 重跑金标集 + 复审阈值（C-Q4 Assumptions），走 kb_revision 全量登记 |
| pgvector 规模化后向量召回延迟/召回率下降 | 首 token SLO 与 Recall 双承压 | HNSW 参数化（m/ef_construction/ef_search 入配置）；部分索引收缩主路径；10 万 chunk 压测前置到 M2 中期；超规模再评估分区或独立向量库（Phase 2 预留，不在本期范围） |
| zhparser 依赖与词典质量传导至关键词通道 | 混合检索退化为纯向量 | 与 F2.4 共用同一配置与词典维护流程（F2 plan A7 风险同源，降级预案一致：default 配置 + jieba 应用层分词）；金标集分通道观测贡献度 |
| F2 事件与 ingestion 的最终一致性（进程内事件、任务失败） | chunk 与 kb_version 漂移 | 幂等键 UNIQUE(doc_id, doc_version, chunk_index)；kb_revision 以 ingest_task_id 去重；对账任务比对 ingest_state 与 chunk 存在性，偏差告警、任务可重触发（F2 plan A5 风险表同源） |
| 长文档表格密集导致 chunk 质量差（序列化行丢失结构语义） | 检索命中率与引用质量下降 | 表格序列化保留表头上下文 + 行级 chunk_index 可回溯；金标集含参数表密集文档（三类场景标注时强制覆盖）；表格整表 ≤1024 token 时优先整表成块 |
| 会话/消息无配额控制被滥用（超长上下文、高频问答） | 成本与性能 | QUERY_TOO_LONG 上限、N 轮窗口硬上限、每用户速率限制（require_perm 之外的中间件限流），超限统一错误体 |

### 非目标（Phase 1）

- 跨语言检索、多模态（图片内容检索）、自动语料爬取、知识图谱推理（spec §6）
- 跨版本对比检索（C-Q2 Assumptions：include_superseded 仅单版本命中，不做版本间 diff）
- 抽样审计自动评分工具（C-Q3 Assumptions：F10.4 导出报表 + 人工核验）
- 通用开放式对话、闲聊、非知识库问题回答（属 F4 AI Chat 职责；F3 严格限定知识库 grounded QA）
- 重排模型微调/嵌入模型训练、查询意图分类器、HyDE 等高级检索增强（金标集不达标时的后续立项项）
- 多知识库/租户隔离（单企业域部署，PRD §53）
- 答案的人工"定版"流（RAG 答案为即时交互产物，无 DRAFT→APPROVED 状态机接入，§2.5）

---

## 7. 决策与假设记录（承接 clarifications）

- C-Q1：验收目标 Recall@8 ≥ 85%、引用准确率 ≥ 90% 正式化；金标集 golden_set_rag_v1（≥50 对 + ≥10 条无答案类，双人标注+仲裁，复用 F1 golden_sets 机制加 kind 列）。→ §2.4、§4 评测、§5 金标评测、A9
- C-Q2：历史版本默认不检索；`include_superseded` 请求级开关（默认 false），命中标注历史版本提示，开关状态入 `rag.query` 审计。→ A3、§3.1、§5
- C-Q3：AI管理员每月分层抽样 ≥50 条人工核验；<90% 或误答 >0 触发复检与调优记录；Phase 1 无自动评分工具。→ §4 评测、§6、§2.5 审计
- C-Q4：阈值锚点 0.30（no_hit）/ 0.45（灰区上界）仅为调参起点；运行时配置 + AI管理员可调 + `rag.threshold.updated` 审计（记录当时 kb_version）；模型更换视同 kb/模型版本变更需重跑金标与复审阈值。→ A5、§3.1、§4、§6
- 新增决策（无对应 Q，依 FR 推定）：**A4 在线问答为同步 SSE 而非异步任务**——spec §4 明确 query 端点为 SSE 流式，且首 token SLO 排斥任务轮询模式；ingestion 仍走任务队列可观测。**A6 引用校验代码强制**（与 F1 A6 grounding 同构）。**A8 object_source_link 单表共用**（spec §3 明示 F3.4.2 与 F7.3 共用）。**A7 检索仅用改写后查询**（历史上下文不进召回，防污染）。**答案不接入 DRAFT→APPROVED 状态机**（即时交互产物，specs/README 草稿语义针对"产物类"AI 输出；RAG 引用进入正式体系的人工动作是 F3.4.2 显式 link，该动作本身即人工确认）。
- 假设：bge-m3/bge-reranker 以本地推理服务形态随部署交付（私有化"外呼=空"检查表覆盖，对齐 F2 plan §4）；`rag_conversations.title` 为首问确定性截取；改写轮数 N=3、top_k=8 为默认配置值（均可经 /rag/config 调整）；金标标注资源延迟时先以我方自建金标集内部验收、客户金标就绪后复测（沿用 C-Q1 Assumptions）。
