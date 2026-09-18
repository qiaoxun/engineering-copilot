# F5 规格书智能对比 — 技术方案（Plan）

| | |
| ---- | ---- |
| Feature | F5-spec-comparison |
| 输入 | specs/F5-spec-comparison.md、specs/F5-spec-comparison.clarifications.md（冲突时以其为准）、PHASE1_SPEC.md、PHASE1_FEATURES.md、specs/README.md、UI_GUIDE 页面13 |
| 关联 | specs/F1-document-parsing.plan.md（统一解析模型/定位/版本契约）、specs/F10-platform-governance.plan.md（对象模型/状态机/审计/RBAC/KPI 接入契约）、specs/F4-ai-chat.md（spec_diff 技能入口） |
| 阶段 | speckit-plan（仅设计，不写代码） |
| 里程碑 | M3 |

> 本 plan 中所有设计决策均标注溯源（FR/AC/Q 编号）。clarifications（Q1–Q3 决策）全文有效，本文引用处标注为「C-Qx」。

---

## 1. 架构与模块落点

### 1.1 总体架构

对齐既定技术栈：**后端 FastAPI 模块化单体 + Celery + PostgreSQL(pgvector) + MinIO；前端 React + TypeScript + Ant Design**。F5 落在独立顶层模块 `specdiff/`，核心由三部分组成：① 确定性 **Diff 引擎**（键归一化、字段对齐、Δ% 计算、规则分级——纯函数、无 LLM、可独立单测，FR5.1.2/FR5.1.3/FR5.3.1）；② **映射召回与确认流**（pgvector 嵌入召回 + LLM 同义判定 + 人工确认入库，FR5.2.1–FR5.2.3）；③ **AI 总结**（仅基于 Diff 数据、强制 grounding，FR5.4）。文档输入一律经 F1 统一解析模型（FR1.6.2、AC1.6.1），禁止自行读原件解析。

```text
apps/backend/
├── app/
│   ├── core/                        # F10 平台地基
│   ├── modules/
│   │   ├── specdiff/                # ← F5 本体
│   │   │   ├── api/                 # runs/rows/mappings/level-rules/export 路由
│   │   │   ├── run/                 # 对比发起：文档 PARSE_CONFIRMED 校验、版本选择（FR5.1.1）
│   │   │   ├── diff_engine/         # 确定性 Diff：键归一化 → 对齐 → 差异类型 → Δ% → 规则分级
│   │   │   │   ├── normalize.py     # 大小写/全半角/空白/单位写法归一（FR5.1.2）
│   │   │   │   ├── align.py         # 精确匹配对齐 + 映射库应用 + 未匹配集产出
│   │   │   │   └── grading.py       # level_rules 规则分级引擎（FR5.3.1）
│   │   │   ├── mapping/             # 映射库：嵌入召回（pgvector）、建议管理、field_mapping CRUD（FR5.2/F5.6）
│   │   │   ├── summary/             # F5.4 AI 总结（LLMGateway + grounding 校验）
│   │   │   ├── export/              # F5.5 Excel(openpyxl) / PDF(水印) 生成 → MinIO
│   │   │   └── levelrules/          # 分级规则表 CRUD + DRAFT/APPROVED 生效判定（C-Q1）
│   │   ├── documents/               # F1：进程内只读复用 list_parse_versions / parse 模型读取
│   │   └── platform/                # F10：objects/workflow/audit/rbac/kpi/prompts（见 F10 plan）
│   ├── worker/                      # Celery app；specdiff 队列（对比 + 导出两类任务）
│   └── main.py
└── alembic/
apps/frontend/
└── src/
    ├── pages/specdiff/              # 对比列表/发起页（页面13：文件A/B 选择 + 版本下拉）
    ├── pages/specdiff/result/       # 差异明细表（等级色标/Δ%/定位跳转/分级覆盖）+ 映射确认区 + [AI]总结卡
    ├── pages/specdiff/mappings/     # F5.6 映射库管理页（查询/停用/确认人与时间）
    └── features/diff-viewer/        # 参数名点击 → A/B 原文高亮（复用 F1 parse-viewer 定位组件，FR5.1.4）
```

### 1.2 对比管线（核心流程）

