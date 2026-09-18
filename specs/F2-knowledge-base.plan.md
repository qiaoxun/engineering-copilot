# F2 企业知识库 — 技术方案（Plan）

| | |
| ---- | ---- |
| Feature | F2-knowledge-base |
| 输入 | specs/F2-knowledge-base.md、specs/F2-knowledge-base.clarifications.md（冲突时以其为准）、PHASE1_SPEC.md、PHASE1_FEATURES.md、specs/README.md |
| 关联 | specs/F1-document-parsing.plan.md（上传/解析管线边界）、specs/F10-platform-governance.plan.md（对象模型/状态机/审计/RBAC）、specs/F3-rag-retrieval.md（ingestion/chunk/kb_version 契约） |
| 阶段 | speckit-plan（仅设计，不写代码） |
| 里程碑 | M2 |

> 本 plan 中所有设计决策均标注溯源（FR/AC/Q 编号）。clarifications（Q1–Q4 决策）全文有效，本文引用处标注为「C-Qx」。

---

## 1. 架构与模块落点

### 1.1 总体架构

对齐既定技术栈：**后端 FastAPI 模块化单体 + Celery + PostgreSQL(pgvector) + MinIO；前端 React + TypeScript + Ant Design**。F2 落在独立顶层模块 `modules/kb/`（与 F10 plan §1.2 的模块清单一致），负责文档全生命周期（上传/版本/分类/关联/检索/推荐/权限），**解析继续走 F1 `documents` 管线、chunk/embed 继续走 F3 ingestion**——F2 是三者的编排者与状态源（文档、版本、kb_revision），不自建解析与向量化能力（FR2.3.2、FR3.1.1 边界）。

```text
apps/backend/
├── app/
│   ├── core/                        # F10 平台地基（F10 plan）
│   ├── modules/
│   │   ├── documents/               # F1：解析管线（F2 仅调用其任务入口与读取 API）
│   │   ├── kb/                      # ← F2 本体
│   │   │   ├── api/                 # 文档/版本/分类/标签/关联/搜索/推荐/可见性路由
│   │   │   ├── upload/              # F2.1：预检(dedup/同名) + 指令化入库 + 批次编排
│   │   │   ├── versions/            # 版本号管理、历史、current_version 切换
│   │   │   ├── taxonomy/            # F2.2 分类树（固定 7 顶级 + 子分类 ≤3 层）
│   │   │   ├── links/               # F2.3 文档↔项目(M2M)/产品(N—1)关联
│   │   │   ├── search/              # F2.4 zhparser 全文检索 + 组合筛选 + 权限过滤
│   │   │   ├── recommend/           # F2.5 最近更新 + 项目上下文向量推荐
│   │   │   ├── lifecycle/           # 软删除/下架、生命周期事件发布、kb_revision 登记
│   │   │   └── visibility/          # F2.6 可见性判定（Casbin domain 模型）+ 查询层过滤谓词
│   │   ├── rag/                     # F3：chunk/embed ingestion（订阅 F2 生命周期事件）
│   │   └── platform/                # F10：objects/workflow/audit/rbac/kpi（见 F10 plan）
│   ├── worker/                      # Celery：kb 队列（版本生效/下架联动、推荐预热可选）
│   └── main.py
└── alembic/
apps/frontend/
└── src/
    ├── pages/kb/                    # UI 页面22：文档列表/筛选、上传向导、详情+版本历史
    ├── pages/kb/taxonomy/           # 分类树管理（AI管理员）
    ├── features/uploader/           # 批量上传、逐文件结果汇总、去重/同名决策对话框
    ├── features/search/             # 搜索结果命中高亮、组合筛选器
    └── features/recommend/          # "与当前项目相关的历史案例 N 个"卡片（UI 页面01 首页复用）
```

### 1.2 核心流程

