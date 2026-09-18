# F7 AI FMEA生成 — 技术方案（Plan）

| | |
| ---- | ---- |
| Feature | F7-fmea-generation |
| 输入 | specs/F7-fmea-generation.md、specs/F7-fmea-generation.clarifications.md（冲突时以其为准）、PHASE1_SPEC.md、PHASE1_FEATURES.md、specs/README.md、UI_GUIDE 页面16 |
| 关联 | specs/F10-platform-governance.plan.md（对象模型/状态机/审计/RBAC/KPI/LLMGateway/Prompt注册表）、specs/F3-rag-retrieval.plan.md（检索服务复用、object_source_link 共用表 A8、原文定位）、specs/F1-document-parsing.plan.md（统一解析模型/原文定位端点）、specs/F4-ai-chat.md（fmea_gen 技能入口、F4.5 异步任务）、specs/F9-test-report.md（F9.6 异常转 FMEA 风险条目） |
| 阶段 | speckit-plan（仅设计，不写代码） |
| 里程碑 | M4（F7.1 → {F7.2 ∥ F7.3} → F7.4 → F7.5 → F7.6） |

> 本 plan 中所有设计决策均标注溯源（FR/AC/Q 编号）。clarifications（C-Q1–C-Q3）全文有效，引用处标注「C-Qx」。

---

## 1. 架构与模块落点

### 1.1 总体架构

对齐既定技术栈：**后端 FastAPI 模块化单体 + Celery + PostgreSQL(pgvector) + MinIO；前端 React + TypeScript + Ant Design**。F7 落在独立顶层模块 `fmea/`，核心由四部分组成：① **生成管线**（输入文档校验 → LLM 五维链结构化生成 → 代码级自检/截断 → F3 检索挂引用 → rubric 规则打分，FR7.1.1–FR7.1.4、FR7.2.1、FR7.3.1）；② **S/O/D 规则引擎**（确定性：rubric 语义分档 + 历史案例分数统计，RPN 实时计算——无 LLM、可独立单测，FR7.2.1–FR7.2.3）；③ **表格编辑与人工闭环**（行内编辑 + diff 留痕、批量采纳/忽略、DRAFT→IN_REVIEW→APPROVED 状态机、修订版本链，FR7.4、FR7.5）；④ **导出**（Excel/Word 异步渲染 + 草稿水印，FR7.6）。文档输入一律经 F1 统一解析模型（specs/README 数据契约），历史案例引用一律来自 F3 真实检索（A4），**LLM 在本 feature 中只出现在一处：五维链文本生成**（A1）。

```text
apps/backend/
├── app/
│   ├── core/                        # F10 平台地基（workflow/audit/rbac/kpi/prompts/objects）
│   ├── modules/
│   │   ├── fmea/                    # ← F7 本体
│   │   │   ├── api/                 # fmeas/rows/revisions/rubric/export 路由
│   │   │   ├── generate/            # F7.1 生成管线（Celery fmea 队列）
│   │   │   │   ├── gather.py        # 输入收集：F1 解析模型读取 + 截断策略（FR7.1.1，A2）
│   │   │   │   ├── llm_chain.py     # 五维链 LLM 结构化生成 + 失败重试（FR7.1.2，A1/A3）
│   │   │   │   ├── validate.py      # 代码级自检：空维度剔除/去重/截断50（FR7.1.2，C-Q3，A7）
│   │   │   │   └── retrieve.py      # 逐行 F3 混合检索 → 引用挂接/无命中标注（FR7.1.3，A4）
│   │   │   ├── scoring/             # F7.2 S/O/D 确定性规则引擎（无 LLM）
│   │   │   │   ├── rubric.py        # rubric 语义分档匹配（生效版本判定，C-Q1，A6）
│   │   │   │   ├── history_stats.py # 历史案例打分统计（FR7.2.1，best-effort）
│   │   │   │   └── rpn.py           # RPN 计算 + 风险色标（FR7.2.3，C-Q2 阈值）
│   │   │   ├── editing/             # F7.4 行内编辑/diff/批量采纳忽略/统计（FR7.4）
│   │   │   ├── review/              # F7.5 状态机端点包装 + 修订版本链 + 版本对照（FR7.5，A8）
│   │   │   ├── evidence/            # F7.3 引用消费（复用 /api/v1/links，F3 plan A8）
│   │   │   └── export/              # F7.6 Excel(openpyxl)/Word(python-docx) → MinIO
│   │   ├── documents/               # F1：进程内只读复用（解析模型/原文定位端点转发）
│   │   ├── rag/                     # F3：进程内复用混合检索服务（F3 plan §1 检索服务化）
│   │   └── platform/                # F10：workflow/audit/rbac/kpi/prompts/objects(Task/Issue)
│   ├── worker/                      # Celery app；fmea 队列（生成 + 导出两类任务）
│   └── main.py
└── alembic/
apps/frontend/
└── src/
    ├── pages/fmea/                  # 页面16 FMEA工作台（专业表格 + 生成入口 + 审核流）
    │   ├── GenerateDialog.tsx       # [AI生成FMEA]：文档多选（F2）+ scope_note + 目标版本选择
    │   ├── FmeaTable.tsx            # 类电子表格：行内编辑/增删行/排序/风险筛选（FR7.4.1）
    │   ├── EvidenceDrawer.tsx       # "查看历史案例"侧滑：片段/来源/项目/时间/原文定位（FR7.3.1）
    │   ├── RevisionCompare.tsx      # 版本对照视图（FR7.5.3）
    │   └── ReviewActions.tsx        # 提交审核/定版（研发主管）/修订/导出
    └── features/fmea-table/         # 可编辑单元格、[AI] 角标、S/O/D 步进器、RPN 色标单元格组件
```

### 1.2 生成管线（核心流程）