```text
POST /runs（校验 A/B 均 PARSE_CONFIRMED + 项目可见性，FR5.1.1）
  → spec_diff_run(DRAFT) + Celery specdiff 队列 → task_id（SSE 进度）
  → 读统一解析模型（documents 读服务，含 override 合并视图，FR1.5.4/FR1.6.2）
  → 键归一化（FR5.1.2）→ 精确匹配对齐 → 输出行：差异类型 + Δ%（数值型，FR5.1.3）
  → 未匹配键：① 查映射库（active 条目，按 scope 过滤，C-Q3）自动应用 → 行标"已按历史映射对齐"（FR5.2.4）
              ② 剩余键：pgvector 嵌入相似度召回 top3 → LLM 同义判定 → 映射建议（FR5.2.1，pending 态）
  → 规则分级（level_rules APPROVED 子集，C-Q1）+ LLM 等级建议（FR5.3.2，level_source=ai）
  → AI 差异总结（仅基于 Diff 行数据，grounding 校验，FR5.4.1–FR5.4.2）
  → run SUCCESS；SSE 推送阶段进度（align/mapping/grading/summary）
  → 人工：确认/拒绝映射建议（FR5.2.2）→ 确认项写入 field_mapping（FR5.2.3，audit mapping.confirmed）
  → 人工：逐行分级覆盖（FR5.3.3，audit level.overridden）→ run.confirmed 定版（F10.2，分级锁定）
  → 导出 Excel/PDF（FR5.5）；KPI：specdiff.start → specdiff.export 耗时打点（spec §5）
```

### 1.3 关键架构决策

| # | 决策 | 溯源 |
| ---- | ---- | ---- |
| A1 | **Diff 引擎与 AI 严格分层**：键归一化/对齐/Δ%/规则分级是确定性纯函数模块（`diff_engine/`），LLM 只出现在映射判定（FR5.2.1）、等级建议（FR5.3.2）、总结（FR5.4）三处且输出永不直接改变结论——映射须人工确认、等级建议仅标注"AI建议"、总结为草稿态。差异召回率（AC5.1.1）的确定性部分不依赖模型质量 | FR5.1.2、FR5.2.2、FR5.3.2、FR5.4.2、AC5.1.1 |
| A2 | **输入只走 F1 统一解析模型**：A/B 文档必须 `PARSE_CONFIRMED` 且解析 status=SUCCESS（FR5.1.1）；版本选择读取 parse_results 版本列表（经 documents 模块进程内读服务 `list_parse_versions()`，specdiff 侧提供代理端点，不新增/不改 F1 的对外 API）；字段来源 `fields[]` 的 `source_block_id` 直接复用于行级定位（FR5.1.4），定位跳转复用 F1 既有端点 `GET /api/v1/documents/{id}/parse/blocks/{block_id}/source`（页码+bbox+预签名 URL） | FR5.1.1、FR5.1.4、FR1.6.2、AC1.6.1；F1 plan §3.1 |
| A3 | **归一化规则表驱动且与 F1 字典同源**：键归一化（小写、全半角折叠、空白剔除、单位写法折叠 Ah/A·h/aH、mAh→A·h 经 `param_dict.si_unit`）复用 F1 `param_dict` 的 synonyms/si_unit，不另造第二套参数词表；无字典命中的自由键按字符归一后精确匹配，匹配不上进入 F5.2 流程 | FR5.1.2、FR1.4.1；C-Q3（模板族标签建议值取自 F1 解析元数据） |
| A4 | **映射建议独立成表、确认才入库**：建议存 `spec_diff_mapping_suggestions`（run 内可见、可逐条确认/拒绝），确认动作是 `field_mapping` 唯一写入路径——AI 建议永不自动入库由「无其他写入代码路径 + 依赖方向约束 + 集成测试断言」保证（同 F10 plan A2 架构禁令手法）；`field_mapping` 状态用 `active/disabled`，不占用 F10 DRAFT→APPROVED（条目产生即人工已确认，天然满足「AI 生成物人工确认」语义） | FR5.2.2、FR5.2.3、FR5.6.2；specs/README AI 草稿语义 |
| A5 | **映射库为部署域全局共享、无 project_id**：`field_mapping` 不继承 BaseEntity（spec §3 数据模型无 project_id，C-Q3 Assumptions）；scope 为可扩展枚举 `{global, template_family}`（Phase 1 仅此两值，未来扩 customer/product_line 只改字典不改表）；对比时先匹配 template_family 条目、再回落 global，命中行标 `mapping_source=library`，可人工解除对齐（解除后行回落 仅A有/仅B有，写审计） | FR5.2.3、FR5.2.4、AC5.2.1；C-Q3 |
| A6 | **分级规则表独立于代码、走平台状态机**：`level_rules` 表存储规则（参数键集合/匹配模式 → 🔴/🟠），初版由我方按 GB 38031/IEC 62660 起草 ≥30 安全项 + ≥40 关键性能项，DRAFT 态导入，研发主管 APPROVED 后线上生效；线上遇未定版规则表按「全部 🟡 + LLM 建议」兜底，不阻塞对比执行。分级优先级：人工覆盖 > 规则 > LLM 建议 > 默认 🟡 | FR5.3.1–FR5.3.3；C-Q1 及其 Assumptions |
| A7 | **对比结论（含 AI 总结）走 F10.2 状态机**：`spec_diff_run` 继承 BaseEntity，state `DRAFT → APPROVED`（定版权限=研发主管，comment 必填，F10 通用 transition 端点）；APPROVED 后差异分级与行数据锁定（`OBJECT_LOCKED`），修订走 revision 新 run。AI 总结在 run 内为草稿性质（UI 带 [AI] 标识），随 run 定版一并确认——不另设总结独立审批对象 | FR5.4.2、FR5.3.3、spec §5 状态机；F10 plan §2.3 |
| A8 | **导出为异步任务 + 工件落 MinIO**：Excel（openpyxl 三 Sheet）/PDF 生成放 Celery `specdiff` 队列（导出含数百行渲染，避免占用 API 进程），产物写 MinIO 返回预签名 URL；PDF 导出在服务端按 run.state 注入"草稿"水印（DRAFT）或不加水印（APPROVED），水印判断以定版时点为准而非导出请求时刻之后的状态变化 | FR5.5.1、FR5.5.2；specs/README 异步约定 |
| A9 | **前端页面13按 UI_GUIDE 落地**：三栏参数对比表（参数/A值/B值/差异）+ 等级色标（🔴🟠🟡）+ AI 总结卡 + 映射确认区（独立面板，逐条 确认/拒绝 + 理由展示）；参数名点击跳转原文高亮复用 `features/parse-viewer`；所有 AI 建议类内容（映射建议理由、AI 等级、总结）带 AI 标识 | spec §1、FR5.2.2、FR5.3.2、FR5.4.2；UI_GUIDE 页面13 |
| A10 | **评测离线脚本独立于线上埋点**（同 F1 plan A10 手法）：`evals/spec_diff/` 对标注集（C-Q2：3 组对、≥180 条差异、双人标注+仲裁）跑全管线，输出差异召回率/精确率/映射建议召回率报告；线上仅打 `specdiff.start→export` 耗时 KPI | AC5.1.1；C-Q2；spec §5 KPI |