```text
上传（F2.1）：预检 upload-check（SHA-256 + 同名检测，逐文件结果）
  → 用户决策（跳过 / 新关联 / 新版本 / 独立文档，FR2.1.2/2.1.3）
  → POST documents+directives：逐文件建 document/document_version（逻辑记录，MinIO 内容寻址不复制，C-Q3）
  → 复用 F1.1 校验 + 入 F1 parse 队列 → PARSE_CONFIRMED
  → F2 发布 document.ingestable 事件 → F3 ingestion（chunk+bge-m3 嵌入）
  → F2 kb_revision 登记（kb_version+1，affected_document_ids，specs/README 数据契约）

新版本生效（C-Q4）：v_n PARSE_CONFIRMED → current_version 切换
  → F2 发布 document.superseded 事件 → F3 置旧版 chunk superseded=true → kb_revision +1

删除（C-Q2）：GET references（FMEA/报告/RAG 引用链）→ 前端展示 + 二次确认
  → 软删除 = 下架：deleted_at 置位、检索/推荐/RAG 召回全通道排除、chunk 标 delisted
  → 对象/版本/引用记录完整保留（审计追溯），无物理删除入口
```

### 1.3 关键架构决策

| # | 决策 | 溯源 |
| ---- | ---- | ---- |
| A1 | **上传两阶段指令化**：阶段一 `upload-check` 服务端计算 SHA-256 并做全库比对 + 同名检测，逐文件返回 `NEW / DUPLICATE / NAME_CONFLICT`；阶段二携带 per-file directives（`create / link_existing / new_version(target_doc)`）执行。两阶段都逐文件隔离，单文件失败不建任何记录、不影响批次 | FR2.1.1、FR2.1.2、FR2.1.3；AC2.1.2 |
| A2 | **MinIO 内容寻址存储**：对象 key = `sha256/<hash>`，`document_versions.file_key` 为逻辑引用；相同 SHA-256 共享物理对象，"仍作为新关联上传"只新建逻辑记录（C-Q3）。物理对象删除仅随数据保留策略（Phase 1 非目标），软删除期间物理对象一律保留 | FR2.1.2；C-Q3、C-Q2 |
| A3 | **分类固定、标签自由的正交设计**：7 个顶级分类为种子数据 `is_fixed=true`，无新建/删除入口，仅 AI管理员可增删子分类（树深 ≤3 由 service + DB CHECK 双重约束）；标签不预置，自由创建 + `document_tags` 频次聚合提供"常用标签"只读接口（C-Q1）。文档多分类用 M2M 而非 spec §3 示意的外键列（spec §3 为"核心字段"摘要，FR2.2.3 多分类语义优先） | FR2.2.1–FR2.2.3；C-Q1 |
| A4 | **删除 = 软删除 + 全通道下架**：`documents.deleted_at` 置位后，搜索（F2.4）、推荐（F2.5）、RAG ingestion/召回（F3.1 chunk 标 `delisted`）同步排除；删除前强制引用方列表确认（实时查询 `object_source_link` + FMEA/报告外键，不做引用计数冗余，clarifications Assumptions）；任何角色无物理删除入口 | FR2.1.5；C-Q2；AC2.1.1（历史保留） |
| A5 | **kb_revision 由 F2 登记、事件驱动**：F2 通过进程内 domain event（`document.ingestable / superseded / delisted`）通知 F3，F3 完成 chunk 写入/标记后回调 F2 `kb_revision_service.record()` 递增 kb_version；`kb_revision` 是 kb_version 唯一事实源，F10 审计经 `kb_version_service.current()` 读取。单体内进程事件 + 显式回调接口，不引入消息中间件 | specs/README 数据契约（kb_version）；FR3.1.1、FR3.1.2；C-Q4 |
| A6 | **权限判定 Casbin 化、过滤谓词同源**：引入 pycasbin 作 F10.5 `require_perm` 之下的文档可见性判定引擎（domain 模型：`sub, dom=project, obj=document, act`），策略数据源即 F10 `project_members`/`departments`（不做第二套策略存储）；列表/搜索/推荐共用同一 SQL 可见性谓词（`visibility='COMPANY' OR 项目成员 OR 部门规则 OR created_by=self`），谓词生成函数与 Casbin 策略同源（同一配置表），保证 API 拒绝（403）与查询层过滤口径一致 | FR2.6.1、FR2.4.3、FR2.3.2；AC2.6.1 |
| A7 | **中文分词单一配置**：PG zhparser 扩展 + 工程自定义词典文件随部署产物交付（`zhparser.custom_dict`），F2.4 全文搜索与 F3.1.3 tsvector 关键词通道共用同一 text search configuration（`zhcfg`）与同一 GIN 索引策略；词典替换+重载走 AI管理员维护流程（无在线编辑 UI，clarifications Assumptions） | FR2.4.1；C-Q1；FR2.6.2 |
| A8 | **AI 推荐为嵌入检索、非生成式**：项目上下文向量（项目关联文档 chunk 嵌入加权聚合 + 项目元信息关键词通道）在**非本项目**文档库中混合检索 top-N；推荐理由为**证据式**（命中的本项目源文档 + 匹配 chunk 片段 + 主题词重叠），不调用生成式 LLM——理由文本可回溯到具体证据，规避幻觉与生成审计负担 | FR2.5.2、FR2.5.3；AC2.5.1 |
| A9 | **版本并发安全**：同名新版本号分配在 documents 行级锁（SELECT FOR UPDATE）内递增，避免并发上传产生重复版本号；`document_versions.version` 以 `UNIQUE(document_id, version)` 兜底；SHA-256 允许多逻辑记录（不设唯一约束，C-Q3 语义） | FR2.1.3、FR2.1.4；C-Q3 |
| A10 | **文档 state 与解析状态解耦**：`documents.state`（F10 BaseEntity）承载 M2 文档治理态；F1 `parse_results.status` 继续承载解析生命周期（F1 plan A8 约定互不占用）。Phase 1 文档默认态即"已入库"（无文档审批流，spec §6 非目标），state 仅预留 F10 通用状态机接入位 | spec §6 非目标；FR10.1.3；F1 plan A8 |

