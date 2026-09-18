# F6 BOM智能比对 — 技术方案（Plan）

| | |
| ---- | ---- |
| Feature | F6-bom-comparison |
| 输入 | specs/F6-bom-comparison.md、specs/F6-bom-comparison.clarifications.md（冲突时以其为准）、PHASE1_SPEC.md、PHASE1_FEATURES.md、specs/README.md、UI_GUIDE 页面11/12 |
| 关联 | specs/F1-document-parsing.plan.md（统一解析模型/表格解析/禁绕过契约）、specs/F10-platform-governance.plan.md（对象模型/状态机/审计/RBAC/KPI/Issue 接入契约）、specs/F4-ai-chat.md（bom_diff 技能入口）、specs/F9-test-report.md（Issue 同类机制） |
| 阶段 | speckit-plan（仅设计，不写代码） |
| 里程碑 | M3 |

> 本 plan 中所有设计决策均标注溯源（FR/AC/Q 编号）。clarifications（Q1–Q3 决策）全文有效，本文引用处标注为「C-Qx」。

---

## 1. 架构与模块落点

### 1.1 总体架构

对齐既定技术栈：**后端 FastAPI 模块化单体 + Celery + PostgreSQL(pgvector) + MinIO；前端 React + TypeScript + Ant Design**。F6 落在独立顶层模块 `bomdiff/`，核心由四部分组成：① **导入向导管线**（文件上传 → F1 解析 → 列映射猜测与人工确认 → 行级校验，FR6.1.1–FR6.1.5）；② 确定性 **对齐与核对引擎**（对齐键、六类差异、替代料集合语义、单位换算——纯函数、无 LLM、可独立单测，FR6.2.1–FR6.2.4）；③ **规则分级 + AI 归因**（确定性规则矩阵，LLM 仅产出建议性归因一句话，FR6.3.1–FR6.3.3）；④ **处置与导出闭环**（逐条/批量处置、转 Issue、定版锁定、三格式导出，FR6.5/FR6.6）。文件输入一律经 F1 统一解析模型（specs/README 数据契约、FR1.6.2），禁止 bomdiff 自行解析 xlsx/PDF。

```text
apps/backend/
├── app/
│   ├── core/                        # F10 平台地基
│   ├── modules/
│   │   ├── bomdiff/                 # ← F6 本体
│   │   │   ├── api/                 # boms/runs/items/templates/critical-parts/export 路由
│   │   │   ├── import/              # F6.1 导入向导：上传登记、列映射猜测、模板、行级校验
│   │   │   │   ├── header_guess.py  # 两级表头猜测：确定性同义词 → LLM 语义判定（FR6.1.2）
│   │   │   │   ├── row_validate.py  # 行级校验错误列表（FR6.1.4）
│   │   │   │   └── substitutes.py   # 替代料列确定性切分（C-Q2 正则约定）
│   │   │   ├── engine/              # 对齐与核对（确定性纯函数，AC6.2.1）
│   │   │   │   ├── align.py         # 料号 / 层级路径+料号 对齐（FR6.2.1）
│   │   │   │   ├── check.py         # 六类核对项 + 替代料无序集合比较（FR6.2.2/6.2.3）
│   │   │   │   ├── quantity.py      # 数量单位换算（FR6.2.4）
│   │   │   │   └── grading.py       # 风险规则矩阵 + 关键件清单命中（FR6.3.1，C-Q1）
│   │   │   ├── attribution/         # F6.3 AI 归因（LLMGateway + grounding 校验）
│   │   │   ├── dispose/             # F6.5 处置：confirm/ignore/to_issue、批量、撤销、定版
│   │   │   ├── export/              # F6.6 Excel(openpyxl)/PDF/Word(python-docx) → MinIO
│   │   │   └── criticalparts/       # 关键件清单 CRUD + DRAFT/APPROVED 生效判定（C-Q1）
│   │   ├── documents/               # F1：进程内只读复用（parse 模型表格读取、定位端点转发）
│   │   ├── platform/                # F10：objects（Issue 创建）/workflow/audit/rbac/kpi/prompts
│   │   └── ...                      # F2–F5 各模块
│   ├── worker/                      # Celery app；bomdiff 队列（比对 + 导出两类任务）
│   └── main.py
└── alembic/
apps/frontend/
└── src/
    ├── pages/bom/                   # BOM 工作台（页面11：设计BOM/PLM BOM 列表、BOM树、物料明细）
    ├── pages/bom/import/            # 导入向导（上传 → 列映射调整 → 错误行修正，FR6.1.2/6.1.4）
    ├── pages/bom/diff/              # 比对运行列表 + 发起（A/B BOM 选择，C-Q3 历史列表）
    ├── pages/bom/diff/result/       # 页面12：总览卡片（钻取）+ 差异明细表（筛选/排序/处置）+ [AI]归因
    └── features/bom-viewer/         # BOM 树渲染、错误行修正表格、处置操作列组件
```

### 1.2 比对管线（核心流程）