---

## 2. 数据模型

> 全部主键 UUIDv7、时间戳 UTC（specs/README 约定）。`spec_diff_run` 继承 F10 BaseEntity 公共列（FR10.1.3：id/project_id/created_by/created_at/updated_at/state/audit_ref）。

### 2.1 spec_diff_run（spec §3）

```text
spec_diff_run(
  # BaseEntity 公共列：id, project_id, created_by, created_at, updated_at,
  #                    state(DRAFT→APPROVED, F10.2), audit_ref, revision INT DEFAULT 1
  doc_a_id→documents, doc_a_parse_version INT,     # 各自可选版本（FR5.1.1）
  doc_b_id→documents, doc_b_parse_version INT,
  template_family VARCHAR NULL,                    # 手动选择/填写（C-Q3；建议值来自 F1 模板识别元数据）
  mapping_library_version INT,                     # 对比时点映射库快照版本（审计用，spec §5）
  level_rules_version UUID NULL,                   # 对比时点生效规则表版本（审计用，C-Q1）
  summary JSONB NULL,                # {overall_conclusion, top_diffs[], risk_notes[], summary_schema_version}
  status,                            # 任务生命周期：QUEUED/RUNNING/SUCCESS/FAILED（对齐任务状态机）
  fail_reason VARCHAR NULL,          # DOC_NOT_PARSE_CONFIRMED / PARSE_MODEL_UNAVAILABLE / SUMMARY_FAIL ...
  task_id UUID NULL,                 # 异步任务（SSE）
  stats JSONB NULL                   # {total_rows, diff_rows, by_level{red,orange,yellow}, by_type{...},
                                     #  matched_exact, matched_library, suggestions_pending}
)
-- state 由 F10 workflow 管理（DRAFT→APPROVED）；status 仅描述异步任务执行
```

### 2.2 spec_diff_row（spec §3）