---

## 2. 数据模型

> 全部主键 UUIDv7、时间戳 UTC（specs/README 约定）。`documents` 为 F1/F2 共享表（F10 plan §2.2 已定义）：F1 拥有解析列，F2 以**增量可空列**扩展知识库列（FR10.1.4 只增不删约定）。

### 2.1 documents（F10 对象模型 Document，扩展 F2 列）

```text
documents(
  # F1 既有列（F1 plan §2.1）：id, project_id, created_by, created_at, updated_at,
  #   state, audit_ref, filename, file_ext, file_type, size_bytes, storage_key,
  #   page_count, current_parse_result_id
  # F2 增量列（FR10.1.4：新增可空列）：
  name VARCHAR NOT NULL DEFAULT filename,   # 展示名（spec §3 name）
  current_version INT NOT NULL DEFAULT 1,   # 指向 document_versions.version（C-Q4 生效语义）
  visibility VARCHAR DEFAULT 'PROJECT_INHERIT',  # PROJECT_INHERIT | COMPANY（FR2.6.1 覆盖标记）
  deleted_at TIMESTAMPTZ NULL,              # 软删除标记 = 下架标记（FR2.1.5、C-Q2）
  delisted_by→users NULL, delist_reason VARCHAR NULL
)
```

### 2.2 document_versions / categories / tags（spec §3）