```text
发起：
POST /fmeas/generate（body: {project_id, document_ids[], product_id?, scope_note?,
  fmea_id?}）
  → 校验：项目权限（fmea.create）、文档属该项目且解析可用（PARSE_CONFIRMED，A2）、
    行数配额（fmea_id 追加批次时检查 200 上限，C-Q3/A7）
  → fmeas 记录（state=DRAFT；fmea_id 缺省则新建 revision=1）→ Celery fmea 队列 → task_id（SSE）

管线（SSE 推送 stage）：
gather     读取所选文档的 F1 统一解析模型（sections/blocks/tables/fields，FR1.6.2），
           按 scope_note 相关性截断组装 LLM 输入（A2；规格参数表优先保留）
generate   LLMGateway → prompt f7.five_dim_chain → JSON Schema 结构化输出 ≤50 行
           （FR7.1.2；C-Q3 单次上限）；schema/自检失败带错误反馈重试 1 次（A3）
validate   代码级自检（FR7.1.2）：五维任一为空 → 剔除；规范化去重（功能+失效模式归一）；
           按 seq 截断至 50 并在任务事件中提示"已达单次上限 50 行"（C-Q3）；剔除/截断计数入审计
retrieve   逐行以「功能 + 失效模式 (+scope_note)」为查询复用 F3 混合检索（top_k=3，
           阈值判定复用 F3 plan A5 口径）→ 命中写 object_source_link(src_type=fmea_row)；
           无命中行 evidence_status='no_hit' 标注"无历史依据"（FR7.1.3，A4）
score      rubric 规则引擎：失效影响语义 → S 分档；历史案例分数统计 → O 分档（best-effort）；
           控制措施可探测性语义 → D 分档；逐维一句理由（FR7.2.1，A5/A6）；
           RPN = S×O×D + 色标（红≥100/橙50–99/绿<50，C-Q2）实时计算（FR7.2.3）
persist    fmea_rows 落库（ai_generated=true, row_status='ai_pending', cell_ai_flags 全 true,
           suggestion 快照）；kb_version/模型/prompt 版本/引用清单/输出行数入 fmeas.generate_meta
完成       audit fmea.generated + KPI fmea.generate（耗时）→ SSE SUCCESS →
           F4 任务卡「查看/编辑 FMEA」（FR7.1.4、F4.4.2）；前端跳转页面16，初稿 DRAFT

人工闭环（工作台）：
行内编辑（PATCH rows/{rid}）→ 逐字段写 fmea_row_diff + 单元格 [AI] 角标消除 + audit row.edited
  （FR7.4.2；S/O/D 人工改动覆盖建议并记录，FR7.2.4）；RPN/色标服务端重算（FR7.2.3）
批量采纳/忽略（POST rows/batch）→ row_status 变更 + audit row.adopted/row.ignored + KPI 埋点
  （FR7.4.3：采纳率 = 采纳行数/AI生成行数，修改率 = 有人工 diff 的采纳行数/采纳行数，AC7.4.1）
引用增删（FR7.3.2）→ 复用 F3 通用链接接口 POST/DELETE /api/v1/links（F3 plan A8）
提交审核 submit-review：DRAFT→IN_REVIEW；定版 approve：IN_REVIEW→APPROVED
  （限研发主管 fmea.confirm + comment 必填，FR7.5.2；AC7.5.1 工程师 403）→ 表格锁定（FR7.5.1）
修订 revise：APPROVED → 复制新 fmea（revision+1，origin_row_id 血缘），旧版本只读留存、
  版本可对照（FR7.5.3，A8）
导出 export：excel|word 异步任务 → MinIO 预签名 URL；非 APPROVED 态带草稿水印（FR7.6.1，A10）
KPI：fmea.generate 耗时；start(发起生成)→approve 人工总耗时（验收 ↓60%，spec §5/PRD §50）；
  采纳率/修改率报表（F10.6.4）
```

### 1.3 关键架构决策