```text
导入（每侧各一次）：
POST /boms/import/step1 上传 → Document 登记 + MinIO 原件 → F1 解析（xlsx native / PDF 表格经 FR1.2.2）
  → 读取统一解析模型表格 → 表头 + 前 N 行预览
POST /boms/import/step2 列映射确认 → 两级表头猜测（确定性同义词命中 → 剩余列 LLM 语义建议，FR6.1.2）
  → 人工调整确认 → 必选列校验（料号/数量，FR6.1.3）→ 替代料切分预览（C-Q2 Assumptions）
  → 行级校验（FR6.1.4）→ 错误列表返回修正（可循环）→ 通过行落 bom_row，映射存 bom.column_mapping
  → 可保存为映射模板（FR6.1.5，audit bomdiff.template.saved）

比对：
POST /bom-diff/runs（校验两侧 bom 同属项目 + 行校验全部通过，FR6.2 前置）
  → bom_diff_run(DRAFT) + Celery bomdiff 队列 → task_id（SSE 进度）
  → align：对齐键 = 料号；有层级列时 = 层级路径+料号（FR6.2.1）
  → check：逐对齐对产出六类差异（FR6.2.2）；未匹配键先查对方替代料集合 → 替代料差异（FR6.2.3，C-Q2）
  → quantity：单位可换算则归一后比较，否则字符串比对（FR6.2.4）
  → grading：规则矩阵（APPROVED 关键件清单命中 → 数量差异升高，C-Q1）；清单未定版兜底全"中"
  → attribution：批量 LLM 归因（输入仅 run 元数据 + 差异行，[AI] 标注，FR6.3.2）
  → run SUCCESS；stats/overview 落 run 行；SSE 推送 stage（align/check/grading/attribution）

人工闭环：
逐条处置 confirm/ignore/to_issue（FR6.5.1；to_issue 经 platform Issue 对象，AC6.5.1 双向链接）
批量处置（按当前筛选，FR6.5.2）；撤销处置（FR6.5.3，入审计）
全部处置完毕 → POST /runs/{id}/confirm → F10.2 workflow DRAFT→APPROVED（定版，明细锁定）
导出 PDF/Excel/Word（FR6.6，异步；DRAFT 水印）
KPI：bomdiff.start → bomdiff.confirm 耗时（对照人工基线验收 ↓70%，spec §5）
```

### 1.3 关键架构决策

| # | 决策 | 溯源 |
| ---- | ---- | ---- |
| A1 | **核对引擎与 AI 严格分层**：对齐、六类差异判定、替代料集合比较、单位换算、规则分级全部是 `engine/` 确定性纯函数模块（无 LLM、无随机性、同输入同输出）；LLM 只出现在表头映射猜测（FR6.1.2 兜底层）与 AI 归因（FR6.3.2）两处，且输出永不改变比对结论——映射建议必须人工确认、归因仅展示带 [AI]。AC6.2.1 的 100% 一致性因此不依赖模型质量 | FR6.1.2、FR6.2.1–FR6.2.4、FR6.3.2、AC6.2.1 |
| A2 | **BOM 文件输入只走 F1 统一解析模型**：xlsx/xls/pdf 一律作为 Document 上传，经 F1 解析管线取 `tables` 结构（PDF 跨页表格合并复用 FR1.2.2，spec 头表依赖 F1.2）；**csv 由 bomdiff 在上传前做无语义的容器转换（csv→xlsx）后走 F1 native 通道**——仅格式包装、不解析内容，从而不违反 specs/README「下游禁止绕过统一解析模型」且无需改 F1（避免 F1 扩 csv 通道的跨模块改动）。PDF 来源的 BOM 要求文档 `PARSE_CONFIRMED`（表格经 OCR/解析风险高，必须人工校对后才能导入）；xlsx/xls（含 csv 转换）native 提取确定性高，解析 status=SUCCESS 即可导入。此宽严差异记为假设（§7） | FR6.1.1、FR1.6.2、AC1.6.1；specs/README 数据契约 |
| A3 | **列映射猜测两级化、猜测结果永不直接生效**：第一级确定性同义词表（料号：`料号/物料编码/Part No/P/N/part_number/物料号…`；数量/名称/层级/版本/替代料/状态/单位各配同义词组，归一化后精确匹配）；第二级对未命中表头走 LLM 语义判定，产出带置信度的建议。两级产物统一进入映射确认页人工调整确认（FR6.1.2「人工调整确认」），自动猜测仅是预填 | FR6.1.2、AC6.1.1；FR10.3.3 |
| A4 | **错误行显式修正闭环、不静默丢弃**：行级校验错误（料号为空/数量非正数值/层级格式非法/替代料超限）落 `bom_import_errors` 表并返回可修正的错误列表，前端逐行修正后重新校验；错误行不进入比对（FR6.1.4）；列映射页对替代料列提供切分结果预览（C-Q2 Assumptions） | FR6.1.4、FR6.1.2；C-Q2 Assumptions |
| A5 | **替代料为无序集合语义**（C-Q2）：`substitutes[]` 按正则 `[,;｜|、，；]` 确定性切分、去空格、去重、上限 20；比对三态：① 料号缺失但出现在对方任一行替代料集合 → `替代料差异`；② 双方料号均在但集合不等（无序集合比较）→ `替代料不一致`；③ 均不满足才判 `B缺失`。两类替代料差异统一按 `SUBSTITUTE` 类型展示，`value_a/value_b` 记录双方替代料集合（C-Q2 Assumptions） | FR6.2.2、FR6.2.3；C-Q2 及 Assumptions |
| A6 | **风险分级纯规则、关键件清单走平台状态机**：`bom_critical_parts` 清单（项目域，料号前缀/名称关键词/规格描述三类匹配规则，≥30 项初版）由我方起草 DRAFT 导入、客户质量/研发负责人 APPROVED 后线上生效；线上遇未定版清单按「数量不一致一律中」兜底不阻塞；清单仅影响新发起的 run（run 记录生效版本快照，已完成 run 不重算）。分级优先级：人工覆盖（Phase 1 预留字段，无独立 API）> 规则（含关键件命中升高）> 默认矩阵 | FR6.3.1；C-Q1 及 Assumptions |
| A7 | **比对结论走 F10.2 状态机、处置与 Issue 关联受锁定约束**：`bom_diff_run` 继承 BaseEntity，state `DRAFT → APPROVED`（定版 = F6.5.4「完成确认」，权限=研发主管，comment 必填，复用 F10 通用 transition）；APPROVED 后明细锁定，处置/撤销/批量处置返回 `BOMDIFF_RUN_LOCKED`。`Issue` 经 platform 统一对象模型创建（`issues` 表，F10.1），`source_type=BOM_DIFF_ITEM` + `source_id` 构成正向链接，`bom_diff_item.issue_id` 为反向链接（AC6.5.1 双向跳转）；带 Issue 关联的 run 不可删除（C-Q3 Assumptions） | FR6.5.1、FR6.5.4、AC6.5.1；spec §5 状态机/对象模型；C-Q3 Assumptions；F10 plan §2.2 |
| A8 | **历史运行全量留存 + 发起人受限删除**（C-Q3）：run 列表分页接口（含状态/总览摘要）；定版 run 永久留存；DRAFT run 仅发起人可删且无 Issue 关联时才允许（软删 + audit `bomdiff.run.deleted`）；diff-of-diff 明确不做（Phase 2） | C-Q3；FR6.5.1、AC6.5.1 |
| A9 | **导出为异步任务 + 工件落 MinIO**：Excel（openpyxl，总览/差异明细/处置记录三 Sheet）、PDF（ReportLab，服务端按 run.state 注入"草稿"水印，FR6.6.2）、Word（python-docx）生成放 Celery `bomdiff` 队列，产物写 MinIO 返回预签名 URL；水印以**定版时点**为准而非导出请求时刻（同 F5 plan A8 手法） | FR6.6.1、FR6.6.2；specs/README 异步约定 |
| A10 | **前端页面11/12按 UI_GUIDE 落地**：页面11 BOM 工作台（BOM 类型页签 + BOM 树 + 物料明细）、导入向导（三步：上传/列映射/校验修正）、页面12 比对结果（总览卡片点击钻取到明细筛选 FR6.4.1；明细表按差异类型/风险/处置状态筛选排序 FR6.4.2；AI 归因列带 [AI] 标识）；处置动作与转整改任务入口在明细行操作列，跳转复用 Issue 列表页 | FR6.4.1、FR6.4.2、FR6.5.1、FR6.3.3、AC6.5.1；UI_GUIDE 页面11/12 |
| A11 | **评测离线脚本独立于线上埋点**（同 F1/F5 plan 手法）：`evals/bom_diff/` 对预置差异集（AC6.2.1）与表头映射金标集离线跑分；线上仅打 `bomdiff.start→confirm` 耗时与处置耗时分布 KPI | AC6.2.1、AC6.1.1；spec §5 KPI |