```text
document_versions(
  id UUIDv7 PK, document_id→documents,
  version INT,                              # 同名新版本 +1（FR2.1.3），UNIQUE(document_id, version)，A9
  file_key VARCHAR,                         # MinIO 内容寻址 'sha256/<hash>'（A2、C-Q3）
  sha256 CHAR(64),                          # 去重比对键（FR2.1.2），索引（非唯一，C-Q3）
  size_bytes BIGINT, change_note VARCHAR NULL,
  parse_result_id→parse_results NULL,       # 该版本的解析结果（F1 契约，FR1.6.4）
  ingest_state VARCHAR,                     # NONE/PENDING/INGESTED/SUPERSEDED/DELISTED（F3 联动，C-Q4）
  uploaded_by→users, uploaded_at            # FR2.1.4 版本历史四要素
)
categories(
  id UUIDv7 PK, parent_id→categories NULL, name VARCHAR,
  is_fixed BOOLEAN,                         # 7 个顶级 is_fixed=true 种子（FR2.2.1）
  depth INT CHECK (depth <= 3),             # 树深 ≤3（FR2.2.2），与 service 校验双保险（A3）
  UNIQUE(parent_id, name)
)
document_categories(document_id, category_id, PK(document_id, category_id))   # ≥1 由 service 强制（FR2.2.3）
tags(id UUIDv7 PK, name VARCHAR UNIQUE, created_by, created_at)                # 不预置（C-Q1）
document_tags(document_id, tag_id, PK(document_id, tag_id),
              created_by, created_at)         # 频次聚合源（C-Q1 Assumptions）
```

### 2.3 关联与 kb_revision（spec §3、FR2.3）

```text
document_projects(document_id, project_id, PK(document_id, project_id))
  # 文档↔项目 M2M（FR2.3.1；F10 plan §2.2 同名表，F2 负责业务语义）
  # products N—1 复用 documents.product_id（F10 plan 已有列，可空，FR2.3.1）

kb_revisions(
  id UUIDv7 PK,
  kb_version INT UNIQUE,                    # 严格递增（specs/README：每次 ingestion 生效 +1）
  trigger VARCHAR,                          # INGEST / SUPERSEDE / DELIST（A5、C-Q2、C-Q4）
  affected_document_ids UUID[],             # spec §3 字段
  document_version_ids UUID[],              # 精确到版本（C-Q4 切换审计需要）
  applied_at TIMESTAMPTZ
)
-- 只追加不修改；当前 kb_version = MAX(kb_version)，由 kb_version_service 提供缓存读
```

### 2.4 横切接入（F10）

- **对象模型**：documents 是 F10.1 Document 实体本体；`document_projects`/`product_id` 即"扩展知识库关联"的 M2 落地（FR10.1.2、PHASE1_FEATURES §6 映射表）。
- **审计**：事件全部 `<domain>.<verb>`——`document.uploaded / version.created / deleted / acl.changed / kb.revision_applied / category.updated / tag.created`（FR2 §5、FR10.3.3 命名约定）；`acl.changed` 记录 visibility 变更前后值（FR2.6.1）。
- **状态机**：文档无定版流（spec §6 非目标），Phase 1 不注册 transition 配置；`state` 预留。
- **KPI**：无独立 KPI（spec §5）；`kb_revision.kb_version` 是 F10.3 审计"知识库版本"字段来源（`kb_version_service.current()`，specs/README 数据契约）。

---

## 3. API 设计（遵循 specs/README：REST /api/v1、统一错误体、异步任务 SSE）

### 3.1 端点清单