| # | 决策 | 溯源 |
| ---- | ---- | ---- |
| A1 | **LLM 全 feature 仅一处、永不触碰结论性数值**：LLM 只产出五维链文本（功能/失效模式/失效影响/失效原因/控制措施，FR7.1.2）；引用挂接（FR7.1.3）、S/O/D 建议（FR7.2.1 明确"内置规则+历史打分统计"）、RPN 与色标（FR7.2.3）全部为确定性代码。LLM 输出不直接产生任何引用或分值，"引用真实、打分可解释"由构造保证而非 prompt 约定（同 F6 plan A1 分层手法） | FR7.1.2、FR7.1.3、FR7.2.1、FR7.2.3 |
| A2 | **输入只走 F1 统一解析模型且必须 PARSE_CONFIRMED**：document_ids 均须属当前项目、经 F1 解析成功且人工校对确认（FMEA 生成质量直接依赖解析正确性，宽于 F6 的 xlsx 通道不可取——生成类输入无 native 确定性通道）；LLM 输入按 sections/fields 组装 + scope_note 相关性截断，规格参数表（F1.4 fields）优先保留 | FR7.1.1；specs/README 数据契约、FR1.6.2；F6 plan A2 对照 |
| A3 | **有效性自检为代码级校验 + 一次带错误反馈的重试**：LLM 返回后 validate.py 逐行校验五维非空（FR7.1.2"任一为空则该行无效"），无效行集合作为错误反馈重试 1 次；仍无效则剔除并计入 generate_meta.invalid_dropped（审计可查，不静默丢弃）；重试后仍为空结果则任务 FAILED（FMEA_GENERATION_FAILED） | FR7.1.2；FR10.3.1 |
| A4 | **引用只能来自真实 F3 检索**：逐行复用 F3 混合检索服务（进程内调用，F3 plan §1 检索服务化），命中 chunk 写共用表 object_source_link（src_type=fmea_row，F3 plan A8）；检索无命中行 evidence_status='no_hit'，UI 标注"无历史依据"（FR7.1.3）；LLM prompt 中明确禁止产出任何引用/案例编号，即使输出也被丢弃（结构化 schema 不含引用字段，构造性杜绝） | FR7.1.3、FR7.3.1；F3 plan A8；AC3.5.1 抑制幻觉语义 |
| A5 | **S/O/D 建议为确定性规则引擎、每维一句理由**：S=失效影响文本语义匹配 rubric 分档（安全/法规→9–10…，C-Q1 初版表）；O=检索命中历史案例中的既有打分统计分位数（历史 FMEA 文档经 F1 表格解析抽取，best-effort：无统计时回落 rubric 中位档）；D=控制措施可探测性语义匹配 rubric 分档（C-Q1）。理由串由规则命中项模板化生成（如"S=9：失效影响涉及安全风险（rubric v2 DRAFT 分档）"），打分建议带「依据未定版评分标准」标记当 rubric 处于 DRAFT（C-Q1 Assumptions） | FR7.2.1、FR7.2.2；C-Q1 及 Assumptions |
| A6 | **rubric 平台域配置、DRAFT→APPROVED、分值快照固化**：`sod_rubrics` 挂平台域（C-Q1(a)），我方起草 DRAFT 初版入库，客户研发/质量专家 APPROVED 后线上生效；未定版时用 DRAFT 打分不阻塞（C-Q1 Assumptions）。**分值随行快照固化**：fmea_rows.suggestion 在生成时点写入，rubric 变更仅影响新生成任务与未打分行，已定版 FMEA 不重算（C-Q1 Assumptions）；run 无需版本快照字段，理由来源串已含 rubric 版本 | FR7.2.2、FR7.2.4；C-Q1；F6 plan A6 同构手法 |
| A7 | **行数双重上限配置化 + 硬校验 + 截断提示**：单次生成输出 ≤50 行（`fmea.generate.row_limit`），超限按 seq 顺序保留前 50 条有效行（确定性截断，C-Q3 Assumptions：不额外调用 LLM 复核）并在任务完成事件提示"可缩小范围或分区域多次生成"；单版本累计 ≤200 行（`fmea.total.row_limit`），超限增行接口返回 `FMEA_ROW_LIMIT_EXCEEDED`；人工增行计入、删行释放配额（C-Q3 Assumptions）。分区域多次生成 = 对同一 DRAFT fmea 追加批次（generate 携 fmea_id），天然落在 F4.5 异步任务模型内（C-Q3） | FR7.1.1、FR7.1.2、FR7.1.4；C-Q3 |
| A8 | **状态机接 F10.2 通用 workflow、修订 = 版本链复制**：fmea 继承 BaseEntity，state 走 F10.2 通用状态机 `DRAFT→IN_REVIEW→APPROVED`（F10.2 映射表 FMEA 行）；spec §4 的 submit-review/approve 为 F10 通用 transition 的语义化包装端点（内部同一 workflow 组件），approve 校验角色 `fmea.confirm`（仅研发主管，FR10.5.2 矩阵）+ comment 必填（FR7.5.2）；APPROVED 后编辑类接口返回 `OBJECT_LOCKED`（FR10.2.4、AC7.5.1）；revise 仅限 APPROVED 态：复制 fmea 与全部行为新记录（revision+1、prev_revision_id、行保留 origin_row_id 血缘），旧版本保持 APPROVED 只读留存；版本对照按 origin_row_id 血缘对齐做行级 diff（FR7.5.3）。AI 无任何直写 APPROVED 通路——approve 仅由人工 API 触发（FR10.2.2、spec §5） | FR7.5.1–FR7.5.3、AC7.5.1；FR10.2.1–FR10.2.4；spec §5 |
| A9 | **diff 单表双用：修改率统计与审计共用**：fmea_row_diffs 为唯一修改留痕处（spec §3"修改率与审计共用"）；行内编辑逐字段写 diff（old/new + edited_by/at），audit row.edited 引用 diff id 列表；修改率 = 有 ≥1 条 diff 的采纳行 / 采纳行（FR7.4.3）。[AI] 角标为**单元格级**：cell_ai_flags JSONB 记录五维+S/O/D 逐字段 AI/人工归属，人工改动仅消除被改字段的角标（FR7.4.2"人工修改后角标消失"的精确语义）；行级 ai_generated 保留（采纳率分母） | FR7.4.2、FR7.4.3、AC7.4.1；spec §3、§5 |
| A10 | **导出异步任务 + 水印以定版时点为准**：Excel（openpyxl，标准 FMEA 表格排版，表头含 S/O/D/RPN 列）与 Word（python-docx）放 Celery `fmea` 队列，产物写 MinIO 返回预签名 URL；state≠APPROVED（DRAFT/IN_REVIEW）注入"草稿"水印（FR7.6.1 明确 DRAFT 带水印，IN_REVIEW 同属未定版，见 §7 假设①）；内容含行明细、审核意见、版本号、定版人与时间（FR7.6.2） | FR7.6.1、FR7.6.2；specs/README 异步约定 |
| A11 | **前端页面16按 UI_GUIDE 落地、表格交互客户端内存完成**：类电子表格组件（行内编辑、增行/删行、按列排序、按风险等级筛选，FR7.4.1）基于 ≤200 行上限（C-Q3）做全量加载 + 客户端排序筛选，无服务端分页复杂度；[AI] 角标（FR7.4.2）、RPN 色标（FR7.2.3）、行级 [采纳][忽略][查看历史案例]（UI 页面16）、历史案例侧滑抽屉复用 F3.4 原文定位端点跳转原文（FR7.3.1）；定版按钮仅研发主管可见（前端展示控制，后端强制校验，FR10.5.4） | FR7.4.1–FR7.4.3、FR7.3.1、FR7.2.3、FR7.5.2；UI_GUIDE 页面16；F10 plan A7 |
| A12 | **F4 技能与 F9.6 复用同一入口**：F4 fmea_gen 技能经 `POST /fmeas/generate` 同一入口发起（spec 头表被依赖关系，同 F6 假设⑥）；F9.6 报告异常转 FMEA 风险条目经 `POST /fmeas/{id}/rows/batch`（action=add，source='report_anomaly'，携带 report/anomaly 元数据入 evidence/source 备注），目标 fmea 须为 DRAFT 态且计入 200 行配额（A7）；产生的行为人工发起对象（source≠AI 生成，不计采纳率分母） | spec 头表；F4.4.2、F9.6；C-Q3 |

---

## 2. 数据模型

> 全部主键 UUIDv7、时间戳 UTC（specs/README 约定）。`fmeas` 继承 F10 BaseEntity 公共列（FR10.1.3：id/project_id/created_by/created_at/updated_at/state/audit_ref）；注册进 F10.1 统一对象模型（FR10.1.1 FMEA(+FmeaRow)）。

### 2.1 fmea 与 fmea_row（spec §3）