---

## 2. 数据模型

> 全部主键 UUIDv7、时间戳 UTC（specs/README 约定）。`bom`、`bom_diff_run` 继承 F10 BaseEntity 公共列（FR10.1.3：id/project_id/created_by/created_at/updated_at/state/audit_ref）。

### 2.1 bom 与 bom_row（spec §3）

```text
boms(                                # 一侧 BOM（design/plm 文件导入产物）
  # BaseEntity 公共列：id, project_id, created_by, created_at, updated_at,
  #                    state(默认 DRAFT，Phase 1 不暴露转换端点，见 §7 假设), audit_ref
  side VARCHAR,                      # design | plm                              （spec §3）
  source_file UUID→documents,        # 原件经 F1 上传（A2）
  source_parse_version INT,          # 读取的 F1 解析版本（A2/F1 plan A4）
  source_kind VARCHAR,               # xlsx | xls | csv_converted | pdf_table    （FR6.1.1）
  version_label VARCHAR NULL,        # BOM 版本标签（人工填写，AI 归因上下文，FR6.3.2）
  column_mapping JSONB,              # {目标列→源列名, 目标列→猜测来源: synonym|llm|human}
                                     #                                           （FR6.1.2）
  row_count INT,                     # 通过校验进入比对的行数                     （spec §3）
  template_id→bom_mapping_templates NULL,   # 应用的映射模板（FR6.1.5）
  stats JSONB                        # {total_rows, valid_rows, error_rows, skipped_optional_cols[]}
                                     # 可选列缺失说明（FR6.1.3）
)

bom_rows(
  id UUIDv7 PK, bom_id→boms, row_no INT,
  part_no VARCHAR,                   # 归一化（去空格、区分大小写，C-Q2）        （FR6.2.1 对齐键）
  name VARCHAR NULL, qty NUMERIC, unit VARCHAR NULL,
  level_path VARCHAR NULL,           # 规范化层级路径（如 "1/2.1/2.1.3"），存在时参与对齐
                                     #                                           （FR6.2.1）
  version VARCHAR NULL,              # 字符串精确比对                            （FR6.2.4）
  substitutes JSONB NULL,            # string[]（切分规范化的无序集合，C-Q2）
  status VARCHAR NULL, remark VARCHAR NULL,   # 状态列 / 备注列（AI 归因上下文，FR6.3.2）
  is_critical BOOLEAN DEFAULT false, # 导入时点按生效关键件清单预计算（观测用；比对时以 run 快照复算）
  created_at
)
-- 索引：(bom_id, part_no), (bom_id, level_path, part_no)

bom_import_errors(                   # FR6.1.4 可修正错误列表（A4），修正通过后删除对应行
  id UUIDv7 PK, bom_id→boms, row_no INT,
  error_code VARCHAR,                # PART_NO_EMPTY | QTY_INVALID | LEVEL_INVALID | SUBSTITUTE_OVER_LIMIT
  raw_row JSONB,                     # 原始行快照（供修正表单回填）
  error_detail JSONB, resolved_by→users NULL, resolved_at NULL
)
```