```text
spec_diff_rows(
  id UUIDv7 PK, run_id→spec_diff_runs,
  param_key VARCHAR,                 # 归一化后键；display_name 取 A 侧原文表头/字典显示名
  value_a JSONB, value_b JSONB,      # {value_raw, value_norm, unit, unit_si}（保留原文表达，FR5.1.3）
  delta_pct NUMERIC NULL,            # 数值型相对偏差（FR5.1.3；非数值/区间型为 NULL）
  diff_type VARCHAR,                 # VALUE_DIFF | ONLY_A | ONLY_B | UNIT_DIFF   （FR5.1.3）
  level VARCHAR,                     # RED | ORANGE | YELLOW                       （FR5.3.1）
  level_source VARCHAR,              # rule | ai | human | default_yellow           （FR5.3.1–FR5.3.3）
  ai_level_suggestion JSONB NULL,    # {level, reason}（FR5.3.2，仅标注不生效）
  level_override JSONB NULL,         # {from_level, to_level, by, at, comment}（FR5.3.3，入审计）
  mapping_source VARCHAR,            # exact | library | suggestion                 （FR5.2.4）
  applied_mapping_id→field_mappings NULL,   # library 命中时可溯源；解除对齐时置 NULL 并留痕
  locate_a JSONB, locate_b JSONB,    # {doc_id, block_id, page, bbox}（FR5.1.4，源自 source_block_id）
  created_at
)
-- 索引：(run_id, level), (run_id, diff_type), (run_id, param_key)
```

### 2.3 映射库与建议

```text
field_mappings(                     # 部署域全局共享，无 project_id（A5、C-Q3 Assumptions）
  id UUIDv7 PK,
  key_a VARCHAR, key_b VARCHAR,     # 归一化键（对方向语义：A键≈B键，双向查询）
  scope VARCHAR,                    # global | template_family（可扩展枚举，C-Q3）
  template_family VARCHAR NULL,     # scope=template_family 时必填
  status VARCHAR,                   # active | disabled                            （FR5.6.1）
  confirmed_by→users, confirmed_at,                                                （FR5.2.3）
  source_run_id→spec_diff_runs NULL,  # 溯源：哪次对比沉淀
  version BIGINT                    # 库级单调版本，供 run 快照（spec §5 审计"映射库版本"）
)
-- UNIQUE(key_a, key_b, scope, template_family)；disabled 保留历史（不物理删，停用写审计）

spec_diff_mapping_suggestions(      # run 内建议区（FR5.2.1–FR5.2.2），不继承 BaseEntity
  id UUIDv7 PK, run_id→spec_diff_runs,
  key_a VARCHAR, key_b VARCHAR,
  embed_score NUMERIC,              # 向量相似度召回分（FR5.2.1 top3）
  llm_judgment JSONB,               # {is_synonym, confidence, reason}（FR5.2.1 理由）
  status VARCHAR,                   # SUGGESTED | CONFIRMED | REJECTED              （FR5.2.2）
  resolved_by→users NULL, resolved_at NULL,
  resulting_mapping_id→field_mappings NULL
)

specdiff_key_embeddings(            # 键嵌入缓存（pgvector），避免重复调用 embedding 模型
  normalized_key VARCHAR PRIMARY KEY, embedding vector(1024), model VARCHAR,
  updated_at
)
```

### 2.4 分级规则表（C-Q1）

```text
level_rules(
  id UUIDv7 PK, version INT,
  rules JSONB,                      # [{match: {keys[]|pattern}, level: RED|ORANGE, category}]
  state,                            # DRAFT | APPROVED（复用 F10 workflow；仅 APPROVED 线上生效）
  approved_by→users NULL, approved_at,
  created_by, created_at, remark
)
-- 变更走 CRUD + audit levelrule.updated（C-Q1）；run 记录生效版本（§2.1 level_rules_version）
-- 兜底：线上无 APPROVED 版本 → 全部 🟡 + LLM 建议（C-Q1 Assumptions，A6）
```

---

## 3. API 设计（遵循 specs/README：REST /api/v1、统一错误体、异步任务 SSE）

### 3.1 端点清单