```text
fmeas(                               # 一个 FMEA 版本（修订链上的一环，A8）
  # BaseEntity 公共列：id, project_id, created_by, created_at, updated_at,
  #                    state(DRAFT→IN_REVIEW→APPROVED, F10.2), audit_ref
  product_id→products NULL,          # 产品上下文（spec §3 product_id?；FR10.1.2 Product 1—N FMEA）
  root_id UUID,                      # 修订链根 id（同链各版本共享，版本列表查询键）
  prev_revision_id→fmeas NULL,       # 前一修订版本（链式追溯，FR7.5.3）
  revision INT DEFAULT 1,            # 版本号（revise +1，FR7.5.3）
  scope_note TEXT NULL,              # FMEA 范围说明（FR7.1.1 可选输入；分区域生成依据，C-Q3）
  source_document_ids JSONB,         # 生成输入文档清单快照 [{document_id, doc_version,
                                     #  parse_version}]（FR7.1.1；审计回溯）
  generate_meta JSONB NULL,          # {model, model_version, prompt_id, prompt_version,
                                     #  kb_version, output_rows, invalid_dropped, truncated,
                                     #  batches[]}（spec §5 审计 fmea.generated 数据源；FR10.3.1）
  risk_thresholds JSONB,             # 色标阈值快照 {red_gte:100, orange_gte:50}（FR7.2.3，C-Q2，
                                     #  定版时点固化，平台配置项可按项目调整）
  review_comment TEXT NULL,          # 定版审核意见（APPROVED 必填，FR7.5.2）
  approved_by→users NULL, approved_at,
  stats JSONB NULL,                  # {ai_rows, adopted_rows, modified_rows, no_hit_rows}
                                     #  采纳率/修改率与 KPI 报表的预聚合（FR7.4.3、AC7.4.1）
  deleted_at TIMESTAMPTZ NULL        # DRAFT 软删（§7 假设④）
)
-- 索引：(project_id, state), (root_id, revision)

fmea_rows(
  id UUIDv7 PK, fmea_id→fmeas,
  origin_row_id UUID NULL,           # 修订复制血缘（版本对照对齐键，A8/FR7.5.3）
  seq INT,                           # 行序（UNIQUE(fmea_id, seq)；截断按 seq，C-Q3）
  function TEXT, failure_mode TEXT, effect TEXT, cause TEXT, control TEXT,
                                     # 五维链（任一为空即无效行，FR7.1.2）
  s INT NULL, o INT NULL, d INT NULL,# 1–10（NULL=未打分，人工增行待打分）
  rpn INT NULL,                      # RPN = S×O×D，服务端写入时点重算（FR7.2.3）
  risk VARCHAR NULL,                 # RED | ORANGE | GREEN（写入时点按阈值快照计算，FR7.2.3/C-Q2）
  suggestion JSONB NULL,             # AI 打分建议快照 {s:{value,reason}, o:{...}, d:{...}}
                                     #  含 rubric 版本与"依据未定版标准"标记（FR7.2.1，A5/A6）
  ai_generated BOOLEAN DEFAULT false,# 行级 AI 生成标记（采纳率分母，FR7.4.3）
  cell_ai_flags JSONB,               # {function,failure_mode,effect,cause,control,s,o,d}→bool
                                     #  单元格级 [AI] 角标（人工改后置 false，FR7.4.2，A9）
  row_status VARCHAR DEFAULT 'manual',  # ai_pending | adopted | ignored（AI 行）；manual（人工/F9.6 行）
                                     #                                           （FR7.4.3）
  source VARCHAR DEFAULT 'manual',   # generation | manual | report_anomaly（F9.6，A12）
  source_ref JSONB NULL,             # report_anomaly 来源 {report_id, anomaly_id}（A12）
  evidence_status VARCHAR,           # linked | no_hit（"无历史依据"标注，FR7.1.3，A4）
  created_by→users, created_at, updated_at
)
-- 索引：(fmea_id, seq) UNIQUE, (fmea_id, row_status), (fmea_id, risk), (origin_row_id)
-- 引用清单不在此表：经 object_source_link(src_type='fmea_row', src_id=row_id) 关联（F3 plan A8）
```

### 2.2 fmea_row_diff 与 sod_rubric（spec §3）

```text
fmea_row_diffs(                      # 修改率与审计共用（spec §3，A9）
  id UUIDv7 PK, row_id→fmea_rows, fmea_id, field VARCHAR,
                                     # function|failure_mode|effect|cause|control|s|o|d
  old_value JSONB, new_value JSONB,
  edited_by→users, edited_at
)
-- 索引：(row_id), (fmea_id, edited_by, edited_at)（修改率按行聚合：行有≥1条 diff 即"被修改"）
-- append 友好：不 UPDATE/DELETE（更正以新 diff 记录冲正，对齐审计 append-only 语义 FR10.3.2）

sod_rubrics(                         # 评分标准表（FR7.2.2；平台域，C-Q1(a)）
  id UUIDv7 PK,
  dimension VARCHAR,                 # s | o | d
  score INT,                         # 1–10
  semantic_description TEXT,         # 语义分档描述（FR7.2.2"语义描述"）
  weight NUMERIC NULL,               # spec §3 weight?（Phase 1 不参与计算，预留，§7 假设⑤）
  version INT,                       # 整表版本（一次评审一个版本）
  state VARCHAR,                     # DRAFT | APPROVED（复用 F10 workflow；仅 APPROVED 线上生效，
                                     #  无 APPROVED 版本时回落最新 DRAFT，C-Q1 Assumptions/A5）
  approved_by→users NULL, approved_at, created_by, created_at, remark
)
-- 索引：(dimension, score, version, state)
-- 变更走维护接口 + audit sod.rubric.updated（C-Q1；<domain>.<verb> 对齐 FR10.3.3）
-- 评测集（C-Q1(b)）为 evals/fmea_generation/ 测试资产，不入线上库（clarifications 明确）
```

### 2.3 复用与关联（不新建表）

```text
object_source_link                   # F3/F7 共用单表（F3 plan A8）：src_type='fmea_row'，
                                     #  dst=document/chunk（含 page/bbox 定位，FR7.3.1 跳转原文）
tasks                                # F10.1 Task 对象：type='fmea_gen'|'fmea_export'，
                                     #  result_ref=fmea_id（FR7.1.4、F4.5.1）
issues                               # F10.1（F7 本体不直写；F6.5 转整改任务可引用 FMEA 行，
                                     #  Phase 1 不建 FMEA→Issue 专属链接，§7 假设⑥）
```