### 2.2 bom_diff_run 与 bom_diff_item（spec §3）

```text
bom_diff_runs(
  # BaseEntity 公共列：id, project_id, created_by, created_at, updated_at,
  #                    state(DRAFT→APPROVED, F10.2/FR6.5.4), audit_ref, revision INT DEFAULT 1
  bom_a_id→boms, bom_b_id→boms,
  critical_parts_version UUID NULL,  # 比对时点生效关键件清单版本快照（审计/C-Q1）
  overview JSONB,                    # {total_parts, matched, diff_count, risk{high,mid,low}}
                                     # 总览卡片（FR6.4.1）
  status,                            # 任务生命周期：QUEUED/RUNNING/SUCCESS/FAILED（对齐任务状态机）
  fail_reason VARCHAR NULL,          # BOM_NOT_READY / ENGINE_ERROR / ATTRIBUTION_FAIL ...
  task_id UUID NULL,                 # 异步任务（SSE）
  deleted_at TIMESTAMPTZ NULL,       # DRAFT 软删（C-Q3/A8）
  stats JSONB NULL                   # {by_type{...六类}, by_disposition{none,confirmed,ignored,issue}}
)
-- state 由 F10 workflow 管理（DRAFT→APPROVED 即「完成确认」）；status 仅描述异步任务执行

bom_diff_items(
  id UUIDv7 PK, run_id→bom_diff_runs,
  part_no VARCHAR, level_path VARCHAR NULL,     # 对齐键原值（FR6.2.1）
  diff_type VARCHAR,                 # QTY_DIFF | VERSION_DIFF | ONLY_A(新增) | ONLY_B(缺失)
                                     # | SUBSTITUTE（FR6.2.2/FR6.2.3，含 C-Q2 统一展示口径）
                                     # | STATUS_DIFF | MATCHED
  risk VARCHAR,                      # HIGH | MID | LOW                          （FR6.3.1）
  risk_reason VARCHAR NULL,          # 命中规则说明（如"关键件清单命中：电芯类"）（FR6.3.1 可配置佐证）
  value_a JSONB, value_b JSONB,      # 两侧值对照 {qty,unit} / {version} / {substitutes[]} /
                                     # {status} / null（缺失侧）（FR6.3.3、C-Q2 Assumptions）
  ai_note TEXT NULL,                 # AI 归因一句建议（[AI] 标注，仅建议性质）   （FR6.3.2）
  ai_note_meta JSONB NULL,           # {prompt_id, prompt_version, model, model_version}（spec §5 审计）
  disposition VARCHAR DEFAULT 'none',# none | confirmed | ignored | issue         （FR6.5.1）
  issue_id UUID NULL,                # → issues（platform 统一对象模型，AC6.5.1）
  disposed_by→users NULL, disposed_at, note VARCHAR NULL,    # 处置记录           （FR6.5.3）
  disposal_history JSONB DEFAULT '[]',  # [{action, by, at, note, revoked_by?, revoked_at?}]
                                     # 撤销亦留痕（FR6.5.3）
  created_at
)
-- 索引：(run_id, diff_type), (run_id, risk), (run_id, disposition), (issue_id)
-- 一致的料号落 MATCHED 行（FR6.2.2「双方一致的料号计入一致」），供总览钻取与明细导出完整对账
```

### 2.3 映射模板与关键件清单

```text
bom_mapping_templates(               # FR6.1.5 列映射模板复用
  id UUIDv7 PK, project_id NULL,     # NULL=部署域全局共享；项目级优先命中
  name VARCHAR UNIQUE,               # 按模板名应用
  column_mapping JSONB,              # 同 boms.column_mapping 结构
  created_by, created_at, updated_at
)

bom_critical_parts(                  # C-Q1 关键件/安全件清单（项目域，规则矩阵的配置输入）
  id UUIDv7 PK, project_id, version INT,
  rules JSONB,                       # [{match: {part_prefix|name_keyword|spec_keyword}, category}]
                                     # 初版 ≥30 项（电芯/BMS/继电器/保险丝/高压连接器/防爆阀…）
  state,                             # DRAFT | APPROVED（复用 F10 workflow；仅 APPROVED 线上生效）
  approved_by→users NULL, approved_at, created_by, created_at, remark
)
-- 变更走 CRUD + audit bomdiff.criticalpart.updated（C-Q1）；run 记录生效版本（§2.1）
-- 兜底：线上无 APPROVED 版本 → 数量不一致一律 MID，不阻塞比对（C-Q1 Assumptions，A6）
```

---

## 3. API 设计（遵循 specs/README：REST /api/v1、统一错误体、异步任务 SSE）

### 3.1 端点清单

