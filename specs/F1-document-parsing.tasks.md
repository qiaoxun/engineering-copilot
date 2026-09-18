# F1 文档解析引擎 — 任务清单（Tasks）

| | |
| ---- | ---- |
| Feature | F1-document-parsing |
| 输入 | specs/F1-document-parsing.md、specs/F1-document-parsing.clarifications.md（C-Q1–Q4）、specs/F1-document-parsing.plan.md（冲突时以后两者为准）、specs/README.md |
| 关联 | specs/F10-platform-governance.tasks.md（T01 常量契约 / T06 审计通道 / T07 LLMGateway / T09 require_perm 为本表前置） |
| 阶段 | speckit-tasks |
| 粒度约定 | 每条任务 0.5–2 人日；超过 2 人日须继续拆分 |
| 里程碑对齐 | T01–T13 → M1；T14 → M1 Exit 验收（金标字段准确率 ≥90% 为硬门槛，AC1.4.1） |

> 依赖列格式：依赖的任务号。编号即执行顺序（尽量并行：T06/T07/T08 三通道相互独立，可并行开发）。
> 前置说明：本表 T01 的四类常量接入 F10 T01 产出的常量表体系；审计写入（F10 T06）、LLMGateway（F10 T07）、require_perm（F10 T09）按 F10 任务表交付，F1 侧仅做挂接与消费，不重复建设。

---

## 任务清单

### T01 F1 接入点：审计事件定义、状态机接线、权限点、KPI 埋点

- **目标**：一次性落地 F1 挂接 F10 的四个接入点——① 审计事件常量：`parse.completed / parse.failed / parse.corrected`（FR10.3.3、spec §5）+ `param_dict.updated`（C-Q4），payload schema 含 parser_versions、低置信度统计、override old/new；② 状态机接线：parse_result 解析生命周期 `PENDING/RUNNING/SUCCESS/FAILED/PARSE_CONFIRMED`（独立于 F10 对象 state，plan A8）+ param_dict `DRAFT→APPROVED`（定版权限=研发主管，C-Q4）注册入 F10 状态机配置；③ 权限点：`documents.view / documents.write / documents.reparse / params.dictionary.manage / params.dictionary.approve` 及项目级可见性挂接（`require_perm` + 项目成员关系，plan A8）；④ KPI：`parse.duration`（提交→SUCCESS，FR10.6.2）埋点 schema 与 emit 时机。同时定义本 feature 错误码全集：`FILE_FORMAT_UNSUPPORTED / FILE_SIZE_EXCEEDED / FILE_ENCRYPTED` + 7 个 `PARSE_ERR_*` reason_code（FR1.1.1–FR1.1.3、FR1.6.3）。
- **涉及文件/模块**：`apps/backend/app/modules/documents/governance.py`（接入点常量与注册）、`app/core/errors.py`（错误码扩展）、F10 侧 `platform/audit/events.py`、`workflow/configs.py`、`rbac/permissions.py`、`kpi/events.py` 的 F1 增量
- **完成标准**：事件/权限/转换/KPI 常量与 spec §5 横切接入及 FR1.6.3 错误码逐条对应，单元测试断言清单完备；`PARSE_ERR_*` 穷举测试与 reason_code 表同源（AC1.6.2 的数据基础）；param_dict 状态机配置含 required_perm（C-Q4）
- **依赖**：F10 T01（常量表体系）、F10 T09（require_perm；可桩对接先行）
- **粒度**：1 天

### T02 数据模型 + 迁移 + param_dict 种子