---

## 3. API 设计（遵循 specs/README：REST /api/v1、统一错误体、异步任务 SSE）

### 3.1 端点清单

```text
# 生成（F7.1，异步）
POST /api/v1/fmeas/generate          # body: {project_id, document_ids[], product_id?,
                                     #  scope_note?, fmea_id?}（fmea_id=向既有 DRAFT 追加批次，
                                     #  C-Q3 分区域生成）→ 201 {fmea_id, task_id}
                                     #  校验：权限 fmea.create、文档属项目 + PARSE_CONFIRMED（A2）、
                                     #  追加时 DRAFT 态 + 200 行配额（A7/C-Q3）
GET  /api/v1/fmeas                   # ?project_id=&state=&page=&page_size= 项目内 FMEA 版本列表
GET  /api/v1/fmeas/{id}              # 表头 + 全量行（≤200 行全量，A11）+ 每行引用摘要
                                     #  （FR7.1.4"表格数据（行+引用）"）

# 行编辑与批量（F7.4）
PATCH /api/v1/fmeas/{id}/rows/{rid}  # body: {patch: {field: value,...}}（五维/S/O/D）
                                     #  逐字段写 diff + cell_ai_flags 消角标 + audit row.edited
                                     #  （FR7.4.2、FR7.2.4）；S/O/D 变更服务端重算 rpn/risk（FR7.2.3）；
                                     #  APPROVED 态返回 OBJECT_LOCKED（AC7.5.1）
POST /api/v1/fmeas/{id}/rows/batch   # body: {action: adopt|ignore|add|delete,
                                     #  row_ids?|filters?|rows?}（FR7.4.1 增删行、FR7.4.3 批量采纳/忽略）
                                     #  add：source=manual|report_anomaly（A12/F9.6），计入配额（A7）
                                     #  部分成功语义：响应逐条成功/失败（超限行报 FMEA_ROW_LIMIT_EXCEEDED）
GET  /api/v1/fmeas/{id}/rows/{rid}/evidence
                                     # 行引用明细（片段/来源文档/项目/时间/定位 bbox，FR7.3.1，
                                     #  = GET /api/v1/links?src_type=fmea_row&src_id= 的语义化包装）

# 引用增删（F7.3.2）——复用 F3 通用链接接口（F3 plan A8，A4）
POST   /api/v1/links                 # {src_type:'fmea_row', src_id, document_id, anchor}
DELETE /api/v1/links/{id}            # → rag.link.created/deleted 审计（F3 已定义）

# 审核流（F7.5，F10.2 workflow 包装，A8）
POST /api/v1/fmeas/{id}/submit-review  # DRAFT→IN_REVIEW（权限 fmea.edit；FR7.5.1）
POST /api/v1/fmeas/{id}/approve        # IN_REVIEW→APPROVED；body: {comment}（必填，FR7.5.2）；
                                       #  权限 fmea.confirm（仅研发主管，FR10.5.2；工程师 403，AC7.5.1）
POST /api/v1/fmeas/{id}/revise         # APPROVED→复制新 DRAFT 版本（revision+1，FR7.5.3）
GET  /api/v1/fmeas/{id}/revisions      # 同链版本列表（root_id 查询，FR7.5.3 版本可对照）
GET  /api/v1/fmeas/compare?base=&target=
                                       # 版本对照：origin_row_id 血缘对齐的行级 diff
                                       #  （changed/added/removed，FR7.5.3，A8）

# 评分标准（FR7.2.2，C-Q1(a)）
GET/POST/PUT /api/v1/fmeas/rubric     # 整表版本化 CRUD（平台域，AI管理员/系统管理员维护入口）
POST /api/v1/fmeas/rubric/{version}/transition   # DRAFT→APPROVED（客户专家=定版权限持有者，
                                                 #  C-Q1；audit sod.rubric.updated）

# 导出（F7.6，异步）
POST /api/v1/fmeas/{id}/export       # body: {format: excel|word} → task_id（A10）
GET  /api/v1/fmeas/{id}/exports      # 导出历史（format/file_url/created_at）

# 任务（specs/README 异步约定）
GET  /api/v1/tasks/{id}/events       # SSE：QUEUED/RUNNING(stage=gather|generate|validate|retrieve|
                                     #  score|export, progress)/SUCCESS/FAILED/CANCELED
POST /api/v1/tasks/{id}/cancel       # F4.5（生成任务可取消）
```

### 3.2 语义与错误

- 统一错误体 `{"code","message","detail"}`。本 feature 新增错误码：
  - `FMEA_SOURCE_DOC_NOT_READY`（FR7.1.1：所选文档未解析成功或未 PARSE_CONFIRMED，detail 列出不合格文档）
  - `FMEA_GENERATION_FAILED`（LLM 生成/重试后仍无有效行，A3）
  - `FMEA_ROW_LIMIT_EXCEEDED`（C-Q3：单版本累计超 200 行，增行被拒；单次截断不报错、走任务事件提示）
  - `FMEA_NOT_DRAFT`（追加批次/增删行/编辑要求 DRAFT 态，当前为 IN_REVIEW）
  - `OBJECT_LOCKED`（复用 F10 通用码：APPROVED 后编辑/增删行/采纳被拒，AC7.5.1、FR10.2.4）
  - `FMEA_REVIEW_COMMENT_REQUIRED`（approve 缺 comment，FR7.5.2）
  - `FMEA_INVALID_TRANSITION`（状态机非法流转，如 DRAFT 直接 approve——FR10.2.1 映射为 IN_REVIEW 必经）
  - `FMEA_EXPORT_UNSUPPORTED_FORMAT`（FR7.6.1 白名单 excel|word 之外）
  - 403（权限不足：工程师定版 AC7.5.1、非项目成员访问等，走 F10.5 统一语义 FR10.5.4）