```text
POST /api/v1/spec-diff/runs              # body: {doc_a_id, doc_a_parse_version?, doc_b_id,
                                         #       doc_b_parse_version?, template_family?}
                                         # 校验 PARSE_CONFIRMED（FR5.1.1）→ 201 {run_id, task_id}（异步）
GET  /api/v1/spec-diff/runs              # 列表：分页 {items,total,page}；筛选项目/状态/模板族
GET  /api/v1/spec-diff/runs/{id}         # 总览 + stats + summary（[AI] 标识）（spec §4）
GET  /api/v1/spec-diff/runs/{id}/rows    # 差异明细：?level=&diff_type=&mapping_source=&page=&page_size=
                                         # （FR5.1.3 输出行结构；spec §4 筛选：等级/类型）
GET  /api/v1/spec-diff/runs/{id}/rows/{row_id}/locate/{side=a|b}
                                         # 定位：返回 {doc_id, block_id, page, bbox, source_url}
                                         # 内部转发 F1 定位端点（FR5.1.4；前端复用 parse-viewer 高亮）
GET  /api/v1/spec-diff/runs/{id}/mappings        # 映射建议区（SUGGESTED/CONFIRMED/REJECTED，FR5.2.2）
POST /api/v1/spec-diff/runs/{id}/mappings/confirm
                                         # body: {decisions: [{suggestion_id, action: confirm|reject,
                                         #        scope?, template_family?}]}
                                         # 批量确认→写 field_mapping + audit mapping.confirmed（FR5.2.2/5.2.3）
POST /api/v1/spec-diff/runs/{id}/rows/{row_id}/level
                                         # body: {level, comment?} 人工分级覆盖→audit level.overridden
                                         # （FR5.3.3）；APPROVED 后返回 RUN_LOCKED
POST /api/v1/spec-diff/runs/{id}/rows/{row_id}/unlink-mapping
                                         # 解除历史映射对齐（FR5.2.4）→ audit specdiff.mapping_unapplied
POST /api/v1/spec-diff/runs/{id}/confirm # 结论定版（F10.2 transition，comment 必填）→ audit run.confirmed
POST /api/v1/spec-diff/runs/{id}/export  # body: {format: excel|pdf} → task_id（异步，A8）；spec §4
GET  /api/v1/spec-diff/runs/{id}/exports # 导出历史（format/file_url/created_by/state）

# 映射库管理（F5.6）
GET  /api/v1/spec-diff/mappings          # ?key=&scope=&template_family=&status= 查询（FR5.6.1）
POST /api/v1/spec-diff/mappings/{id}/disable   # 停用 → audit mapping.disabled（FR5.6.1）

# 分级规则表（C-Q1）
GET/POST/PUT /api/v1/spec-diff/level-rules     # CRUD（版本化）；变更 → audit levelrule.updated
POST /api/v1/spec-diff/level-rules/{id}/transition  # DRAFT→APPROVED（研发主管；复用 F10 workflow）

# 辅助
GET  /api/v1/spec-diff/documents/{doc_id}/parse-versions
                                         # A/B 版本下拉数据（代理 documents 进程内读服务，A2）
GET  /api/v1/tasks/{id}/events           # SSE：QUEUED/RUNNING(stage=align|mapping|grading|summary)/
                                         # SUCCESS/FAILED/CANCELED（specs/README 异步约定）
```

### 3.2 语义与错误

- 统一错误体 `{"code","message","detail"}`。本 feature 新增错误码：
  - `SPEC_DIFF_DOC_NOT_CONFIRMED`（FR5.1.1：文档未 PARSE_CONFIRMED，message 提示先完成校对确认）
  - `SPEC_DIFF_PARSE_VERSION_NOT_FOUND`（FR5.1.1 版本选择非法）
  - `SPEC_DIFF_RUN_LOCKED`（APPROVED 后分级/行编辑/映射操作被拒，spec §5「定版后分级锁定」）
  - `SPEC_DIFF_MAPPING_DUPLICATE`（确认的映射与库内 active 条目冲突）
  - `SPEC_DIFF_SUMMARY_UNAVAILABLE`（总结生成失败不阻塞 Diff 结果，行数据照常可读）
- **异步边界**：发起对比、导出两操作走 Celery `specdiff` 队列返回 `task_id`、进度经 SSE；映射确认、分级覆盖、解除对齐、停用映射为同步操作（无重计算）；定版走 F10 通用 transition（同步）。发起时校验失败（文档未确认等）为同步 4xx，不入队。
- **权限**（F10.5 矩阵）：发起/编辑/映射确认 = 工程师+；定版/规则表 APPROVED = 研发主管；映射库停用 = 工程师+（停用写审计）；run 可见性随项目继承。F4 spec_diff 技能经 `POST /runs` 同一入口发起（被依赖关系，spec 头表）。
- SSE `RUNNING` payload：`{"stage": "align|mapping|grading|summary", "progress": 0–100}`；导出任务 stage=`export`。

---