- **目标**：建 `documents`（BaseEntity 继承、file_ext 保留原始扩展名 C-Q2、storage_key→MinIO、current_parse_result_id）、`document_projects`（N—N）、`parse_results`（version 递增、result JSONB+GIN、status/reason_code CHECK 约束、parser_versions、task_id）、`parse_overrides`、`param_dict`（synonyms/unit_candidates/si_unit/state DRAFT|APPROVED/version）、`golden_sets`（版本化 golden_set_v1，C-Q1）表及 Alembic 迁移；种子 ≥30 类电池工程参数字典（DRAFT 态导入，C-Q4）。
- **涉及文件/模块**：`app/modules/documents/model/entities.py`、`app/modules/documents/params/models.py`、`alembic/versions/*`、`app/modules/documents/params/seeds.py`（含 ≥30 参数 YAML/JSON 数据文件）
- **完成标准**：迁移可上下执行；CHECK 约束（FAILED⇔reason_code、SUCCESS⇔result 非空）生效测试；重解析 version 递增唯一性测试（FR1.6.4）；种子字典条目 ≥30 且含 FR1.4.1 列举的全部参数类别
- **依赖**：T01；F10 T03（BaseEntity/OBJECT_REGISTRY）
- **粒度**：1.5 天

### T03 统一解析输出模型（F1.6）+ JSON Schema 导出

- **目标**：Pydantic 定义统一模型全集（parse_schema_version="1.0"：document/sections/blocks/tables/fields/warnings，含 page/bbox/confidence/low_confidence/source_block_id/merged_from_pages 等全部字段，FR1.6.1）；JSON Schema 导出物作为契约基线（plan §6 schema 演进风险缓解）；LLM 结构化输出 schema 与 `fields[]` 定义同源（plan §4）。
- **涉及文件/模块**：`app/modules/documents/model/schema.py`、`app/modules/documents/model/export.py`（schema JSON 导出脚本）、`specs/contracts/f1_parse_schema_v1.json`（导出产物）
- **完成标准**：导出的 JSON Schema 与 FR1.6.1 示例结构逐字段一致；schema 快照契约测试（改动即失败，防破坏下游）；`fields[]` 与 LLM 输出 schema 同源引用测试（FR1.4.2）
- **依赖**：T01
- **粒度**：0.5 天

### T04 上传与格式校验（F1.1）

- **目标**：`POST /api/v1/documents` multipart 批量上传：逐文件独立校验（扩展名白名单 FR1.1.1、100MB 上限 FR1.1.2、加密检测——PDF `needs_pass` 试解密 + OOXML/OLE CFB 加密封装识别，plan A9）；通过即建 Document(PENDING) + MinIO 流式上传 + 入 parse 队列（FR1.1.5）；失败逐文件返回统一错误体数组，不产生任何业务记录（FR1.1.4）；含宏文件拒收（C-Q2）。`GET /api/v1/documents` 列表（分页信封、含 status/reason_code，AC1.6.2）与 `GET /{id}` 元信息。
- **涉及文件/模块**：`app/modules/documents/upload/`（`validators.py`、`encryption.py`、`api.py`）、`app/modules/documents/api/`（列表/详情路由）
- **完成标准**：加密 PDF 被拒且 message="文件已加密，请提供解密后版本"、无 Document 记录（AC1.1.1）；批量 3 文件含 1 坏文件 → 2 成 1 拒互不影响（AC1.1.2）；校验矩阵单测（FR1.1.1–FR1.1.4）全覆盖
- **依赖**：T02
- **粒度**：1.5 天

### T05 解析管线编排：Celery parse 队列 + reason_code 终态 + SSE 进度

- **目标**：管线骨架：上传→入队→router 通道决策（pdf 文本层字符密度判定 native_text|ocr、图片→ocr、office 直读、doc/xls 先转换，plan §1.2）→ 各通道 Processor 接口 → 统一模型组装 → parse_result 落库 → `parse.completed/failed` 审计 + `parse.duration` KPI；A5 失败必落终态：异常全捕获映射 7 个 reason_code（`soft_time_limit`→PARSE_ERR_TIMEOUT、未映射→UNKNOWN+堆栈摘要入 error_detail）；SSE `GET /api/v1/tasks/{id}/events` 推 QUEUED/RUNNING(页级 page_done/page_total/stage)/SUCCESS/FAILED。
- **涉及文件/模块**：`app/worker/`（Celery app、parse 队列、OCR 并发上限 4 配置 C-Q3）、`app/modules/documents/pipeline/`（`orchestrator.py`、`router.py`、`errors.py` reason_code 映射表）、`app/modules/documents/api/tasks.py`（SSE）
- **完成标准**：每种 reason_code 构造一个必现场景（含未映射异常→UNKNOWN），断言终态落库 + 审计 parse.failed + 列表可见原因码 + 任务不残留 RUNNING（FR1.6.3、AC1.6.2）；SSE 事件序列与 payload schema 契约测试（specs/README 异步约定）
- **依赖**：T02、T03、T04；F10 T06（审计通道）
- **粒度**：2 天