```text
# 导入（F6.1，两步向导）
POST /api/v1/boms/import/step1       # multipart 上传（xlsx/xls/csv/pdf）→ {bom_id, document_id,
                                     #  task_id?, sheet_candidates[]}；csv 服务端转 xlsx（A2）；
                                     #  pdf 需文档 PARSE_CONFIRMED（A2）
GET  /api/v1/boms/{id}/preview       # 表头 + 前 N 行预览（读 F1 解析模型表格，FR6.1.2）
GET  /api/v1/boms/{id}/mapping-suggestions
                                     # 两级猜测结果：[{source_col, target_col?, source: synonym|llm,
                                     #  confidence?, reason?}]（FR6.1.2，A3）
POST /api/v1/boms/{id}/mapping       # body: {column_mapping, version_label?, save_template?}
                                     # 人工确认映射 → 触发行级校验 → 返回错误列表（FR6.1.3/6.1.4）
PUT  /api/v1/boms/{id}/rows/errors   # body: {corrections: [{error_id, raw_row}]} 修正后重新校验
                                     # （FR6.1.4 循环）；全部通过 → bom READY
GET  /api/v1/boms                    # 项目内 BOM 列表（页面11：设计BOM/PLM BOM 页签）
GET  /api/v1/boms/{id}               # BOM 树 + 物料明细（页面11）
GET  /api/v1/boms/mapping-templates  # ?name= 模板查询（FR6.1.5）
DELETE /api/v1/boms/{id}             # 未被 run 引用的 BOM 可删（引用检查）

# 比对运行（F6.2–F6.4）
POST /api/v1/bom-diff/runs           # body: {bom_a_id, bom_b_id}；校验同项目 + 两侧 READY
                                     # → 201 {run_id, task_id}（异步，Celery bomdiff 队列）
GET  /api/v1/bom-diff/runs           # ?project_id=&page=&page_size= 分页历史（C-Q3，含状态/总览摘要）
GET  /api/v1/bom-diff/runs/{id}      # 总览 + overview + stats（FR6.4.1）
GET  /api/v1/bom-diff/runs/{id}/items
                                     # ?diff_type=&risk=&disposition=&page=&page_size=
                                     # 明细筛选与排序（FR6.4.2、FR6.3.3 行结构）
DELETE /api/v1/bom-diff/runs/{id}    # 仅发起人 + DRAFT + 无 Issue 关联（C-Q3 Assumptions，A8）
                                     # 软删 → audit bomdiff.run.deleted
GET  /api/v1/bom-diff/runs/{id}/items/{item_id}/issue
                                     # 正向跳转 Issue 详情（AC6.5.1）；反向：issues 详情带 source 链接

# 处置（F6.5）
POST /api/v1/bom-diff/items/{id}/dispose
                                     # body: {action: confirm|ignore|to_issue,
                                     #  issue: {title, assignee_id, due_date}?, note?}
                                     # to_issue 经 platform Issue 对象创建（FR6.5.1，同步操作）
POST /api/v1/bom-diff/runs/{id}/items/batch-dispose
                                     # body: {filters|item_ids, action, note?} 按筛选批量（FR6.5.2）
                                     # 逐条记录处置人；响应逐条返回成功/失败（部分成功语义）
POST /api/v1/bom-diff/items/{id}/dispose/revoke
                                     # 撤销处置 → disposition 回 none，history 留痕
                                     # （FR6.5.3，audit bomdiff.item.disposal.revoked）
POST /api/v1/bom-diff/runs/{id}/confirm
                                     # 完成确认（F10.2 transition DRAFT→APPROVED，comment 必填；
                                     # 前置校验：无 disposition=none 的差异行）→ 明细锁定（FR6.5.4）

# 导出（F6.6）
POST /api/v1/bom-diff/runs/{id}/export   # body: {format: pdf|excel|word} → task_id（异步，A9）
GET  /api/v1/bom-diff/runs/{id}/exports       # 导出历史（format/file_url/state）

# 关键件清单（C-Q1）
GET/POST/PUT /api/v1/bom-diff/critical-parts     # CRUD（版本化，项目域）；变更 → audit
                                                 # bomdiff.criticalpart.updated
POST /api/v1/bom-diff/critical-parts/{id}/transition  # DRAFT→APPROVED（质量/研发负责人，F10 workflow）

# 辅助
GET  /api/v1/tasks/{id}/events       # SSE：QUEUED/RUNNING(stage=align|check|grading|attribution|export,
                                     #  progress 0–100)/SUCCESS/FAILED/CANCELED（specs/README 异步约定）
```

### 3.2 语义与错误

- 统一错误体 `{"code","message","detail"}`。本 feature 新增错误码：
  - `BOMDIFF_FILE_UNSUPPORTED`（FR6.1.1 类型白名单外）
  - `BOMDIFF_PDF_NOT_CONFIRMED`（A2：PDF 来源文档未 PARSE_CONFIRMED，提示先完成校对确认）
  - `BOMDIFF_REQUIRED_COLUMN_MISSING`（FR6.1.3：料号/数量列未映射）
  - `BOMDIFF_ROW_ERRORS_PENDING`（FR6.1.4：存在未修正错误行，BOM 不 READY）
  - `BOMDIFF_BOM_NOT_READY`（发起比对时侧 BOM 未完成导入校验）
  - `BOMDIFF_RUN_LOCKED`（APPROVED 后处置/撤销被拒，FR6.5.4「定版后明细锁定」）
  - `BOMDIFF_RUN_HAS_ISSUES`（存在 Issue 关联的 run 不可删除，C-Q3 Assumptions）
  - `BOMDIFF_CONFIRM_INCOMPLETE`（完成确认时仍有未处置差异行，FR6.5.4）
  - `BOMDIFF_ATTRIBUTION_UNAVAILABLE`（AI 归因失败不阻塞比对结果，行照常可读可处置）
- **异步边界**：发起比对、导出两操作走 Celery `bomdiff` 队列返回 `task_id`、进度经 SSE；step1 上传触发的 F1 解析复用 F1 自身异步任务；列映射确认、行修正、处置、撤销、删除为同步操作；定版走 F10 通用 transition（同步）。发起时校验失败为同步 4xx，不入队。
- **幂等与并发**：批量处置对已处置行返回逐条冲突结果（不整体失败）；处置与定版并发时以 transition 行锁为准，后到者收 `BOMDIFF_RUN_LOCKED`。
- **权限**（F10.5 矩阵）：导入/发起/处置 = 工程师+；定版（完成确认）与关键件清单 APPROVED = 研发主管（质量负责人同权，C-Q1）；run 可见性随项目继承；删除 = 发起人。F4 bom_diff 技能经 `POST /bom-diff/runs` 同一入口发起（被依赖关系，spec 头表）。
- **处置人记录**：批量处置时逐条记录同一操作人与时间戳（FR6.5.2「逐条记录处置人」），不支持代他人处置。