- **异步边界**：生成与导出走 Celery `fmea` 队列返回 `task_id`、进度经 SSE（specs/README 异步约定）；行编辑、批量采纳/忽略、引用增删、submit-review/approve/revise、rubric 维护为同步操作；F4 fmea_gen 技能经同一 generate 端点入队（A12）。
- **幂等与并发**：行编辑以后写为准（单工作台编辑假设，spec §6 非目标排除协同编辑）；批量操作与定版并发时以 transition 行锁为准，后到者收 `OBJECT_LOCKED`；revise 幂等保护（同链并发 revise 串行化取 max(revision)+1）。
- **权限**（F10.5 矩阵）：查看/编辑/采纳/提交审核/导出 = 工程师+（项目成员可见性继承 FR10.5.3）；定版（approve）与 rubric APPROVED = 研发主管（rubric 维护入口限系统/AI管理员，生效评审由研发/质量专家执行，C-Q1）；FMEA 可见性随项目继承。
- **统计口径**（FR7.4.3、AC7.4.1）：采纳率 = adopted 行数 / AI 生成行数（ai_generated=true 全集）；修改率 = 存在 diff 的采纳行数 / adopted 行数；分母仅计 AI 行（source=generation），人工增行与 F9.6 转入行不进入分母（A12）；fmeas.stats 预聚合 + F10.6 KPI 埋点双写。

---

## 4. AI/LLM 使用点

| 项 | 设计 | 溯源 |
| ---- | ---- | ---- |
| LLM 使用范围 | **一处**：五维链结构化生成（FR7.1.2）。引用检索（FR7.1.3）、S/O/D 打分（FR7.2.1）、RPN/色标（FR7.2.3）、有效性自检与截断（FR7.1.2 自检半段、C-Q3）、diff/统计/导出全部确定性代码 | FR7.1.2；A1 |
| 模型策略 | 经 F10 `LLMGateway`：生成模型走配置（私有化可替换、数据不出企业域，PRD §53）；审计记录运行时实测 model/model_version。无 embedding 新增需求（引用检索复用 F3 既有向量通道） | F10 plan §4 挂点 2；FR10.3.1 |
| Prompt 策略 | Prompt 注册表管理，单一 prompt_id：`f7.five_dim_chain`（输入：项目/产品上下文 + scope_note + 所选文档 F1 解析模型的章节/字段/表格序列化文本（按相关性截断，参数表优先，A2）+ 输出要求；系统指令：围绕功能→失效模式→失效影响→失效原因→控制措施五维链展开、覆盖 scope_note 范围、禁止编造引用或历史案例编号、禁止输出分值）；分区域多次生成时以 scope_note 切分输入（C-Q3）。禁止裸字符串 prompt（FR10.3.4） | FR7.1.1、FR7.1.2；FR10.3.4；C-Q3 |
| 结构化输出 schema | 强制 JSON Schema（Pydantic 校验）：`{"rows":[{"function","failure_mode","effect","cause","control","seq"}]}`，≤50 行（C-Q3）；schema 缺字段/五维空 → 带错误反馈重试 1 次（A3）；仍失败 → 剔除无效行计数，全空则任务 FAILED。**schema 不含引用与分值字段**——LLM 无法输出引用/打分（构造性防幻觉，A1/A4） | FR7.1.2；C-Q3；F10 plan §4 挂点 3 |
| Grounding/防幻觉 | ① 引用仅来自真实 F3 检索命中（A4）；② 打分仅来自 rubric 规则 + 历史统计（A5）；③ 逐行自检剔除空维度（FR7.1.2）；④ 生成产物整体为 DRAFT、[AI] 角标 + 人工审核定版（FR7.4.2、FR7.5、specs/README AI 草稿语义）；⑤ 审计记录 kb_version + 引用清单可抽样回查引用正确性（FR10.3.1） | FR7.1.2、FR7.1.3、FR7.5.1；FR10.3.1 |
| 审计接入 | `fmea.generated`（模型/prompt 版本/kb_version/引用清单/输出行数 + invalid_dropped/truncated，spec §5）、`row.edited`（diff id 列表）、`row.adopted`/`row.ignored`、`fmea.approved`（含 comment 与 diff 摘要）、扩展 `fmea.submitted`/`fmea.revised`/`fmea.exported`/`sod.rubric.updated`（均 `<domain>.<verb>`，FR10.3.3 清单外新增按同规则命名）；AC10.3.1 的 FMEA 全链路重建以本模块为主场景 | spec §5；FR10.3.1、FR10.3.3；C-Q1 |
| KPI 埋点 | `fmea.generate`（任务耗时，F10.6.2）；`start(发起生成)→approve` 人工总耗时（fmeas.created_at→approved_at，验收 ↓≥60% 的分母为 F10.6.3 人工基线）；`row.adopted/ignored` 埋点供采纳率/修改率报表（FR10.6.4、PRD §50 AI 类 KPI） | spec §5；FR10.6.2–FR10.6.4 |
| 评测方式 | ① **AC7.1.1 金标评测**（M4 硬门槛）：`evals/fmea_generation/` 内置 C-Q1(b) 金标集——3 个项目（电池包级 1 + 子系统级 2，不足降级 2+1，clarifications Assumptions）× ≥10 行金标行；离线跑生成管线断言：行数 ≥10、五维无一为空、维度语义正确性人工走查通过；② 自动指标（观测）：有效行率（自检通过行/LLM 原始行）、单调用行数分布、引用命中率（有引用行/总行）、引用抽样正确率（人工标注）；③ prompt/模型版本变更触发金标回归（C-Q1(b) 用途）；④ 线上采纳率/修改率为质量观测指标（不设硬门槛——采纳率受人工习惯影响）；⑤ `start→approve` 耗时对照人工基线验收 ↓60% | AC7.1.1；C-Q1(b)；spec §5 KPI |

---

## 5. 测试策略