```text
POST /api/v1/documents/upload-check        # 阶段一预检（multipart）：逐文件 sha256/同名检测
                                           # → [{filename, sha256, verdict: NEW|DUPLICATE|NAME_CONFLICT,
                                           #    existing: {doc_id, version, uploader} | 同名文档列表}]
POST /api/v1/documents                     # 阶段二执行（multipart + directives JSON）：
                                           #   files[].action = create|link_existing|new_version|skip
                                           #   create 附 {name, category_ids, tag_ids, project_ids, product_id?}
                                           #   new_version 附 {target_document_id, change_note?}
                                           # 逐文件结果汇总返回；create 触发 F1 parse → task_ids[]（FR2.1.1）
GET  /api/v1/documents                     # 列表：?category_id&project_id&tag&uploaded_by&from&to
                                           # &sort=updated|relevance&page&page_size → {items,total,page}
GET  /api/v1/documents/search?q=           # 全文检索：zhparser 分词 + 组合筛选 + 命中片段高亮
                                           # （ts_headline）+ 相关度/更新时间排序（FR2.4.1/2.4.2）
GET  /api/v1/documents/{id}                # 详情：元数据 + 分类/标签/关联 + 版本历史（FR2.1.4）
GET  /api/v1/documents/{id}/versions/{v}   # 历史版本查看（AC2.1.1：v1 上传 v2 后仍可查看）
POST /api/v1/documents/{id}/versions       # 直接为新版本入口（已知 target 时可跳过预检，FR2.1.3）
GET  /api/v1/documents/{id}/references     # 引用方列表（FMEA/报告/object_source_link 实时查询，C-Q2）
DELETE /api/v1/documents/{id}              # 软删除+下架；body 携带 references_ack 确认标记（FR2.1.5、C-Q2）
PUT  /api/v1/documents/{id}/visibility    # PROJECT_INHERIT ⇄ COMPANY（FR2.6.1）→ document.acl.changed
PUT  /api/v1/documents/{id}/links          # 批量更新项目/产品/分类/标签关联（FR2.3.1、FR2.2.3）
GET  /api/v1/documents/recent              # 首页最近更新（可见范围内，FR2.5.1）
GET  /api/v1/projects/{id}/recommendations # AI 推荐：{items:[{document, reason, evidence}], n}
                                           # reason/evidence 结构见 §4（FR2.5.2/2.5.3）
GET/POST /api/v1/kb/categories             # 树查询 / 子分类创建（AI管理员，FR2.2.1/2.2.2）
DELETE /api/v1/kb/categories/{id}          # 仅非固定、无子节点、无文档关联时可删（FR2.2.1/2.2.3）
GET  /api/v1/kb/tags?popular=true          # 标签列表 + 常用标签频次聚合（C-Q1）
GET  /api/v1/kb/version                    # 当前 kb_version（审计/调试用，specs/README 数据契约）
```

### 3.2 语义与错误

- 统一错误体 `{"code","message","detail"}`；本 feature 新增错误码：
  - `DUPLICATE_CONTENT`（FR2.1.2 预检命中，非错误而是决策提示，`detail.existing` 携带"文档名/版本/上传人"）、`NAME_CONFLICT`（FR2.1.3）、`CATEGORY_REQUIRED`（FR2.2.3 ≥1 分类）、`CATEGORY_DEPTH_EXCEEDED` / `CATEGORY_FIXED`（FR2.2.2/2.2.1）、`DOCUMENT_HAS_REFERENCES`（FR2.1.5 未携带确认删除被拒，`detail.references[]` 附引用方列表）、`CATEGORY_IN_USE`（FR2.2.3）。
- **权限拒绝一律 403 + 统一错误体**（AC2.6.1）：列表/搜索/推荐在查询层注入可见性谓词（A6），无权限文档不出现于结果；直接访问无权限文档详情返回 403 而非 404（FR2.4.3、FR2.6.1）。
- **异步边界**：上传阶段二为同步入库（建记录+入 F1 parse 队列），解析进度沿用 F1 `task_id`/SSE；ingestion 完成与版本切换由 F3 ingestion 任务承载（其 task 经 `GET /api/v1/tasks/{id}/events` 可观测）。推荐检索为同步只读接口，目标 P95 ≤ 2s（PRD §52 交互响应精神），超预算转 Celery `kb` 队列 + SSE。
- 分页 `{items,total,page}`、复数资源名、UUIDv7、UTC ISO-8601 全局约定适用于全部端点。

---

## 4. AI/LLM 使用点