### T06 PDF 通道：版面/表格还原 + 跨页表格合并（F1.2）

- **目标**：PyMuPDF 文本层版面分析：章节树/段落块/表格（表头行识别），全元素携带 page/bbox/confidence（FR1.2.1）；跨页表格合并规则（续页列结构一致且无重复表头 → 合并，标记 `merged_from_pages[]`，行序保持，FR1.2.2）；双栏阅读顺序还原；表格识别双库比对择优、置信度 <0.85 标 `low_confidence` 并强制进校对队列不静默输出（FR1.2.4，plan §6 风险缓解）；大文件按页迭代不整件载入（plan §6）。
- **涉及文件/模块**：`app/modules/documents/pipeline/pdf/`（`layout.py`、`tables.py`、`merge.py`、`reading_order.py`）
- **完成标准**：单元测试覆盖合并规则矩阵（列结构一致/不一致、重复表头、行序保持）与双栏顺序还原（FR1.2.2）；含跨页参数表的样本 fixture 端到端断言 `merged_from_pages` 正确（AC1.2.1 样本级预演，金标终验在 T13）；低置信度表格必出 warning 且进校对队列（FR1.2.4）
- **依赖**：T03、T05
- **粒度**：2 天

### T07 Office 通道 + .doc/.xls 转换（F1.2.3，C-Q2）

- **目标**：docx（python-docx）/xlsx（openpyxl）结构化读取：原生层级（标题/段落/表格）直映射统一模型，不经 OCR/版面模型（FR1.2.3）；`.doc/.xls` LibreOffice headless 转换为 docx/xlsx 后走同一通道，`Document.file_type`/`file_ext` 保留原始扩展名（C-Q2、plan 假设）；转换失败→PARSE_ERR_CORRUPT、超时→PARSE_ERR_TIMEOUT；转换前后页数/文本量 sanity 校验，异常记 warning 进校对队列（plan §6）。
- **涉及文件/模块**：`app/modules/documents/pipeline/office/`（`docx_reader.py`、`xlsx_reader.py`）、`app/modules/documents/pipeline/convert/`（`libreoffice.py`，含进程超时与清理）
- **完成标准**：doc/xls fixture 转换→结构化读取端到端断言层级与表格保真（FR1.2.3、C-Q2）；损坏 doc→PARSE_ERR_CORRUPT、挂起转换→PARSE_ERR_TIMEOUT 测试；`file_type` 记录原始扩展名断言（Assumptions C-Q2）
- **依赖**：T03、T05
- **粒度**：1.5 天

### T08 OCR 通道（F1.3，C-Q3）

- **目标**：`OcrBackend` 抽象接口 + PaddleOCR CPU 默认实现（PP-Structure 版面+表格），环境变量可切 GPU 后端代码同构（C-Q3）；扫描件判定（T05 router 的密度阈值）后的块级识别：中英混排（FR1.3.3）、块级置信度、`confidence < 0.85` 标 `low_confidence=true`（FR1.3.2）；OCR 结果与坐标一并写入统一模型 blocks（可定位原文，FR1.3.3）；页级并行 + 队列并发 4。
- **涉及文件/模块**：`app/modules/documents/pipeline/ocr/`（`backend.py` 抽象、`paddle_cpu.py`、`confidence.py`）
- **完成标准**：扫描 PDF/图片 fixture 端到端：块级坐标与置信度写入模型、低置信度标记阈值正确（FR1.3.1–FR1.3.3）；`OcrBackend` 可替换性测试（fake backend 注入）；≤100 页扫描件 SLO 观测埋点就位（P95 ≤10min 为 SLO 非硬门槛，C-Q3 Assumptions）
- **依赖**：T03、T05
- **粒度**：2 天