---

## 4. AI/LLM 使用点

| 项 | 设计 | 溯源 |
| ---- | ---- | ---- |
| LLM 使用范围 | **两处**：① 表头列映射语义猜测兜底层（FR6.1.2，确定性同义词未命中的表头）；② 差异 AI 归因建议（FR6.3.2）。替代料切分（C-Q2 明确不调用 LLM）、对齐、六类差异判定、单位换算、规则分级、导出渲染全部为确定性代码；关键件清单命中判定为确定性规则（C-Q1 Assumptions） | FR6.1.2、FR6.3.2；C-Q1/Q2 |
| 模型策略 | 经 F10 `LLMGateway`：生成模型走配置（私有化可替换、数据不出企业域）；审计记录运行时实测 model/model_version。无 embedding 需求（表头候选少，无需向量召回） | F10 plan §4 挂点 2；FR10.3.1 |
| Prompt 策略 | Prompt 注册表管理，两个 prompt_id：`f6.header_mapping`（输入：全部表头 + 每列前 3 个样本值 + 目标列定义清单；输出：逐表头→目标列判定+置信度+理由；无匹配目标列时输出 none，禁止硬凑）；`f6.diff_attribution`（输入：**仅** run 元数据——两侧文件名/version_label/导入时间/备注列摘录 + 差异行结构化数据；系统指令明确"只允许基于输入数据推断，禁止引用外部知识/标准，输出一句中文建议，语气为‘请确认’性质"）。禁止裸字符串 prompt | FR6.1.2、FR6.3.2；FR10.3.4 |
| 结构化输出 schema | 均强制 JSON Schema（Pydantic 校验，失败重试 1 次后降级：映射猜测→该列标记未映射由人工选择、归因→ai_note 置 NULL + `BOMDIFF_ATTRIBUTION_UNAVAILABLE` warning，均不阻塞主流程）：① `{"mappings":[{"source_col","target_col","confidence","reason"}]}`；② `{"attributions":[{"item_id","note"}]}`（note ≤120 字） | FR6.1.2、FR6.3.2；F10 plan §4 挂点 3 |
| Grounding/防幻觉 | 归因后置**确定性校验**（代码非 prompt）：归因文本中出现的料号必须存在于该 run 的差异行集合、出现的数值/版本串必须与对应行 value_a/value_b 匹配（归一后比对），校验失败丢弃该条 ai_note 并记 warning——"归因仅基于两侧 BOM 元数据"由代码保证而非 prompt 约定（同 F1 plan A6 手法）；归因 UI 恒带 [AI] 标识且仅建议性质（FR6.3.2/FR6.3.3） | FR6.3.2、FR6.3.3 |
| 审计接入 | 每次比对 emit `bomdiff.run`（记录模型、prompt 版本、critical_parts_version、两侧 bom id 与 source_file）；`bomdiff.item.disposed / item.disposal.revoked / run.confirmed / run.deleted / criticalpart.updated / template.saved` 均入审计（`<domain>.<verb>`，spec §5 + C-Q1/Q3）；ai_note_meta 随差异行持久化 prompt 版本 | spec §5 审计；FR10.3.1、FR10.3.3；C-Q1/Q3 |
| 评测方式 | ① **AC6.2.1 引擎金标**（M3 硬门槛）：构造预置差异集——六类差异每类 ≥5 条 + 替代料嵌套场景（X 缺失但出现在对方替代料集合、双方集合不等、替代料含分隔符边界）+ 含层级路径对齐用例，`evals/bom_diff/` 离线跑核对引擎断言与预置答案 **100% 一致**，任何引擎/规则变更触发回归；② 表头映射金标集（≥50 个真实/扰动表头，同义词命中 + LLM 判定分层统计）：综合 top1 准确率 ≥90% 为观测指标（AC6.1.1 由 2 分钟走查验收，准确率指标用于监控猜测质量）；③ AI 归因小样本评测（≥30 条差异，双人标注"归因是否合理"）：合理率为观测指标，不设硬门槛（仅建议性质）；④ 线上 `bomdiff.start→confirm` 耗时 KPI 对照人工基线验收 ↓70% | AC6.2.1、AC6.1.1；C-Q2；spec §5 KPI；PRD §50 |

---

## 5. 测试策略