## 4. AI/LLM 使用点

| 项 | 设计 | 溯源 |
| ---- | ---- | ---- |
| LLM 使用范围 | **三处**：① 跨模板映射同义判定（FR5.2.1）；② 差异等级建议（FR5.3.2）；③ 差异总结（FR5.4.1）。键归一化、精确对齐、Δ%、规则分级、Excel/PDF 渲染全部为确定性代码。 embedding 调用（召回）经 LLMGateway，但仅产生候选不产生结论 | FR5.2.1、FR5.3.2、FR5.4.1 |
| 模型策略 | 经 F10 `LLMGateway`：embedding 模型与生成模型均走配置（私有化可替换、数据不出企业域）；审计记录运行时实测 model/model_version；embedding 向量维度随配置，缓存表迁移时锁定 | F10 plan §4 挂点 2；FR10.3.1 |
| Prompt 策略 | Prompt 注册表管理，三个 prompt_id：`f5.mapping_judge`（输入：候选键对 + 双侧 display_name/单位/样本值上下文；输出：逐对同义判定+理由）、`f5.level_suggest`（输入：差异行 + 参数上下文；输出：建议等级+理由；系统指令明确"仅建议，人工可改"）、`f5.diff_summary`（输入：**仅** Diff 行结构化数据 + 等级分布；系统指令明确"只允许引用输入数据中的参数与数值，禁止引入任何外部知识/标准/经验"，FR5.4.2）。禁止裸字符串 prompt | FR5.2.1、FR5.3.2、FR5.4.2；FR10.3.4 |
| 结构化输出 schema | 均强制 JSON Schema（Pydantic 校验，失败重试 1 次后降级：映射对→该候选放弃、等级→不产出建议、总结→summary 置 NULL + `SPEC_DIFF_SUMMARY_UNAVAILABLE` warning，不阻塞主流程）：① `{"judgments":[{"key_a","key_b","is_synonym","confidence","reason"}]}`；② `{"suggestions":[{"param_key","level":"RED|ORANGE|YELLOW","reason"}]}`；③ `{"summary_schema_version":"1.0","overall_conclusion","top_diffs":[{"param_key","statement","delta_pct"}],"risk_notes":[{"param_key","note"}]}` | FR5.2.1、FR5.3.2、FR5.4.1；F10 plan §4 挂点 3 |
| Grounding/防幻觉 | 总结后置**确定性校验**（代码非 prompt）：总结文本中出现的每个参数键必须存在于该 run 的 diff 行集合、每个数值/百分比必须与对应行 value/delta_pct 匹配（归一后比对），校验失败丢弃该句并记 warning——"总结仅基于 Diff 数据"由代码保证而非 prompt 约定（同 F1 plan A6 手法）；总结对象 UI 带 [AI] 草稿标识，随 run 走 F10.2 定版 | FR5.4.1、FR5.4.2 |
| 映射召回 | 归一化键 → pgvector 余弦相似度召回对方文档未匹配键 top3（嵌入缓存 `specdiff_key_embeddings`）→ LLM 判定；候选不足 3 个按实际数量；未匹配键同时进入仅A有/仅B有行（映射确认后这些行更新为对齐行）。观测：映射建议召回率（建议含标注真值映射比例 ≥90%，C-Q2，非硬门槛） | FR5.2.1；C-Q2 |
| 审计接入 | 每次对比 emit `specdiff.run`（记录模型、prompt 版本、映射库版本 mapping_library_version、规则表版本）；`mapping.confirmed / mapping.disabled / level.overridden / run.confirmed / specdiff.mapping_unapplied / levelrule.updated` 均入审计（<domain>.<verb>） | spec §5 审计；FR10.3.1、FR10.3.3；C-Q1 |
| 评测方式 | ① 离线标注集评测：3 组真实规格书对（≥1 同模板 + ≥2 跨模板，优先取自 F1 golden_set_v1 已确认解析产出，C-Q2 Assumptions），≥180 条标注差异，差异召回率 ≥95% 为 **M3 硬门槛**（跨模板组按"人工确认映射后"口径统计）；映射建议召回率 ≥90%、精确率、AI 等级采纳率为观测指标；脚本归档版本化报告；② 变更（规则表/prompt/模型）触发回归；③ 线上 `specdiff.start→export` 耗时 KPI 对照人工基线验收 ↓80% | AC5.1.1；C-Q2；spec §5 KPI；PRD §50 |

---

## 5. 测试策略

