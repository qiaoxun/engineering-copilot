# F1 文档解析引擎 — 技术方案（Plan）

| | |
| ---- | ---- |
| Feature | F1-document-parsing |
| 输入 | specs/F1-document-parsing.md、specs/F1-document-parsing.clarifications.md（冲突时以其为准）、PHASE1_SPEC.md、PHASE1_FEATURES.md、specs/README.md |
| 关联 | specs/F10-platform-governance.plan.md（对象模型/状态机/审计/RBAC/KPI 接入契约） |
| 阶段 | speckit-plan（仅设计，不写代码） |
| 里程碑 | M1 |

> 本 plan 中所有设计决策均标注溯源（FR/AC/Q 编号）。clarifications（Q1–Q4 决策）全文有效，本文引用处标注为「C-Qx」。

---

## 1. 架构与模块落点

### 1.1 总体架构

对齐既定技术栈：**后端 FastAPI 模块化单体 + Celery + PostgreSQL(pgvector) + MinIO；前端 React + TypeScript + Ant Design**。F1 是全平台唯一文档数据入口（FR1.6.2），落在独立顶层模块 `documents/`，解析管线以**管道式 Processor 链**实现，按文件类型与文本层特征路由（FR1.2.3、FR1.3.1）。

```text
apps/backend/
├── app/
│   ├── core/                        # F10 平台地基（config/db/errors/uuidv7/security）
│   ├── modules/
│   │   ├── documents/               # ← F1 本体
│   │   │   ├── api/                 # 上传/reparse/parse 读取/进度路由
│   │   │   ├── upload/              # F1.1 校验：扩展名、大小、加密检测、Document 创建
│   │   │   ├── pipeline/            # Celery 编排：路由 → 解析 → 归一 → 抽取 → 持久化
│   │   │   │   ├── router.py        # 通道决策：native_text / ocr / office / convert
│   │   │   │   ├── pdf/             # PyMuPDF 文本层 + 版面/表格还原（F1.2）
│   │   │   │   ├── office/          # docx/xlsx 结构化读取（FR1.2.3）
│   │   │   │   ├── convert/         # .doc/.xls → LibreOffice headless 转换（C-Q2）
│   │   │   │   ├── ocr/             # OCR 后端抽象 + PaddleOCR CPU 实现（F1.3，C-Q3）
│   │   │   │   ├── tables/          # 跨页表格合并（FR1.2.2）
│   │   │   │   └── extract/         # F1.4：字典规则抽取 + LLM 兜底 + 单位归一
│   │   │   ├── model/               # F1.6 统一解析输出模型（Pydantic + JSON Schema 导出）
│   │   │   ├── proofread/           # F1.5 校对：override 读写、双留存、PARSE_CONFIRMED
│   │   │   └── params/              # param_dict CRUD + DRAFT/APPROVED 生效判定（C-Q4）
│   │   └── platform/                # F10：objects/workflow/audit/rbac/kpi/prompts（见 F10 plan）
│   ├── worker/                      # Celery app；parse 队列（OCR 并发上限 4，C-Q3）
│   └── main.py
└── alembic/
apps/frontend/
└── src/
    ├── pages/documents/             # 文档列表（含失败原因码，AC1.6.2）
    ├── pages/documents/parse/       # F1.5 校对视图：左原文对照 / 右结构化结果，低置信度标红
    └── features/parse-viewer/       # 解析模型渲染器（blocks/tables/fields，原文定位跳转）
```

### 1.2 解析管线（核心流程）