### T09 参数抽取（F1.4）：规则优先 + LLM 兜底 + grounding + 单位归一

- **目标**：表格键值匹配规则层（param_dict key/synonyms/value_pattern，FR1.4.3 优先）；段落语义兜底经 LLMGateway（prompt_id=f1.param_extract 注册表引用，禁裸字符串，FR10.3.4）：仅送候选 blocks、强制 JSON Schema 输出、逐字段 source_block_id；grounding 校验：回查 block 原文、归一后匹配失败即丢弃 + `warning(GROUNDING_FAIL)`，confidence 由服务重算不信任 LLM 自报（plan A6，代码保证"仅原文存在才输出"）；Pint 单位归一（mAh→A·h、℃/K、扭矩/公差），`value_raw` 永远保留（FR1.4.4）；仅 APPROVED 字典参与线上抽取生效判断（C-Q4）。
- **涉及文件/模块**：`app/modules/documents/pipeline/extract/`（`rules.py`、`llm_fallback.py`、`grounding.py`、`units.py`）、prompt 注册表种子（f1.param_extract v1）
- **完成标准**：grounding 单测：伪造 LLM 输出原文不存在的值必被丢弃且出 warning（FR1.4.2/FR1.4.3）；单位归一表穷举测试（FR1.4.4）；DRAFT 字典不生效/APPROVED 生效测试（C-Q4）；fields[] 输出全部可通过 source_block_id 定位原文（FR1.4.2）
- **依赖**：T06、T07、T08（任一通道产出 blocks 即可先行，终验需全通道）；F10 T07（LLMGateway）
- **粒度**：2 天

### T10 param_dict 字典管理 API + DRAFT→APPROVED 定版

- **目标**：`GET/POST/PUT/DELETE /api/v1/params/dictionary` CRUD + `POST /api/v1/params/dictionary/{id}/transition`（DRAFT→APPROVED，权限=params.dictionary.approve 即研发主管，C-Q4）；变更 emit `param_dict.updated` 审计（`<domain>.<verb>` 命名）；version 递增；全部端点挂 require_perm。
- **涉及文件/模块**：`app/modules/documents/params/api.py`、`service.py`、路由注册
- **完成标准**：CRUD 契约测试（统一错误体/分页信封/UUIDv7）；研发主管定版成功/工程师 403（F10.5 矩阵、C-Q4）；每次变更审计事件字段完整（FR1.4.1、FR10.3.3）
- **依赖**：T01、T02
- **粒度**：1 天

### T11 解析结果读取 / 重解析 / 原文定位 + 下游契约（AC1.6.1 禁绕过）

- **目标**：`GET .../parse`（默认 override 合并视图，`?raw=true` 取原始——双留存读取，plan A3）；`POST .../reparse`（新 parse_result 版本递增，旧行永不覆盖，返回 task_id，FR1.6.4）；`GET .../parse/blocks/{block_id}/source`（页码+bbox+原件预签名 URL，FR1.2.1/FR1.3.3）；重解析挂 `documents.reparse` 权限；下游契约保障：import-linter 架构测试禁止 documents 模块外直接读 MinIO 原件/自建 PDF 解析（FR1.6.2）。
- **涉及文件/模块**：`app/modules/documents/api/parse.py`、`service.py`（override 合并）、`pyproject.toml`（import-linter 规则）、`apps/backend/tests/architecture/test_no_bypass.py`
- **完成标准**：reparse 产生 version+1 且旧版本经 raw 可读（FR1.6.4）；合并视图与 raw 视图差异可断言（FR1.5.2/FR1.5.4 的读取前提）；架构测试断言越界 import 即失败（AC1.6.1 静态侧）
- **依赖**：T02、T03、T05
- **粒度**：1.5 天