| 层级 | 内容 | 溯源 |
| ---- | ---- | ---- |
| 单元 | 键归一化矩阵（大小写/全半角/空白/单位写法 Ah/A·h/mAh→A·h、℃/K）；Δ% 计算（含 0 值、负值、区间型不计算）；diff_type 判定四类穷举；规则分级引擎（红/橙/黄、仅单方默认 🟡、未定版规则表兜底全 🟡、优先级 human>rule>ai>default）；scope 过滤（template_family 命中优先回落 global）；总结 grounding 校验器（构造注入外部数值的总结断言被剔除） | FR5.1.2、FR5.1.3、FR5.3.1；C-Q1、C-Q3；FR5.4.2 |
| 集成（对比管线） | fixtures：两组含参数表规格书（同模板 + 跨模板，取自 F1 金标解析产物）端到端跑 SUCCESS；断言行结构（value_raw 保留原文、locate 含 page/block_id）、stats 汇总正确、未确认文档发起返回 `SPEC_DIFF_DOC_NOT_CONFIRMED` 且无 run 记录；SSE 事件序列 QUEUED→RUNNING(各 stage)→SUCCESS | FR5.1.1–FR5.1.4；specs/README 异步 |
| 集成（映射闭环，AC5.2.1） | 第一次跨模板对比→建议区产出建议→批量确认（含 reject 分支）→field_mapping 落库含 confirmed_by/at→**第二次同模板族对比自动应用且行上 mapping_source=library**→解除对齐后行回落 仅A有/仅B有 且审计留痕→停用映射后第三次对比不再应用 | FR5.2.2–FR5.2.4、AC5.2.1、FR5.6.1 |
| 集成（分级与定版） | LLM 等级建议仅标 level_source=ai 不改生效等级；人工覆盖写 level_override + audit level.overridden；工程师定版 403、研发主管 comment 必填成功；APPROVED 后 level/unlink/mapping 操作返回 RUN_LOCKED；run.confirmed 审计含 who/when | FR5.3.2、FR5.3.3、spec §5 状态机；F10 plan A2 |
| 集成（总结，FR5.4） | mock LLM 返回含外部知识的总结→grounding 校验剔除并 warning；合法总结入库为 DRAFT 态随 run 定版；LLM 失败→run 仍 SUCCESS、summary NULL + 错误码可读 | FR5.4.1、FR5.4.2 |
| 集成（导出） | Excel 三 Sheet 内容与行数据一致（Sheet1 明细含等级/偏差/页码、Sheet2 映射、Sheet3 总结）；PDF DRAFT 态含水印、APPROVED 后无水印；导出走异步任务且产物可下载 | FR5.5.1、FR5.5.2 |
| **禁绕过测试**（AC1.6.1 复用） | import-linter 禁止 specdiff 模块直读 MinIO 原件/自建 PDF 解析；集成测试以仅消费统一解析模型的桩文档验证 Diff 可完成 | FR1.6.2、AC1.6.1；A2 |
| 权限矩阵 | 参数化：5 角色 × {发起/查行/映射确认/分级覆盖/定版/规则表定版/映射停用}；映射库无 project_id 的全局可见性断言（C-Q3） | FR10.5 矩阵；spec §5 |
| API 契约 | 统一错误体/分页信封/SSE payload schema；新错误码语义逐条断言；映射批量确认部分成功语义（逐条返回成功/失败） | specs/README、§3.2 |
| 评测 | `evals/spec_diff/` 对标注集全量跑分：差异召回率 ≥95%（M3 硬门槛）、映射建议召回率 ≥90%（观测）；分同模板/跨模板分项报表；AI 等级采纳率统计 | AC5.1.1；C-Q2 |
| 前端 | 组件测试：等级色标与筛选、映射确认区逐条确认/拒绝、[AI] 标识（总结/建议理由/AI 等级）、参数名点击→A/B 原文高亮、版本下拉、水印提示 | FR5.1.4、FR5.2.2、FR5.3.2、FR5.4.2；UI_GUIDE 页面13 |

覆盖率目标遵循全局规则（新增模块 ≥80%）。

---

## 6. 风险与非目标

### 风险