```text
上传 → 校验(F1.1) → Document(PENDING) + MinIO 原件 → Celery parse 队列
  → router：doc/xls 先 convert(C-Q2)；pdf 测文本层字符密度 → native_text | ocr(FR1.3.1)；图片→ocr
  → 版面/结构还原：pdf=PyMuPDF+表格识别 / office=python-docx|openpyxl / ocr=PaddleOCR PP-Structure
  → 跨页表格合并(FR1.2.2) → 统一模型组装(F1.6, parse_schema_version=1.0)
  → 参数抽取(F1.4)：表格键值规则优先 → LLM 结构化兜底(带 grounding 校验) → 单位归一(Pint)
  → parse_result(SUCCESS/FAILED+reason_code) → audit parse.completed/failed → SSE 页级进度
```

### 1.3 关键架构决策

| # | 决策 | 溯源 |
| ---- | ---- | ---- |
| A1 | **双通道 PDF 解析**：有文本层走 PyMuPDF 版面分析（快、坐标精确），文本层字符密度低于阈值判定扫描件转 OCR 通道；同一套统一模型归一层，通道差异不外泄。OCR 后端抽象为 `OcrBackend` 接口，默认 PaddleOCR CPU，环境变量可切 GPU 后端，代码同构 | FR1.3.1、FR1.2.1；C-Q3 |
| A2 | **Word/Excel 不经 OCR/版面模型**（FR1.2.3）：docx 用 python-docx、xlsx 用 openpyxl 直接读原生层级/表格；`.doc/.xls` 由服务端内嵌 LibreOffice headless 无损转换为 docx/xlsx 后走同一通道，`Document.file_type` 保留原始扩展名，转换失败 `PARSE_ERR_CORRUPT`、超时 `PARSE_ERR_TIMEOUT`；含宏文件上传即拒 `FILE_FORMAT_UNSUPPORTED` | FR1.2.3、FR1.1.1；C-Q2 |
| A3 | **解析结果 JSONB 单表存储 + 读取时合并 override**：`parse_result.result` 存完整统一模型（符合 spec 数据模型），override 存关系表并在 `GET .../parse` 输出时叠加为"修正后视图"，同时提供 `raw=true` 取原始结果——**双留存**由存储结构直接保证，不做字段级复制 | FR1.6.1、FR1.5.2、FR1.5.4 |
| A4 | **重解析 = 新 parse_result 行**（version 递增），旧行与 override 永不覆盖/删除；Document 指向"当前版本"。下游一律经 `GET .../parse` 读当前版本（含 override），与 F2 ingestion 解耦 | FR1.6.4、FR1.5.4；C-Q1（golden_set 版本化同理） |
| A5 | **失败必落终态**：Celery 任务任何异常都被管线捕获映射为 7 个 reason_code 之一（超时由 Celery soft_time_limit 显式转 `PARSE_ERR_TIMEOUT`），禁止任务静默消失；未映射异常归 `PARSE_ERR_UNKNOWN` 并附堆栈摘要入 `error_detail` | FR1.6.3、AC1.6.2、FR1.1.3 |
| A6 | **LLM 仅用于 F1.4 段落语义兜底抽取**，且强制 grounding：LLM 输出的每个字段必须携带 `source_block_id`，抽取服务回查该 block 原文，`value_raw` 无法在原文中匹配到（数值+单位归一后比对）即丢弃并记 `warning(GROUNDING_FAIL)`——"仅当原文存在该值时才允许输出"由代码保证而非 prompt 约定 | FR1.4.3、FR1.4.2 |
| A7 | **上传校验前置且逐文件隔离**：批量上传每个文件独立校验、独立返回结果（成功建 Document，失败回错误体），单文件失败不产生任何业务记录也不影响批次 | FR1.1.1–FR1.1.4、AC1.1.2 |
| A8 | **文档可见性继承 F10**：documents 继承 BaseEntity（project_id/created_by/state/audit_ref），权限经 `require_perm("documents.view")` + 项目成员关系判定；parse 状态（PENDING/RUNNING/SUCCESS/FAILED/PARSE_CONFIRMED）是解析生命周期字段，挂在 parse_result 上，**不占用** F10 通用 state（F10 state 留给 M2 文档定版） | spec §5 权限；FR10.1.3、FR10.2.1 |
| A9 | **加密检测在同步校验阶段完成**：PDF 试解密（PyMuPDF `needs_pass`）、Office OOXML 加密封装检测（OLE CFB 结构识别），均在上传请求内同步执行，加密文件**不创建 Document、不入队** | FR1.1.3、AC1.1.1 |
| A10 | **金标评测脚本独立于线上埋点**：`evals/golden_set/` 离线脚本读取 golden_set_v1（C-Q1，版本化于 `golden_sets` 表），输出字段准确率/表格合并正确率/双栏顺序还原率报告；线上仅打 `parse.duration` KPI | spec §5 KPI；AC1.4.1；C-Q1 |