| 项 | 设计 | 溯源 |
| ---- | ---- | ---- |
| AI 使用范围 | **嵌入检索（bge-m3，经 F3 复用）+ 确定性证据聚合**；**无生成式 LLM 调用**（推荐理由为证据式，A8）。嵌入模型属 AI 组件，纳入私有化"外呼=空"检查表 | FR2.5.2；FR2.6.2；C-Q1 |
| 推荐算法 | ① 项目上下文构建：`document_projects` 取当前项目关联文档的 current_version chunk 嵌入，按分类权重（测试/质量/FMEA 类加权）+ 时间衰减聚合为项目向量；② 项目元信息（名称/描述）经 zhparser 抽关键词走 tsvector 通道（混合检索，与 C-Q1 单一分词配置一致）；③ 候选池 = 全库可见文档中**排除本项目文档**（"历史案例"语义，其他项目的经验复用），权限谓词过滤（A6）；④ 向量 top50 + 关键词 top50 → RRF 融合（复用 F3.1.3 融合器），top-N（默认 N=5，配置可调） | FR2.5.2、FR2.3.2；FR2.4.3；FR2.6.1 |
| 推荐理由（结构化输出 schema） | 无 LLM 生成，schema 即推荐 API 响应契约：`{items: [{document_id, doc_version, score, reason: {source_document_id(本项目命中源文档), matched_snippet(chunk 片段, 带 page/bbox), shared_theme_terms[](zhparser 抽取的主题词交集), source_project}, }], n, generated_by: "embedding+rrf@<algo_version>"}`。`reason` 三要素直接对应 FR2.5.3"与项目中哪份文档/哪个主题相关" | FR2.5.3、AC2.5.1 |
| 排除与下架联动 | 推荐候选池排除 `deleted_at` 非空、`ingest_state IN (SUPERSEDED, DELISTED)` 的版本（C-Q2/C-Q4：下架即全通道退出）；冷启动（项目无关联文档）返回空列表 + 明确提示，不报错、不降级为全库热门 | FR2.3.2、FR2.5.2；C-Q2、C-Q4 |
| Prompt 策略 | **无 prompt**（无生成式调用），故无 prompt_registry 条目；若 Phase 2 引入 LLM 润色推荐理由，再按 FR10.3.4 注册 `f2.recommend_reason`。本决定记入 §7 | FR10.3.4（前瞻）；A8 |
| 审计接入 | 推荐调用 emit `document.recommended`（读类事件，记录 project、算法版本、kb_version、命中 doc_ids）；上传/版本/删除/可见性事件见 §2.4；嵌入模型标识随 kb_revision 的 ingestion 记录留痕（F3 侧） | FR10.3.1、FR10.3.3；specs/README（AI 操作必须审计） |
| 评测方式 | ① **金标推荐集**：AC2.5.1 金标场景抽验扩展为 ≥20 个"项目→历史案例"标注对（含密封结构→密封失效案例金标项），离线脚本计算 Recall@N 与 MRR，验收门槛 Recall@5 ≥ 60%（内部目标，上线前与业务方核定后版本化 `golden_set_rec_v1`，标注机制沿用 F1 双人+仲裁）；② 推荐理由可核验率：抽验 reason.source_document_id 与 matched_snippet 确属命中证据（应为 100%，确定性生成保证）；③ 词典/嵌入模型变更后回归跑分 | AC2.5.1；FR2.5.3；C-Q1（机制复用） |

---

## 5. 测试策略