| 层级 | 内容 | 溯源 |
| ---- | ---- | ---- |
| 单元（导入） | 替代料切分矩阵（5 种分隔符、多分隔符混用、去重/去空格、超 20 报错、含分隔符料号进错误列表不静默丢弃）；表头同义词匹配（常规名/非常规名 AC6.1.1 场景、大小写/空白归一）；行级校验（料号空/数量 0/负数/非数值/层级格式非法）；必选列缺失拦截；csv→xlsx 容器转换幂等 | FR6.1.2–FR6.1.4、AC6.1.1；C-Q2 及 Assumptions；A2 |
| 单元（引擎） | 对齐键（无层级=料号；有层级=层级路径+料号，同名料号不同层级为不同对象）；六类差异穷举 + MATCHED 计入；替代料三态判定（A5）优先级（替代料差异先于 B缺失）；无序集合比较；数量单位换算（可换算归一比较 / 不可换算字符串比对并标注）；规则矩阵（版本→高、数量→中、新增/缺失→中、替代料→中、状态→低；关键件命中数量升高；清单未定版兜底全中） | FR6.2.1–FR6.2.4、FR6.3.1；C-Q1/Q2；A5/A6 |
| 单元（归因 grounding） | 构造含外部料号/数值的归因文本断言被剔除并 warning；合法归因（仅引用输入元数据）通过 | FR6.3.2 |
| 集成（导入向导） | 上传 xlsx → F1 解析 → 猜测建议返回（synonym 层命中标记 source）→ 人工调整映射 → 错误列表返回 → 修正循环 → READY 且 row_count 正确；PDF 未确认文档返回 `BOMDIFF_PDF_NOT_CONFIRMED`；缺失可选列时 stats.skipped_optional_cols 说明（FR6.1.3）；保存模板 → 新导入一键应用（FR6.1.5） | FR6.1.1–FR6.1.5 |
| 集成（比对管线） | fixtures：预置差异集 BOM 对端到端跑 SUCCESS；断言 items 六类齐备、MATCHED 计入 overview、risk 分布正确、SSE 事件序列 QUEUED→RUNNING(各 stage)→SUCCESS；未 READY 的 BOM 发起返回 `BOMDIFF_BOM_NOT_READY` 且无 run 记录 | FR6.2.1–FR6.2.4、FR6.4.1；specs/README 异步 |
| 集成（处置与定版） | 逐条 confirm/ignore；to_issue 创建 Issue（标题/描述含差异快照/责任人/截止日期）且 item.issue_id 回填、Issue 详情含 source 反向链接（AC6.5.1 双向跳转）；批量处置逐条记录处置人 + 部分成功语义；撤销回 none 且 history 留痕 + 审计；未处置完 confirm 返回 `BOMDIFF_CONFIRM_INCOMPLETE`；研发主管定版成功（comment 必填）后处置/撤销返回 `BOMDIFF_RUN_LOCKED`；run.confirmed 审计含 who/when | FR6.5.1–FR6.5.4、AC6.5.1；spec §5 状态机 |
| 集成（清单与版本快照） | 清单 DRAFT 时发起 run：数量差异=中 + run.critical_parts_version 记录该 DRAFT 版本；APPROVED 后**新发起** run 数量差异升高、已完成 run 不重算（快照语义，C-Q1 Assumptions）；清单变更入审计 | C-Q1；FR6.3.1 |
| 集成（历史与删除） | runs 分页列表含状态/总览摘要（C-Q3）；发起人删除 DRAFT 无 Issue 的 run 成功（软删+审计）；带 Issue 的 run 删除返回 `BOMDIFF_RUN_HAS_ISSUES`；非发起人删除 403 | C-Q3；A8 |
| 集成（导出） | Excel 三 Sheet 内容与行/处置数据一致；PDF DRAFT 态含水印、APPROVED 后无水印（FR6.6.2）；Word 含总览/明细/处置/运行信息；导出走异步任务且产物可下载（FR6.6.1） | FR6.6.1、FR6.6.2 |
| **禁绕过测试**（AC1.6.1 复用） | import-linter 禁止 bomdiff 模块直读 MinIO 原件/自建 xlsx-PDF 解析（csv 容器转换白名单例外，仅允许无语义字节级包装）；集成测试以仅消费 F1 解析模型的桩文档验证导入与比对可完成 | FR1.6.2、AC1.6.1；A2 |
| 权限矩阵 | 参数化：5 角色 × {导入/发起/处置/批量处置/定版/清单定版/删除}；run 项目可见性断言；F4 bom_diff 技能复用同一发起入口断言 | FR10.5 矩阵；spec §5 |
| API 契约 | 统一错误体/分页信封 `{items,total,page}`/SSE payload schema；新错误码语义逐条断言；批量处置部分成功响应结构 | specs/README、§3.2 |
| 评测 | `evals/bom_diff/` 引擎金标 100%（M3 硬门槛）、表头映射 top1 ≥90%（观测）、归因合理率（观测）；报告版本化归档 | AC6.2.1、AC6.1.1；§4 评测 |
| 前端 | 组件测试：映射确认页预填与调整、错误行修正表格、总览卡片点击钻取带筛选（FR6.4.1）、明细筛选排序、处置操作与批量、[AI] 标识（归因列）、水印提示、Issue 双向跳转、BOM 树渲染 | FR6.1.2、FR6.4.1–FR6.4.2、FR6.5.1、FR6.3.3、AC6.5.1；UI_GUIDE 页面11/12 |

覆盖率目标遵循全局规则（新增模块 ≥80%）。

---

## 6. 风险与非目标

### 风险