---

## 2. 数据模型

> 全部主键 UUIDv7、时间戳 UTC（specs/README 约定）。documents 及关联对象遵循 F10 BaseEntity 统一接口字段（FR10.1.3：id/project_id/created_by/created_at/updated_at/state/audit_ref）。

### 2.1 documents（F10 对象模型中的 Document，FR10.1.1/FR10.1.2）

```text
documents(
  # BaseEntity 公共列：id, project_id, created_by, created_at, updated_at, state, audit_ref
  filename, file_ext,                 # 原始扩展名（doc/xls 不因转换改写，C-Q2）
  file_type,                          # pdf|word|excel|image（归一类）
  size_bytes, storage_key→MinIO,      # 原件对象键
  page_count INT NULL,                # 解析后回填
  current_parse_result_id→parse_results NULL,
  document_projects(document_id, project_id)   # N—N（FR10.1.2）
)
```

### 2.2 parse_results（spec §3）

```text
parse_results(
  id UUIDv7 PK, doc_id→documents, version INT,          # 重解析递增（FR1.6.4）
  schema_version VARCHAR DEFAULT '1.0',                 # parse_schema_version（FR1.6.1）
  result JSONB,                       # 完整统一解析模型（F1.6 结构），GIN 索引 (jsonb_path_ops)
  status,                             # PENDING/RUNNING/SUCCESS/FAILED/PARSE_CONFIRMED
  reason_code VARCHAR NULL,           # PARSE_ERR_FORMAT/ENCRYPTED/SIZE/CORRUPT/TIMEOUT/OCR_FAIL/UNKNOWN
  error_detail TEXT NULL,             # 人类可读描述 + 堆栈摘要（FR1.6.3）
  parser_versions JSONB,              # {pdf_lib, ocr, extractor, ...} 运行时实测版本
  task_id UUID NULL,                  # 关联异步任务（SSE）
  started_at, finished_at
)
-- CHECK: status='FAILED' ⇔ reason_code 非空；status='SUCCESS' ⇔ result 非空
```

### 2.3 parse_overrides（spec §3，F1.5）

```text
parse_overrides(
  id UUIDv7 PK, parse_result_id→parse_results,
  target_type,                        # field|table_cell|block_section|ocr_block
  target_block_id VARCHAR NULL, field_key VARCHAR NULL, cell_ref JSONB NULL,
  old_value JSONB, new_value JSONB,   # 双留存：raw 结果不动，修正叠加于读视图（A3）
  reason VARCHAR NULL,                # 修正说明（可选，审计 detail 引用）
  edited_by→users, edited_at
)
-- 保存 override 即 emit audit parse.corrected（FR1.5.3；FR10.3.3 事件清单）
```

### 2.4 param_dict（spec §3 + C-Q4）