| 风险 | 影响 | 缓解 |
| ---- | ---- | ---- |
| 跨模板键归一化后仍大量不匹配（同义写法超出字典覆盖） | 建议数量爆炸/召回不足，威胁 AC5.1.1 | 归一化复用 F1 字典同义词（A3）；嵌入召回 + 编辑距离兜底双候选源；未匹配键全部显式呈现（仅A有/仅B有行）不静默丢弃；标注集分模板观测调优 |
| LLM 同义判定假阳性（如不同含义的近似键被判定同义） | 错误映射污染 Diff 结论与映射库 | 人工逐条确认强制（FR5.2.2）；建议携带置信度与理由供人判断；映射可停用/可解除对齐且入审计（FR5.2.4、FR5.6.1）；映射建议精确率作为观测指标 |
| 单位语义陷阱：数值相等但单位不同（100Ah vs 100mAh）被误判一致 | 漏报关键差异（威胁 AC5.1.1） | 值比对基于 `unit_si` 归一后数值；单位写法不同但语义等价归 UNIT_DIFF 而非 VALUE_DIFF；单测覆盖 mAh/Ah 数量级差异场景 |
| 总结幻觉（引入外部标准/数值） | 违反 FR5.4.2，结论可信度受损 | 确定性 grounding 校验（§4）代码级保证 + 失败降级置 NULL，不静默输出 |
| 规则表长期停留 DRAFT（客户评审延迟） | 分级全部 🟡，KPI 体验下降 | C-Q1 兜底：全 🟡 + LLM 建议不阻塞执行；测试环境整库启用（C-Q1 Assumptions）；M3 Exit 前置检查项推动评审 |
| 标注集依赖客户方标注资源（C-Q2） | M3 验收延迟 | Assumption：先以我方自建标注集（3 组对、≥180 条、双人标注）内部验收，客户方标注集就绪后复测正式验收（C-Q2 Assumptions，同 F1 golden_set_v1 处理方式） |
| 映射库全局共享带来的跨项目语义冲突（不同产品线同名键含义不同） | 错误自动对齐 | Phase 1 单客户私有化部署风险可控（C-Q3）；template_family 手动限定缩小命中面；行级解除对齐 + 停用通道兜底；scope 枚举预留 customer/product_line 扩展 |
| KPI 基线缺失（人工比对耗时未测） | ↓80% 无法验收 | F10.6 人工基线联合测量为 M1 交付项，M3 Exit 前置检查（F10 plan 风险表）；线上 specdiff.start/export 打点必须全程覆盖 |

### 非目标（Phase 1）

- 合同/招标书类非结构文本比对、双文档版式视觉比对（像素级）、批量多文档两两对比矩阵（spec §6）
- 按客户/产品线自动分域、模板族自动聚类（C-Q3：仅 global + 手动 template_family，枚举预留）
- 映射建议自动入库、AI 直写任何终态（FR5.6.2；specs/README AI 草稿语义）
- 差异自动合并/回写到文档、对比结果的双向同步编辑
- Excel 样式级原文还原导出（导出为结构化报表，非文档复刻）

---

## 7. 决策与假设记录（承接 clarifications）

- C-Q1：分级规则表由我方按 GB 38031/IEC 62660 起草初版（安全 ≥30 项🔴、关键性能 ≥40 项🟠），DRAFT 导入、研发主管 APPROVED 后线上生效；未定版时兜底全 🟡 + LLM 建议不阻塞；变更走 CRUD + `levelrule.updated` 审计。→ §2.4、§3.1、A6、§4、§5、§6
- C-Q2：差异召回率 ≥95% 为 M3 硬门槛；标注集 = 3 组对（≥1 同模板 + ≥2 跨模板，优先复用 F1 golden_set_v1 解析产出）、≥180 条差异、双人标注+仲裁；跨模板召回按"人工确认映射后"口径；映射建议召回 ≥90% 及精确率、AI 等级采纳率为观测指标。→ §4 评测、§5 评测、A10、§6
- C-Q3：scope 仅 `{global, template_family}`，无客户/产品线自动分域；`field_mapping` 无 project_id（部署域全局共享）；template_family 手动选择（建议值来自 F1 模板识别元数据）；不做模板族自动聚类。→ A3、A5、§2.3、§3.1、§5、§6
- 假设：映射建议独立成表 `spec_diff_mapping_suggestions`（spec §3「核心」模型之外的最小扩展，FR5.2.2 确认区的持久化载体，A4）；`spec_diff_run.status`（任务生命周期）与 F10 `state`（DRAFT→APPROVED）分离（同 F1 plan A8 手法）；A/B 文档版本下拉数据由 specdiff 代理端点提供、不修改 F1 对外 API（A2）；行级定位转发复用 F1 定位端点（FR5.1.4）；F4 spec_diff 技能复用 `POST /runs` 入口，无独立 API（spec 头表被依赖关系）。