### T12 人工校对闭环（F1.5）：override 双留存 + confirm + 前端校对视图

- **目标**：后端：`GET/POST .../parse/overrides`（值/单位/归属章节/表格单元格四类目标，FR1.5.2）、`POST .../parse/confirm`（→PARSE_CONFIRMED，仅人工入口，AI 管线禁调，plan §3.2）；override 落库 raw 不动（双留存，plan A3）、emit `parse.corrected` 审计（who/when/old/new，FR1.5.3）；以合同式测试桩模拟 F2 ingestion 仅消费 `GET .../parse`，断言修正值出现在下游读视图（AC1.5.1）。前端：`pages/documents`（列表含失败原因码 AC1.6.2）、`pages/documents/parse` 校对视图（左原文对照/右结构化结果、低置信度红色高亮、修正表单、confirm 流程）、`features/parse-viewer`（blocks/tables/fields 渲染 + 原文定位 bbox 高亮跳转，FR1.5.1）。
- **涉及文件/模块**：`app/modules/documents/proofread/`（`api.py`、`service.py`）、`tests/integration/test_proofread_loop.py`（含 F2 桩）、`apps/frontend/src/pages/documents/**`、`src/features/parse-viewer/*`
- **完成标准**：修正→override 落库→raw 不变→confirm→审计 parse.corrected 全链路集成测试（FR1.5.1–FR1.5.4）；F2 桩读视图命中修正值（AC1.5.1）；前端组件测试：低置信度标红、修正表单、失败原因码展示、bbox 跳转（FR1.5.1、AC1.6.2）
- **依赖**：T09（fields 可校对）、T11（读取/合并视图）；F10 T09（权限）
- **粒度**：2 天

### T13 金标评测脚本 + golden_set_v1 跑分（AC1.2.1 / AC1.2.2 / AC1.4.1）

- **目标**：`evals/golden_set/` 离线评测脚本（独立于线上埋点，plan A10）：读取 golden_sets 表版本化金标（C-Q1：≥35 份、扫描件≥5、图片≥3、≥3 类模板；先行以我方自建 ≥30 份内部版跑分，客户方金标就绪后复测，C-Q1 Assumptions）；全管线跑分输出：字段准确率（值+单位均匹配计正确，目标 ≥90%，AC1.4.1）、跨页表格合并正确率（AC1.2.1）、双栏顺序还原率（AC1.2.2）；分模板/分通道（native/OCR）分项报表；报告版本化归档，作为管线/字典/模型变更的回归门槛（plan §4）。
- **涉及文件/模块**：`evals/golden_set/`（`runner.py`、`metrics.py`、`report.py`）、金标标注规范与模板（交付物脚本形态，C-Q1）、内部金标 fixtures
- **完成标准**：内部金标集全量跑分报告产出且三项指标可度量；字段准确率 ≥90%（M1 Exit 硬门槛，以内部金标先验收、golden_set_v1 复测为正式验收，C-Q1 Assumptions）；扫描件超时率观测项输出（>5% 触发 GPU 评估，C-Q3）
- **依赖**：T06、T07、T08、T09、T02（golden_sets 表）
- **粒度**：2 天

### T14 端到端验收（覆盖 F1 全部 AC）