```text
param_dict(
  id UUIDv7 PK, key VARCHAR UNIQUE,   # rated_capacity / nominal_voltage / internal_resistance ...
  display_name, synonyms TEXT[], unit_candidates TEXT[],
  si_unit VARCHAR,                    # 归一目标单位（mAh→A·h 等，FR1.4.4）
  value_pattern TEXT NULL,            # 键值匹配正则/别名规则（FR1.4.3 规则层）
  safety_level VARCHAR,               # 安全相关参数标记（扭矩/密封等）
  state,                              # DRAFT/APPROVED（C-Q4：仅 APPROVED 参与线上抽取生效判断）
  approved_by→users NULL, approved_at, version INT
)
-- F10 状态机配置：param_dict  DRAFT→APPROVED（定版权限=研发主管，C-Q4）
-- 字典变更 emit audit param_dict.updated（C-Q4；<domain>.<verb> 命名）
golden_sets(id, name, doc_snapshot JSONB, expected_fields JSONB, annotations JSONB,
            version VARCHAR,          # golden_set_v1（C-Q1）
            confirmed_by, confirmed_at)      # 双人标注+仲裁+书面确认后版本化
```

> 说明：`param_dict` 初版 ≥30 类电池工程参数以种子数据导入为 DRAFT，研发主管逐项 APPROVED 后生效（测试环境可整库启用，C-Q4 Assumptions）。

---

## 3. API 设计（遵循 specs/README：REST /api/v1、统一错误体、异步任务 SSE）

### 3.1 端点清单

```text
POST /api/v1/documents                     # multipart 批量上传（多 file 字段）；逐文件校验
                                           # 成功→Document(PENDING)+task_id；失败→逐文件错误体数组（AC1.1.2）
GET  /api/v1/documents                     # 列表：分页 {items,total,page}；含 status/reason_code（AC1.6.2）
GET  /api/v1/documents/{id}                # 文档元信息
POST /api/v1/documents/{id}/reparse        # 触发重解析：新 parse_result 版本 → task_id（FR1.6.4）
GET  /api/v1/documents/{id}/parse          # 当前解析模型：默认 override 合并视图（FR1.5.4）
                                           # ?raw=true 取原始结果（双留存读取，FR1.5.2）
GET  /api/v1/documents/{id}/parse/blocks/{block_id}/source
                                           # 原文定位：返回页码+bbox+原件预签名 URL（FR1.2.1/FR1.3.3、F3.4 复用）
GET  /api/v1/documents/{id}/parse/overrides        # 修正历史
POST /api/v1/documents/{id}/parse/overrides    # 人工修正（F1.5.2）→ parse.corrected 审计
POST /api/v1/documents/{id}/parse/confirm      # 校对完成 → PARSE_CONFIRMED（FR1.5.3）
GET/POST/PUT/DELETE /api/v1/params/dictionary  # 参数字典 CRUD（FR1.4.1、C-Q4；变更写审计）
POST /api/v1/params/dictionary/{id}/transition # DRAFT→APPROVED 定版（研发主管，C-Q4）
GET  /api/v1/tasks/{id}/events             # SSE：QUEUED/RUNNING(页级进度 0–100%)/SUCCESS/FAILED/CANCELED
```

### 3.2 语义与错误

- 统一错误体 `{"code","message","detail"}`。本 feature 新增错误码：
  - 上传校验：`FILE_FORMAT_UNSUPPORTED`（FR1.1.1）、`FILE_SIZE_EXCEEDED`（FR1.1.2）、`FILE_ENCRYPTED`（FR1.1.3，message="文件已加密，请提供解密后版本"，AC1.1.1）。
  - 解析终态 reason_code：`PARSE_ERR_FORMAT / PARSE_ERR_ENCRYPTED / PARSE_ERR_SIZE / PARSE_ERR_CORRUPT / PARSE_ERR_TIMEOUT / PARSE_ERR_OCR_FAIL / PARSE_ERR_UNKNOWN`（FR1.6.3）。