| 层级 | 内容 | 溯源 |
| ---- | ---- | ---- |
| 单元 | SHA-256 计算与 DUPLICATE/NAME_CONFLICT 判定矩阵；版本号分配（含并发模拟）；分类树深度校验（≤3 拒绝第 4 层）与固定分类保护；可见性谓词生成（COMPANY/项目成员/部门/自建四分支）；kb_version 递增与并发登记串行化；推荐聚合权重与冷启动分支 | FR2.1.2/2.1.3、FR2.2.1/2.2.2、FR2.6.1、A5、A9；C-Q4 |
| 集成（上传与版本） | 批量 50 文件含坏文件 → 逐文件结果汇总、坏文件零记录、余文件成功（FR2.1.1）；同内容重复上传 → 预检 DUPLICATE 且 existing 信息正确（AC2.1.2）；同名不同内容 → new_version 路径版本 +1、历史保留、v1 可查看（AC2.1.1、FR2.1.4）；link_existing 路径仅建逻辑记录且 MinIO 对象数不增（C-Q3）；并发双上传同名 → 版本号不重复（A9） | FR2.1.1–FR2.1.4、AC2.1.1、AC2.1.2；C-Q3 |
| 集成（检索与权限） | zhparser 中文 query 命中（含自定义词典词）+ 分类/项目/时间/标签/上传人组合筛选（FR2.4.1）；命中片段 `ts_headline` 高亮与双排序（FR2.4.2）；**权限过滤在 SQL 层**：无项目权限用户搜索不可见、直取详情 403（AC2.6.1、FR2.4.3）；visibility=COMPANY 覆盖后跨项目可见且 acl.changed 审计（FR2.6.1） | FR2.4.1–FR2.4.3、FR2.6.1、AC2.6.1；C-Q1 |
| 集成（删除与下架） | 有 FMEA 引用的文档删除 → references 返回引用方列表、无确认被拒；确认后 deleted_at 置位 → 搜索/推荐/模拟 F3 召回三通道均不可见，但详情/版本历史/引用记录可查（C-Q2）；删除触发 `document.deleted` + kb_revision(DELIST) + kb_version+1（A5）；版本历史页 v1/v2 均保留 | FR2.1.5、AC2.1.1；C-Q2、C-Q4 |
| 集成（ingestion 契约） | 以 F3 ingestion 桩实现订阅事件：document.ingestable → 桩完成 → kb_revision(INGEST)+1；新版本 PARSE_CONFIRMED → 桩置旧版 superseded → kb_revision(SUPERSEDE)；断言事件/回调顺序与 kb_version 严格递增（A5）；下游以桩消费 `GET /api/v1/kb/version`（specs/README 契约） | FR3.1.1/FR3.1.2（契约侧）；C-Q4；specs/README |
| 推荐 | 金标推荐集离线评测（密封结构项目 → 密封失效案例命中，AC2.5.1）；排除本项目文档断言；冷启动空列表；权限谓词在推荐结果生效（FR2.4.3 精神）；reason 三要素与 evidence 一致性断言 | FR2.5.1–FR2.5.3、AC2.5.1 |
| API 契约 | 统一错误体/分页信封/SSE 事件契约；upload-check 与 directives 两阶段请求/响应 schema；403 与查询层过滤口径一致性（同一可见性谓词函数的单测+集成双重覆盖，A6） | specs/README、AC2.6.1 |
| 权限矩阵 | 5 角色 × 文档操作（view/upload/edit_category/manage_taxonomy/delete/visibility）参数化矩阵，与 `role_permissions` 种子同源（F10 plan §5 模式）；分类树管理仅 AI管理员（spec §5） | FR2.6.1、FR2.2.1；F10.5 |
| 前端 | 上传向导：逐文件进度/结果汇总、去重提示与三选一对话框、同名决策；分类树组件（固定顶级不可删）；搜索高亮渲染；删除二次确认展示引用方列表；推荐卡片"查看历史案例"入口 + reason 展示（UI 页面22/01） | FR2.1.1–FR2.1.5、FR2.2.1、FR2.4.2、FR2.5.3 |

覆盖率目标遵循全局规则（新增模块 ≥80%）。

---

## 6. 风险与非目标

### 风险