| 层级 | 内容 | 溯源 |
| ---- | ---- | ---- |
| 单元（生成自检） | 五维空值逐维剔除；规范化去重（功能+失效模式空白归一）；按 seq 截断至 50 的确定性（C-Q3 Assumptions：保留前 50 有效行）；重试反馈构造；全空结果 → FAILED；invalid_dropped/truncated 计数正确 | FR7.1.2；C-Q3；A3/A7 |
| 单元（打分引擎） | rubric 语义分档匹配矩阵（S：安全/法规→9–10…五档；D：无探测→9–10…自动在线检测→1–2）；O 历史统计分位回落中位档；rubric DRAFT 态理由带「依据未定版评分标准」、APPROVED 后不带（C-Q1 Assumptions）；RPN 计算（S×O×D）与色标三段阈值（≥100 红/50–99 橙/<50 绿，C-Q2）；阈值快照快照化（定版不重算，A6）；打分理由一句模板生成 | FR7.2.1–FR7.2.3；C-Q1/C-Q2；A5/A6 |
| 单元（编辑与统计） | PATCH 逐字段 diff 生成（old/new）；cell_ai_flags 单字段消角标（FR7.4.2 精确语义）；S/O/D 修改后 rpn/risk 重算（FR7.2.3）；采纳率/修改率口径（分母排除 manual/report_anomaly 行，A12/§3.2）；删行释放配额（C-Q3 Assumptions） | FR7.2.4、FR7.4.2、FR7.4.3、AC7.4.1；C-Q3 |
| 集成（生成管线） | fixtures：预置规格书（F1 解析桩）端到端跑 SUCCESS；断言 SSE 事件序列 QUEUED→RUNNING(gather/generate/validate/retrieve/score)→SUCCESS；行落库 ai_generated=true + suggestion 快照 + evidence_status；引用行写 object_source_link 且可经 /links 反查；无命中行标 no_hit（FR7.1.3）；>50 行截断提示出现在任务事件（C-Q3）；文档未确认返回 `FMEA_SOURCE_DOC_NOT_READY`；追加批次配额校验 | FR7.1.1–FR7.1.4、AC7.1.1；C-Q3；specs/README 异步 |
| 集成（编辑与批量） | 行内编辑 → diff 落库 + 角标消除 + audit row.edited；批量采纳/忽略部分成功语义；采纳/忽略/行内编辑后 fmeas.stats 正确（AC7.4.1 KPI 报表数字出现）；引用增删经 /links 生效且审计 rag.link.created/deleted（FR7.3.2） | FR7.3.2、FR7.4.1–FR7.4.3、AC7.4.1 |
| 集成（审核流，F10 样板闭环 AC10.2.1/AC10.3.1 的 F7 侧断言） | 工程师 approve → 403（AC7.5.1）；研发主管 approve 缺 comment → `FMEA_REVIEW_COMMENT_REQUIRED`；成功定版后 PATCH/批量/revise 之外的编辑类接口返回 `OBJECT_LOCKED`（AC7.5.1）；DRAFT 直接 approve → `FMEA_INVALID_TRANSITION`；revise → revision+1、旧行 origin_row_id 血缘完整、旧版本只读；compare 按血缘输出行级 diff；审计链完整重建（who/when/input/model/prompt/kb_version/output/human diff/final，AC10.3.1） | FR7.5.1–FR7.5.3、AC7.5.1；FR10.2、AC10.2.1、AC10.3.1；A8 |
| 集成（导出） | Excel 表头含 S/O/D/RPN 列 + 行明细/审核意见/版本号/定版人与时间（FR7.6.1/7.6.2）；DRAFT 导出水印存在、APPROVED 导出无水印（A10）；Word 同口径；异步任务产物可下载 | FR7.6.1、FR7.6.2 |
| **禁绕过测试**（AC1.6.1 复用） | import-linter 禁止 fmea 模块直读 MinIO 原件/自建文档解析（输入一律消费 F1 解析模型）；禁止 fmea 模块直连模型 SDK（必须经 LLMGateway，F10 plan 挂点 2）；检索必须经 rag 模块服务接口（禁止自行查 chunks 表） | FR1.6.2、AC1.6.1；FR10.3.4；F3 plan A8 |
| 权限矩阵 | 参数化：5 角色 × {生成/编辑/采纳/提交审核/定版/修订/导出/rubric 维护/rubric 定版}；项目可见性断言；F4 fmea_gen 技能复用同一入口断言（A12） | FR10.5 矩阵；AC7.5.1 |
| API 契约 | 统一错误体/分页信封/SSE payload schema；新错误码逐条断言；批量操作部分成功响应结构 | specs/README、§3.2 |
| 评测 | `evals/fmea_generation/` 金标集（C-Q1(b)）：AC7.1.1 ≥10 行有效五维链 + 维度语义人工走查（M4 硬门槛）；有效行率/引用命中率/引用抽样正确率（观测）；prompt/模型变更回归；报告版本化归档 | AC7.1.1；C-Q1(b)；§4 评测 |
| 前端 | 组件测试：类电子表格行内编辑/增删行/排序/风险筛选（FR7.4.1）；[AI] 角标随编辑消失（FR7.4.2）；批量采纳/忽略与统计数字刷新（AC7.4.1）；RPN 色标（FR7.2.3）；历史案例侧滑与原文跳转（FR7.3.1）；生成对话框（文档多选 + scope_note + 追加批次）；审核流按钮按角色显隐（FR7.5.2）；版本对照视图（FR7.5.3）；水印提示 | FR7.3–FR7.6 各条；UI_GUIDE 页面16 |

覆盖率目标遵循全局规则（新增模块 ≥80%）。

---

## 6. 风险与非目标

### 风险