- 上传/校验为同步接口（毫秒级），不走 task；**解析走 Celery `parse` 队列，返回 `task_id`，进度经 SSE 推送，页级粗粒度**（spec §5 异步、specs/README 异步约定）。批量上传返回多个 task_id（每文件一个任务，故障隔离，AC1.1.2）。
- SSE `RUNNING` 事件 payload：`{"page_done": n, "page_total": m, "stage": "layout|ocr|extract"}`。
- 解析结果可见性随文档（项目/部门继承，F10.5）；`documents.write` 校对权限为"工程师+"。
- `PARSE_CONFIRMED` 之后仍允许新增 override（工程实际：定稿后仍可补正），但每次修正都写审计；这与 F10 AI 生成物 DRAFT→APPROVED 语义不同——解析结果是"机器产物+人工校对"，其确认入口 `parse/confirm` 仅人工可调，AI 管线代码不调用该端点（对齐 F10 plan A2 的架构禁令精神）。

---

## 4. AI/LLM 使用点

| 项 | 设计 | 溯源 |
| ---- | ---- | ---- |
| LLM 使用范围 | **仅 F1.4 段落语义兜底抽取**。表格键值匹配（规则/字典）优先且覆盖大多数参数表；仅当字典规则在段落文本中命中参数上下文但未抽得结构化值时，调用 LLM。无 LLM 参与版面分析、OCR、表格合并（全部确定性算法） | FR1.4.3 |
| 模型策略 | 经 F10 `LLMGateway` 调用，模型/版本走配置（私有化可替换，数据不出企业域，PRD §53）；审计记录运行时实测 `model/model_version` | F10 plan §4；FR10.3.1 |
| Prompt 策略 | Prompt 注册表管理：`prompt_id=f1.param_extract, version` 显式引用，禁止裸字符串（FR10.3.4）。Prompt 结构：① 参数字典当前 APPROVED 子集（key+同义词+单位候选）注入上下文；② 仅送入候选段落 blocks（带 block_id）；③ 要求逐字段给出 source_block_id；④ 系统指令明确"原文不存在的值禁止输出" | FR1.4.1、FR1.4.3；FR10.3.4 |
| 结构化输出 schema | LLM 输出强制 JSON Schema（Pydantic 校验，失败重试 1 次后降级为放弃该字段+warning）：`{"fields": [{"key","value_raw","value_norm","unit","unit_si","source_block_id","confidence"}], "schema_version":"1.0"}`；schema 与统一模型 `fields[]` 定义同源（FR1.6.1），不另造第二套字段结构 | FR1.4.2、FR1.6.1 |
| Grounding 校验 | LLM 每个候选字段：回查 source_block 原文 → 数值与单位归一后字符串/数值匹配 → 匹配失败丢弃并记 `warning(GROUNDING_FAIL)`；`confidence` 字段由抽取服务按匹配质量重算，不信任 LLM 自报值 | FR1.4.2（可定位原文）、FR1.4.3（仅原文存在才输出） |
| 单位归一 | Pint 库 + `param_dict.si_unit` 映射（mAh→A·h、℃ 保留/K 归一、N·m 等）；归一失败记 warning 不阻断；`value_raw` 永远保留原始表达 | FR1.4.4 |
| 审计接入 | 每次 LLM 调用经 LLMGateway 强制 emit 审计：prompt_id/version、model、citations（源 blocks）、输出、grounding 结果；`parse.completed/failed/corrected` 事件含 parser_versions 与低置信度统计 | FR10.3.1、FR10.3.3、spec §5 审计 |
| 评测方式 | ① 离线金标评测：`evals/` 脚本对 golden_set_v1（≥35 份，扫描件≥5、图片≥3，≥3 类模板，双人标注+仲裁，C-Q1）跑全管线，输出：字段准确率（值+单位均匹配计正确，AC1.4.1 目标 ≥90%）、跨页表格合并正确率（AC1.2.1）、双栏顺序还原率（AC1.2.2，可度量即可）；② 每次管线/字典/模型变更跑回归，报告版本化归档；③ 线上仅 `parse.duration` KPI 打点（FR10.6.2），评测独立于埋点（A10） | AC1.2.1、AC1.2.2、AC1.4.1；C-Q1；spec §5 KPI |