- **目标**：演示环境全链路验收：上传加密 PDF/坏文件/正常混合批量 → 逐文件结果与错误提示（AC1.1.1/AC1.1.2）→ 全类型样本（PDF/扫描件/doc/xls/docx/xlsx/图片）解析 → SSE 进度 → 失败文档列表可见原因码（AC1.6.2）→ 跨页参数表合并与行序保持（AC1.2.1）→ 双栏还原率可度量（AC1.2.2）→ 字典 DRAFT 不生效→研发主管 APPROVED→抽取命中（C-Q4）→ 校对修正→confirm→F2 桩读视图命中修正值（AC1.5.1）→ F5/F6 桩仅消费 `GET .../parse` 完成最小功能（AC1.6.1）→ 重解析版本链（FR1.6.4）→ 审计（parse.completed/failed/corrected、param_dict.updated）与 parse.duration KPI 可查 → T13 金标报告 ≥90%。产出验收核对单逐项勾稽。
- **涉及文件/模块**：`apps/backend/tests/e2e/test_f1_acceptance.py`、验收核对单（`specs/F1-document-parsing.acceptance.md` 或本文件附录）
- **完成标准**：以下 AC 全部通过——AC1.1.1、AC1.1.2、AC1.2.1、AC1.2.2、AC1.4.1（金标 ≥90%）、AC1.5.1、AC1.6.1、AC1.6.2；FR1.1.1–FR1.6.4 逐条映射到用例的追溯表无缺口；新增模块行覆盖率 ≥80%（全局规则）；≤100 页扫描件 P95 ≤10min SLO 观测达标或记录超时率并触发 GPU 评估决议（C-Q3）
- **依赖**：T10、T11、T12、T13
- **粒度**：1 天

---

## 任务依赖图

```text
F10 T01/T06/T07/T09（平台前置，见关联行）
        │
T01 ─┬→ T02 ─┬→ T04 ──→ T05 ─┬→ T06 ─┐
     │       │               ├→ T07 ─┼→ T09 ─┐
     │       │               └→ T08 ─┘       ├→ T12 ─┐
     │       ├→ T10 ────────────────────────┤        │
     ├→ T03 ─┴→ T11 ────────────────────────┴→ T13 ─┼→ T14
     └──────────────────────────────────────────────┘
```

并行建议：T06 / T07 / T08 三通道互不依赖可并行（仅共享 T03 模型与 T05 Processor 接口）；T10 与 T04–T09 可并行；T11 与 T06–T09 可并行。

---

## Breakdown 决策与假设（Clarifications / Assumptions）

- **[D1] F10 前置而非内嵌**：任务要求首任务为 F10 接入点。决策：T01 只做 F1 侧的四接入点常量/注册/挂接与错误码全集，审计存储（F10 T06）、LLMGateway（F10 T07）、require_perm（F10 T09）按 F10 任务表交付，F1 侧以接口桩先行并行开发（与 F10 T04 同策略）。理由：避免跨 feature 重复建设，保持 `<domain>.<verb>` 事件与权限点全集单一定义源。
- **[D2] 解析状态机不占用 F10 对象 state**：parse_result 的 PENDING→…→PARSE_CONFIRMED 是解析生命周期字段（plan A8），不经 F10 通用 transition API；仅 param_dict 的 DRAFT→APPROVED 走 F10 状态机（C-Q4）。T01/T10 按此接线。
- **[D3] 金标集先行策略**：C-Q1 正式金标（≥35 份，客户方标注）存在外部依赖。决策：T13 以我方自建内部金标（≥30 份，含扫描件 5 份）先跑分支撑 M1 内部验收，golden_set_v1 就绪后复测作为正式验收（clarifications Assumptions 原文）；金标标注工具按 C-Q1 以脚本+规范形态交付，不入平台范围。
- **[D4] 下游契约测试桩**：AC1.6.1 要求 F2/F5/F6 集成证明，但三者分属 M2/M3。决策：T11（架构禁令静态测试）+ T12/T14（仅消费 `GET .../parse` 的合同式测试桩模拟 F2 入库与 F5 字段 Diff 最小流程）承担证明；F2/F5/F6 落地时以真实模块回归该契约。
- **[D5] 转换器部署依赖**：T07 LibreOffice headless 为部署层依赖（容器镜像内安装），任务范围内仅含调用、超时与失败映射；镜像变更记入部署清单，不新增失败码（C-Q2 Assumptions）。
- **[D6] 任务粒度校验**：拆解结果 14 条 ≤ 15 条上限，plan 粒度合格（plan §1–§5 模块划分与任务一一对应），无需回改 plan。