| 风险 | 影响 | 缓解 |
| ---- | ---- | ---- |
| LLM 五维链质量不稳定（维度语义错位、行间重复、泛泛而谈）致 AC7.1.1 不达标或采纳率低迷 | 验收失败 / KPI 失效 | 代码级自检剔除空维度（FR7.1.2，A3）；金标评测集回归（C-Q1(b)）驱动 prompt 迭代；scope_note 引导分区域聚焦生成（FR7.1.1、C-Q3）；无效行/截断计数入审计可观测（A3/A7） |
| 规格书超长导致输入截断、生成遗漏关键子系统 | 初稿覆盖不全 | 相关性截断策略（参数表优先，A2）；分区域多次生成累积至 200 行（C-Q3）；generate_meta 记录截断量供人工判断补批次 |
| 检索无命中率偏高（知识库冷启动） | 大量行标"无历史依据"，历史依据价值打折 | F3 检索阈值复用 F3 plan A5 口径（no_hit 阈值可调）；evidence_status 可筛选，支持人工补链（FR7.3.2）；KB 冷启动属 F2 交付范畴（M2 先于 M4） |
| rubric 长期停留 DRAFT（客户专家评审延迟） | 打分理由带"未定版"标记，权威性受疑 | C-Q1 兜底不阻塞：DRAFT 初版打分、行级理由明示；M4 Exit 前置检查项推动评审（同 F6 关键件清单处理方式） |
| 历史案例打分统计不可得（历史 FMEA 无结构化 S/O/D） | O 值建议退化为 rubric 默认档 | best-effort 设计（A5）：统计命中才用，未命中回落 rubric 中位档并在理由中说明；不影响 AC7.1.1（其只约束五维链） |
| 200 行累计上限不足以覆盖超大型整包 FMEA（真实规模 100–300 行） | 增行被拒阻碍真实使用 | 阈值为平台配置项（C-Q3）可按项目上调；超限错误信息引导分区域/分版本；上限语义按"单版本"而非"单对象"，revise 后配额重置 |
| KPI 基线缺失（人工 FMEA 初稿耗时未测） | ↓60% 无法验收 | F10.6.3 人工基线联合测量为 M1 交付项；`fmea.generate` 与 start→approve 打点全程覆盖（spec §5） |
| 采纳率/修改率口径分歧（哪些行计入分母） | AC7.4.1 报表数字争议 | 口径在 §3.2 固化（分母仅 AI 生成行）并写入 stats 预聚合注释与 KPI 报表说明；口径变更需评审（对齐 FR10.6.4 报表定义） |
| 并发编辑冲突（多人同时打开工作台） | 后写覆盖前写 | Phase 1 单人编辑假设（spec §6 非目标排除协同编辑）；diff 留痕可追溯；工作台进入时提示他人正在编辑（软提示，不拦截） |

### 非目标（Phase 1）

- DFMEA/PFMEA 模板差异与工艺流程联动（PFMEA 属第二阶段制程能力，spec §6）
- VDA-SSR / Action Priority（A/P 列 + H/M/L）打分体系（C-Q2 明确列 Phase 2，不改变既有 S/O/D/RPN 数据模型）
- 多方协同实时编辑（spec §6；后写为准 + 软提示）
- FMEA 数据库跨项目复用治理、跨项目模板库（spec §6）
- AI 直写 APPROVED / 任何终态（FR10.2.2 架构约束；approve 仅人工 API）
- 打分建议的 LLM 化、S/O/D 自动重算已定版 FMEA（FR7.2.1 规则为确定性；分值快照固化，A6）
- FMEA→Issue 专属关联模型（F6.5 转整改任务可文本引用 FMEA 行，结构化链接 Phase 2，§7 假设⑥）
- 五维链生成的多模型投票/自一致性（Phase 1 单次生成 + 重试 + 金标回归已满足 AC7.1.1，成本收益不匹配）

---

## 7. 决策与假设记录（承接 clarifications）

- C-Q1(a)：评分标准表由我方起草默认初版（S 按影响严重度五档 / O 按历史频次统计 / D 按可探测性分档），平台域 `sod_rubrics` DRAFT 入库、客户研发/质量专家 APPROVED 后生效；未定版用 DRAFT 打分且理由注明「依据未定版评分标准」；分值随行快照固化，已定版 FMEA 不重算；变更走维护接口 + `sod.rubric.updated` 审计。→ §2.2、§3.1、A5、A6、§4、§5、§6
- C-Q1(b)：评测集 = 3 个历史项目金标（电池包级 1 + 子系统级 2；不足降级 2+1 公开案例），我方标注 ≥10 行/项目 + 客户 FMEA 工程师确认，固化于 `evals/fmea_generation/`（测试资产不入线上库、不走状态机），用于 AC7.1.1 验收与 prompt/模型回归。→ §4 评测、§5
- C-Q2：AIAG-VDA 经典 RPN 体系（RPN=S×O×D，1–1000；红≥100/橙50–99/绿<50），阈值为平台配置项可按项目调整（fmeas.risk_thresholds 快照固化）；VDA-SSR/AP 列 Phase 2。→ §2.1、A5、§5、§6
- C-Q3：单次生成 ≤50 行（超限按 seq 确定性截断 + 任务事件提示）、单版本累计 ≤200 行（超限 `FMEA_ROW_LIMIT_EXCEEDED`），均为配置项（`fmea.generate.row_limit`/`fmea.total.row_limit`）；分区域多次生成 = 向同一 DRAFT fmea 追加批次；截断不调用 LLM 复核；人工增行计入、删行释放配额。→ §3.1、A7、§5、§6
- 新增决策（无对应 Q，依 FR 推定，均已在正文标注）：
  - **假设①** 导出水印以 state≠APPROVED 为准（FR7.6.1 仅明确 DRAFT；IN_REVIEW 同属未定版，水印口径统一为「未定版」）。
  - **假设②** 排序/筛选在客户端内存完成（≤200 行全量加载，C-Q3 上限使然；FR7.4.1 语义不受影响）。
  - **假设③** `fmea_row_diffs` 不删改（冲正以新记录追加），对齐审计 append-only 语义（FR10.3.2 精神，该表非审计表本体）。
  - **假设④** DRAFT fmea 可由发起人软删（无独立 spec 条款，对齐 F6 plan A8 手法）；IN_REVIEW/APPROVED 永久留存。
  - **假设⑤** `sod_rubric.weight` 字段预留不参与 Phase 1 计算（spec §3 未给语义）。
  - **假设⑥** FMEA 与 Issue 不建结构化关联（F6.5/F9 整改任务可引用 FMEA 行号文本）；如需双向跳转，Phase 2 复用 F6 的 source_type 链接模式。
  - **假设⑦** F9.6 异常转风险条目经 `POST /rows/batch`（action=add, source='report_anomaly'）实现，行为人工发起（不计采纳率分母），目标须 DRAFT 且受 200 行配额约束（A12；F9 plan 细化其侧调用契约）。
  - **假设⑧** 修订版本链以 `root_id + revision` 建模、行血缘以 `origin_row_id` 对齐（spec §3 仅给 revision 字段，链结构为 design 补全）；版本对照仅做行级内容 diff，不做列级 schema 对照。