---

## 5. 测试策略

| 层级 | 内容 | 溯源 |
| ---- | ---- | ---- |
| 单元 | 扩展名/大小校验矩阵；PDF 加密与 Office 加密封装检测；文本层字符密度扫描件判定阈值；跨页表格合并规则（列结构一致、无重复表头、行序保持）；置信度阈值 0.85 标记；Pint 单位归一表（mAh→A·h、℃/K、扭矩、公差）；reason_code 映射表穷举 | FR1.1.1–1.1.3、FR1.2.2、FR1.3.1–1.3.2、FR1.4.4、FR1.6.3 |
| 集成（后端管线） | 样本 fixtures（小型 PDF/扫描 PDF/docx/xlsx/doc/xls/图片/加密 PDF/损坏文件）逐类跑全管线断言统一模型结构符合 F1.6 JSON Schema；批量上传 3 文件含 1 坏文件→2 成 1 拒互不影响（AC1.1.2）；加密文件拒绝且无 Document 记录（FR1.1.4、AC1.1.1）；doc→docx 转换通道（C-Q2）；解析超时→PARSE_ERR_TIMEOUT 终态（C-Q3）；重解析产生 version+1 且旧版本可读（FR1.6.4） | FR1.6.1、AC1.1.1、AC1.1.2、FR1.6.3、FR1.6.4；C-Q2/C-Q3 |
| 集成（校对闭环） | 修正字段值→override 落库、raw 不变→`?raw=true` 与默认视图差异可断言→confirm 后状态 PARSE_CONFIRMED→审计 parse.corrected 含 who/when/old/new；模拟 F2 ingestion 读取：修正值出现在下游读视图（AC1.5.1，以合同式测试桩代替真实 F2） | FR1.5.1–FR1.5.4、AC1.5.1 |
| 集成（下游契约，AC1.6.1） | **禁绕过测试**：静态架构测试（import-linter 禁止 documents 模块外直接读 MinIO 原件/自建 PDF 解析）+ 集成测试以仅消费 `GET .../parse` 的桩实现 F5 字段 Diff 与 F2 入库最小流程 | FR1.6.2、AC1.6.1 |
| 失败路径 | 每种 reason_code 构造一个必现场景（含未映射异常→UNKNOWN），断言列表页可见 reason_code + 人类可读 message、审计 parse.failed 落库、任务不残留 RUNNING | FR1.6.3、AC1.6.2、FR1.1.3 |
| 金标评测 | golden_set_v1 全量跑分脚本：字段准确率 ≥90% 作为 M1 Exit 硬门槛；分模板/分通道（native/OCR）准确率分项报表；扫描件超时率 <5% 观测（C-Q3 触发 GPU 评估的阈值） | AC1.2.1、AC1.2.2、AC1.4.1；C-Q1、C-Q3 |
| API 契约 | 统一错误体/分页信封/SSE 事件序列契约测试；上传响应逐文件 success/error 数组结构；SSE 页级进度事件 payload schema | specs/README、spec §5 异步 |
| 字典与权限 | param_dict DRAFT 不参与线上抽取、APPROVED 生效（C-Q4）；研发主管定版成功/工程师 403（F10.5 矩阵）；param_dict.updated 审计 | FR1.4.1、FR1.4.3；C-Q4 |
| 前端 | 校对视图组件测试：低置信度红色高亮、左右对照布局、修正表单（值/单位/章节/单元格）、confirm 流程；文档列表失败原因码展示；原文定位跳转（bbox 高亮） | FR1.5.1–FR1.5.3、AC1.6.2 |

覆盖率目标遵循全局规则（新增模块 ≥80%）。测试环境字典整库启用（C-Q4 Assumptions）。

---

## 6. 风险与非目标

### 风险