| 风险 | 影响 | 缓解 |
| ---- | ---- | ---- |
| zhparser 依赖 PG 扩展编译与词典维护，客户环境 PG 发行版可能不含 | FR2.4.1 中文检索失守、交付受阻 | 部署镜像预装 zhparser + 词典并写入《外呼清单=空》自检报告（FR2.6.2）；降级预案：`default` 配置 + 应用层 jieba 分词查询（接口不变，仅索引配置切换）；上线检查表含分词冒烟用例 |
| 推荐质量依赖嵌入表示与聚合权重，冷数据/小语料下 AC2.5.1 可能不达标 | M2 Exit 抽验失败 | 金标推荐集上线前调参（权重/时间衰减/N）；向量+关键词混合兜底纯向量；不达标时在推荐位展示"语料不足"提示而非错误推荐 |
| 两阶段上传的会话状态（预检结果与执行 directives 不一致：文件被替换/他人先建同名） | 脏数据或决策失效 | 执行阶段服务端重算 SHA-256 校验 directives 一致性，不一致返回 `PRECHECK_STALE` 要求重新预检（不静默采用旧决策） | FR2.1.2/2.1.3 |
| 文档↔项目关联缺失导致推荐/检索范围静默收窄（FR2.3.2） | 用户困惑"为何搜不到/不推荐" | 上传 directives 强制引导选择项目（UI 必填项可留空但显式警示）；列表页提供"未关联项目"筛选便于治理 |
| kb_revision 与 F3 ingestion 回调的最终一致性（进程内事件、任务失败） | kb_version 与 chunk 状态漂移 | 回调幂等（kb_revision 以 ingestion 任务 id 去重）；对账任务（定时比对 ingest_state 与 kb_revisions）偏差告警；任务失败可重触发（specs/README 任务状态机 CANCELED/FAILED 语义） | A5 |
| MinIO 内容寻址对象被误清（外部运维） | 版本历史文件丢失（AC2.1.1） | 对象删除仅保留数据保留策略通道（C-Q2 非目标）；`document_versions.file_key` 与对象存在性巡检脚本随交付 |

### 非目标（Phase 1）

- 在线协同编辑、文档审批流（DRAFT→APPROVED 定版）、OCR 缓存策略优化、跨库联邦检索（spec §6）
- 物理删除与数据保留策略实现（C-Q2：仅留管理员后台规划位）
- 历史版本参与 RAG 检索（C-Q4：仅 current_version；未来作为 F3 可配置项另行立项）
- zhparser 词典在线编辑 UI（仅文件替换+重载，clarifications Assumptions）
- 预置标签集/标签治理策略（C-Q1：空初始集+自由创建）
- 顶级分类扩展、分类树 >3 层（FR2.2.1/2.2.2 明确禁止）
- 全文库去重的跨实例同步、多知识库/租户隔离（单企业域部署，PRD §53）

---

## 7. 决策与假设记录（承接 clarifications）

- C-Q1：中文分词 = PG zhparser + 随包自定义词典（AI管理员文件替换+重载维护），F2.4 与 F3.1.3 共用同一 text search configuration；标签不预置、自由创建 + 常用标签频次聚合。→ A3、A7、§2.2、§3.1、§5
- C-Q2：删除 = 软删除 + 全通道下架双层语义；删除前强制引用方列表（实时查询）+ 二次确认；对象/版本/引用记录永久保留；无物理删除入口。→ A4、§1.2、§3.1、§5
- C-Q3：MinIO 内容寻址（key=`sha256/<hash>`），同内容共享物理对象；"仍作为新关联上传"仅建逻辑记录。→ A2、A9、§2.2、§5
- C-Q4：仅 current_version 的 chunk 参与检索；新版本生效时旧版本 chunk 置 superseded 并登记 kb_revision；历史版本可人工查看（AC2.1.1）。→ A5、§1.2、§2.2/§2.3、§5
- 新增决策（无对应 Q，依 FR 推定的默认选项）：**A8 推荐不使用生成式 LLM**——FR2.5.3 的"推荐理由"以证据结构（源文档+片段+主题词）确定性生成，理由可 100% 回溯核验，规避生成式幻觉与额外审计负担；如业务要求自然语言理由，Phase 2 以 `f2.recommend_reason` prompt 增量接入（FR10.3.4 通道已备）。
- 新增决策：**AC2.5.1 金标场景抽验扩展为 golden_set_rec_v1（≥20 对，Recall@5 ≥ 60% 内部目标）**——spec 仅给单一金标场景，评测需最小样本量；目标值上线前与业务方核定版本化（沿用 F3 Q1 模式）。
- 假设：文档 state 在 Phase 1 不启用治理转换（无审批流，spec §6）；上传 UI 中项目关联可留空但显式警示（FR2.3.2 的引导式实现）；`documents.name` 默认取上传文件名，可编辑；kb_version 服务缓存以单实例内存 + DB MAX(kb_version) 校准（模块化单体假设，F10 plan A1 一致）。