| 风险 | 影响 | 缓解 |
| ---- | ---- | ---- |
| 表头猜测不准导致 AC6.1.1（2 分钟完成映射）不达标 | 易用性验收失败 | 两级猜测（同义词层覆盖常规名、LLM 层覆盖非常规名，A3）；映射模板复用减少重复操作（FR6.1.5）；映射页单屏预览+下拉调整的最小交互；准确率观测指标（≥90%）驱动词表迭代 |
| 替代料真实数据格式超出 C-Q2 约定（括号备注、含分隔符料号、替代组语义） | 误判差异类型/丢行 | 切分结果在映射页预览人工确认（C-Q2 Assumptions）；无法解析按 FR6.1.4 进错误列表修正，不静默丢弃；替代组语义 Phase 2 处理（C-Q2，与 spec §6 非目标一致） |
| 层级路径写法不统一（`1.2.3` vs `1/2/3` vs 缩进列）导致对齐失败 | 大量伪"新增/缺失" | 层级路径规范化器（分隔符折叠、深度数字提取）入 engine/align；无法规范化的行按 FR6.1.4 进错误列表；退化路径：层级列整体不可用时回落纯料号对齐并在运行信息说明（FR6.1.3 语义） |
| 关键件清单长期停留 DRAFT（客户评审延迟） | 数量差异全部"中"，高风险漏报体验下降 | C-Q1 兜底不阻塞执行；测试环境整库启用（C-Q1 Assumptions）；M3 Exit 前置检查项推动评审（同 F5 处理方式） |
| 数量单位换算覆盖不足（件/pcs/m/kg 之外的自定义单位） | 可换算差异被当字符串比对误判一致/不一致 | Phase 1 内置小而确定的换算表（pcs/件/个 同义、长度/重量常见单位）；不可换算时字符串精确比对且差异行标注"单位不可换算"提示人工判断，不静默判定 |
| AI 归因幻觉（引用外部标准/编造原因） | 违反 FR6.3.2"仅建议性质"的可信度 | 输入限定为 run 元数据 + 差异行（prompt 层）+ 确定性 grounding 校验剔除（代码层，§4）+ [AI] 标识 + 失败降级置 NULL |
| KPI 基线缺失（人工 BOM 核对耗时未测） | ↓70% 无法验收 | F10.6 人工基线联合测量为 M1 交付项（F10 plan 风险表）；`bomdiff.start→confirm` 打点全程覆盖；处置耗时分布同表观测（spec §5） |
| run/明细与 Issue 双向链接的悬挂风险（删 BOM/删 run） | AC6.5.1 链接断裂 | 带 Issue 关联的 run 不可删（C-Q3 Assumptions）；BOM 被 run 引用时不可删（§3.1 DELETE /boms/{id} 引用检查）；外键约束兜底 |

### 非目标（Phase 1）

- 与 PLM/ERP 系统直连或回写提交（第二阶段，spec §6、PHASE1_SPEC §4；UI_GUIDE 页面12 的「提交PLM」按钮 Phase 1 仅置灰提示）
- 替代组（alternate group）语义、MBOM/多楼层 BOM 变形比对、单价成本比对（spec §6；C-Q2）
- 同一 BOM 对的 diff-of-diff（两次运行结果对比，C-Q3 明确列入 Phase 2）
- AI 直写任何终态、处置动作自动化（处置必须人工逐条/批量触发；specs/README AI 草稿语义）
- 关键件清单的物料分类主数据（分类编码体系）对接（C-Q1 Assumptions：料号级规则匹配已够 Phase 1）
- BOM 编辑/回写（bom_row 为导入快照，不可编辑；修正仅发生在导入校验阶段，FR6.1.4 语义）

---

## 7. 决策与假设记录（承接 clarifications）

- C-Q1：关键件/安全件清单由我方起草初版（≥30 项料号规则：前缀/名称关键词/规格描述三类匹配），项目域 `bom_critical_parts` 表存储，DRAFT 导入、客户质量/研发负责人 APPROVED 后线上生效；未定版时数量不一致一律"中"兜底不阻塞；清单仅影响新发起 run（run 记录版本快照，已完成 run 不重算）；变更走 CRUD + `bomdiff.criticalpart.updated` 审计。→ §2.3、§3.1、A6、§4、§5、§6
- C-Q2：替代料为扁平列表确定性切分（正则 `[,;｜|、，；]`、去空格/去重/上限 20、料号区分大小写），解析不调用 LLM；替代料差异与替代料不一致统一按 `SUBSTITUTE` 类型展示、风险默认"中"；替代组不做。→ A5、§2.1、§4、§5、§6
- C-Q3：历史运行全量留存（不做 diff-of-diff）；分页历史列表；定版 run 永久留存；DRAFT run 仅发起人可删且无 Issue 关联（软删+审计）；带 Issue 的 run 一律不可删。→ §2.2、§3.1、A7、A8、§5、§6
- 假设：① **PDF 来源 BOM 需 PARSE_CONFIRMED、xlsx/xls/csv 仅需解析 SUCCESS**（A2——PDF 表格经 OCR/解析风险高必须人工校对；native 表格提取确定性高，若评审认为需统一收紧为全部 PARSE_CONFIRMED，仅改 step1 校验一处）；② csv 通过无语义容器转换（csv→xlsx 字节包装）走 F1，不新增 F1 csv 通道（A2）；③ `bom` 注册进 F10 OBJECT_REGISTRY 但 Phase 1 不暴露状态转换端点（导入校验通过即 READY，BOM 输入件本身无需审批；如需「导入确认」审批可在 M3 复审时以 transition 配置追加，不改表结构）；④ 人工风险等级覆盖 Phase 1 预留 `risk_reason`/history 字段、不设独立 API（spec 未要求，FR6.3.1 仅规则矩阵可配置）；⑤ 数量单位换算表初版仅含同义件数单位与常见度量单位，其余字符串比对并标注（§6 风险表）；⑥ F4 bom_diff 技能复用 `POST /bom-diff/runs` 入口，无独立 API（spec 头表被依赖关系，同 F5 处理方式）；⑦ `bom_diff_run.status`（任务生命周期）与 F10 `state`（DRAFT→APPROVED）分离（同 F1 plan A8、F5 plan A7 手法）；⑧ UI_GUIDE 页面11 的「料号匹配」页签与「ERP BOM」入口 Phase 1 不做（spec §6 非目标：无系统直连，ERP 侧 BOM 以文件导入即 `side=plm` 泛化承载，字段 `side` 枚举预留 `erp`）。