| 风险 | 影响 | 缓解 |
| ---- | ---- | ---- |
| 复杂工程文档表格还原质量（合并单元格、无线表格、多级表头）不达 AC1.2.1 | 下游 F5/F6 比对输入失真 | 表格识别双库比对（PyMuPDF 原生 + 结构化启发式）择优；置信度 <0.85 强制进校对队列（FR1.2.4），不静默输出；金标集分模板观测、按模板调参 |
| CPU OCR 吞吐不足（C-Q3 不配 GPU） | ≤100 页 P95 ≤10min SLO 失守 | 页级并行 + 队列并发上限 4；超时率 >5% 触发 M1 验收前 GPU 节点评估（部署配置变更，代码同构零改造） |
| LLM 兜底抽取幻觉 | 虚假字段污染下游 | A6 强制 grounding + 置信度重算 + GROUNDING_FAIL 告警；金标评测覆盖 LLM 兜底路径 |
| .doc/.xls 转换保真损失（复杂公式/嵌入对象） | 老格式文档字段缺失 | 转换前后页数/文本量 sanity 校验，异常记 warning 进校对队列；失败显式 PARSE_ERR_CORRUPT（C-Q2） |
| 金标集依赖客户方标注资源（C-Q1） | M1 Exit 评测延迟 | Assumption：先以我方自建金标集（≥30 份）内部验收，golden_set_v1 就绪后复测作为正式验收（clarifications 已记录） |
| 统一模型 schema 演进破坏下游 | F2–F9 连锁返工 | `parse_schema_version` 严格版本化 + 向后兼容约定（只增不删，同 FR10.1.4）；下游按 schema_version 分支处理；schema JSON 导出物作为契约测试基线 |
| 大文件（100MB 扫描 PDF）内存峰值 | worker OOM | MinIO 流式下载 + 按页迭代解析（PyMuPDF/PaddleOCR 均支持逐页），不整件载入内存 |

### 非目标（Phase 1）

- CAD/3D 格式、手写体识别、公式还原与重排、EPUB（spec §6；PHASE1_SPEC §4）
- 全文检索/向量化入库（F2 ingestion 职责）、kb_version 管理（F2）
- 文档级 DRAFT→APPROVED 定版流（F10 state 留待 F2.1 文档管理接入；F1 仅负责解析生命周期 PARSE_CONFIRMED）
- OCR 版面级训练/模型微调、多语种扩展（仅中英混排，FR1.3.3）
- 在线标注工具（金标标注工具为交付物脚本/表格规范，非平台功能，C-Q1）

---

## 7. 决策与假设记录（承接 clarifications）

- C-Q1：金标集 ≥35 份（扫描件≥5、图片≥3、≥3 类模板、中/中英混排），双人标注+仲裁，版本化 golden_set_v1，作为 AC1.2.1/AC1.2.2/AC1.4.1 唯一评测基准。→ §2.4 golden_sets、§4 评测、§5 金标评测、A10
- C-Q2：`.doc/.xls` 服务端 LibreOffice headless 自动转换，不要求上传方转换；宏文件拒收；转换失败归 CORRUPT/TIMEOUT，不新增失败码。→ A2、§2.1、§3.2
- C-Q3：无 GPU 默认，PaddleOCR CPU、parse 队列 OCR 并发 4；≤100 页 P95 ≤10min 为 SLO 非验收门槛；OcrBackend 抽象预留 GPU 开关；超时率 >5% 触发 GPU 评估。→ A1、§1.2、§3.2、§5、§6
- C-Q4：param_dict 初版由客户方研发主管评审，走 DRAFT→APPROVED，仅 APPROVED 生效于线上抽取；变更走 CRUD + `param_dict.updated` 审计。→ §2.4、§3.1、§5
- 假设：`Document.file_type` 记录原始扩展名（转换产物为中间态，不落业务字段）；F1 解析状态机与 F10 对象 state 相互独立（A8）；金标标注工具以规范+脚本形态交付，不入平台范围。
