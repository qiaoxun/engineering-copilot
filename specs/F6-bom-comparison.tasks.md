# F6 BOM智能比对 — 任务清单（Tasks）

| | |
| ---- | ---- |
| Feature | F6-bom-comparison |
| 输入 | specs/F6-bom-comparison.md、specs/F6-bom-comparison.clarifications.md（C-Q1–Q3）、specs/F6-bom-comparison.plan.md（冲突时以后两者为准）、specs/README.md |
| 关联 | specs/F1-document-parsing.tasks.md（统一解析模型/表格结构为前置）、specs/F10-platform-governance.tasks.md（M1 骨架为前置）、specs/F4-ai-chat.tasks.md（bom_diff 技能复用 `POST /bom-diff/runs` 入口，plan 假设⑥）、specs/F9-test-report.tasks.md（Issue 对象同类机制参照） |
| 阶段 | speckit-tasks |
| 粒度约定 | 每条任务 0.5–2 人日；超过 2 人日须继续拆分 |
| 前置 | F10 M1 骨架（BaseEntity/LLMGateway/prompt_registry/审计通道/require_perm/kpi_events/workflow 通用 transition/OBJECT_REGISTRY/KPI SQL 视图）、F1.6 统一解析模型读服务（`tables` 结构读取、解析版本列表；PDF 跨页表格合并 FR1.2.2 已就绪） |

> 依赖列格式：依赖的任务号。编号即执行顺序（可并行：T06/T07 引擎线与 T03–T05 导入线在 T02 后可并行；T09/T10/T11 在 T08 后可并行；T12/T13 前端可与后端并行）。

---

## 任务清单

### T01 F6 接入点骨架：审计事件定义、状态机接线、权限点、KPI 埋点

- **目标**：一次性定义 F6 挂接 F10 的接入点——① 审计事件常量：`bomdiff.run / item.disposed / item.disposal.revoked / run.confirmed / run.deleted / criticalpart.updated / template.saved`（spec §5 + C-Q1/Q3；`bomdiff.run` 字段契约：两侧 bom id 与 source_file、实测 model/model_version、两个 prompt_id 版本、`critical_parts_version`，即「模型与 prompt 版本可追溯」，plan §4 审计接入）；② 状态机接线：注册 `bom_diff_run`（`DRAFT→APPROVED`，定版=完成确认，权限=研发主管/质量负责人、comment 必填，FR6.5.4）与 `bom_critical_parts`（`DRAFT→APPROVED`，C-Q1）进 F10 workflow 配置；`bom` 注册进 OBJECT_REGISTRY 但 Phase 1 不暴露 transition 端点（plan 假设③）；③ 权限点清单 `bomdiff.import / bomdiff.run.start / bomdiff.item.dispose / bomdiff.run.confirm / bomdiff.criticalpart.manage / bomdiff.run.delete`（plan §3.2：导入/发起/处置=工程师+，定版与清单 APPROVED=研发主管，删除=发起人）；④ KPI 埋点契约：`bomdiff.start` / `bomdiff.confirm`（duration_ms，`start→confirm` 耗时对照人工基线 ↓70%，spec §5 KPI）+ 处置耗时分布打点注册进 F10 KPI SQL 视图（FR10.6.1）。同时登记错误码（`BOMDIFF_FILE_UNSUPPORTED / BOMDIFF_PDF_NOT_CONFIRMED / BOMDIFF_REQUIRED_COLUMN_MISSING / BOMDIFF_ROW_ERRORS_PENDING / BOMDIFF_BOM_NOT_READY / BOMDIFF_RUN_LOCKED / BOMDIFF_RUN_HAS_ISSUES / BOMDIFF_CONFIRM_INCOMPLETE / BOMDIFF_ATTRIBUTION_UNAVAILABLE`，plan §3.2）与 prompt 注册表条目骨架 `f6.header_mapping / f6.diff_attribution`（FR10.3.4，禁裸字符串）。
- **涉及文件/模块**：`apps/backend/app/modules/platform/audit/events.py`（F6 事件段追加）、`app/modules/bomdiff/constants.py`（权限点/错误码）、`app/modules/platform/workflow/configs.py`（bom_diff_run 与 bom_critical_parts 注册）、`app/modules/platform/kpi/views.sql`（KPI 视图段）、`app/modules/platform/prompts/registry.py`（f6.* 条目）、`app/modules/platform/objects/registry.py`（bom 注册）
- **完成标准**：事件/权限/错误码/prompt 常量表与 spec §5、plan §3.2/§4 逐条对应并有单元断言；workflow 注册后 `bom_diff_run` 可经 F10 通用 transition 走 DRAFT→APPROVED（研发主管 + comment 必填断言，FR6.5.4/F10.2）；`bom_critical_parts` 仅 APPROVED 生效语义在常量层可判定（C-Q1）；`bomdiff.start→confirm` 两个 KPI 事件写入 kpi_events 后可被 SQL 视图聚合（耗时查询冒烟）；审计命名全部符合 `<domain>.<verb>`（FR10.3.3）
- **依赖**：无（复用 F10 M1 已有常量骨架）
- **粒度**：0.5 天

### T02 F6 数据模型 + 迁移

- **目标**：新表——`boms`（继承 BaseEntity：state 默认 DRAFT 不暴露转换端点（plan 假设③）、audit_ref；另含 side design|plm（枚举预留 erp，plan 假设⑧）、source_file→documents、source_parse_version、source_kind xlsx|xls|csv_converted|pdf_table、version_label、column_mapping JSONB（含猜测来源 synonym|llm|human）、row_count、template_id、stats JSONB `{total_rows,valid_rows,error_rows,skipped_optional_cols[]}`，plan §2.1）；`bom_rows`（part_no 归一化对齐键、name/qty/unit/level_path 规范化层级路径/version/substitutes JSONB/status/remark、is_critical 预计算，索引 `(bom_id,part_no)`/`(bom_id,level_path,part_no)`）；`bom_import_errors`（row_no、error_code `PART_NO_EMPTY|QTY_INVALID|LEVEL_INVALID|SUBSTITUTE_OVER_LIMIT`、raw_row JSONB、error_detail、resolved_by/at，plan §2.1）；`bom_diff_runs`（继承 BaseEntity：state DRAFT→APPROVED、revision、audit_ref；另含 bom_a_id/bom_b_id、`critical_parts_version` 快照、overview JSONB `{total_parts,matched,diff_count,risk{high,mid,low}}`、status 任务生命周期与 state 分离（plan 假设⑦）、fail_reason、task_id、deleted_at 软删、stats JSONB `{by_type,by_disposition}`，plan §2.2）；`bom_diff_items`（part_no/level_path 对齐键原值、diff_type `QTY_DIFF|VERSION_DIFF|ONLY_A|ONLY_B|SUBSTITUTE|STATUS_DIFF|MATCHED`、risk/risk_reason、value_a/value_b JSONB、ai_note/ai_note_meta `{prompt_id,prompt_version,model,model_version}`、disposition 默认 none、issue_id→issues、disposed_by/at/note、disposal_history JSONB，索引 `(run_id,diff_type)/(run_id,risk)/(run_id,disposition)/(issue_id)`，一致料号落 MATCHED 行）；`bom_mapping_templates`（project_id NULL=全局、name UNIQUE、column_mapping JSONB）；`bom_critical_parts`（project_id、version、rules JSONB `[{match:{part_prefix|name_keyword|spec_keyword},category}]`、state、approved_by/at，plan §2.3）。Alembic 迁移。
- **涉及文件/模块**：`app/modules/bomdiff/models.py`、`alembic/versions/*`
- **完成标准**：迁移可上下执行；`boms`/`bom_diff_runs` BaseEntity 公共列齐备（FR10.1.3）；bom_diff_items 四索引存在性迁移测试；`bom_diff_run.status` 与 `state` 两列语义独立（任务状态 ≠ 定版状态，plan §2.2 注）；disposal_history 默认 `[]`、issue_id 外键指向 platform `issues`；critical_parts rules JSONB 结构可承载三类匹配规则（C-Q1）
- **依赖**：T01
- **粒度**：1.5 天

### T03 导入 step1：上传登记 + F1 解析通道复用 + 预览（FR6.1.1、A2）

- **目标**：`POST /api/v1/boms/import/step1`（multipart，类型白名单 xlsx/xls/csv/pdf，越界 `BOMDIFF_FILE_UNSUPPORTED`）——原件作为 Document 上传入 MinIO + F1 解析管线复用（**禁自解析**，FR1.6.2）；csv 在上传前做无语义容器转换（csv→xlsx 字节包装，白名单例外，A2）；pdf 来源要求文档 `PARSE_CONFIRMED` 否则 `BOMDIFF_PDF_NOT_CONFIRMED`（A2，xlsx/xls/csv 仅需解析 SUCCESS——plan 假设①）；返回 `{bom_id, document_id, task_id?, sheet_candidates[]}`；`GET /api/v1/boms/{id}/preview` 读 F1 统一解析模型 `tables` 结构返回表头 + 前 N 行预览（FR6.1.2 输入）；`DELETE /api/v1/boms/{id}` 引用检查（被 run 引用不可删，plan §6 风险表）。
- **涉及文件/模块**：`app/modules/bomdiff/import/api.py`（step1/preview/delete）、`import/container.py`（csv→xlsx 包装）、`app/modules/documents/`（进程内只读读服务复用）
- **完成标准**：xlsx/xls/csv/pdf 四通道上传 → Document 登记 + F1 解析成功集成测试（csv 经容器转换走 native 通道断言，A2）；非白名单类型返回 `BOMDIFF_FILE_UNSUPPORTED`；未 PARSE_CONFIRMED 的 PDF 返回 `BOMDIFF_PDF_NOT_CONFIRMED`、已确认的 PDF 表格预览可读（复用 FR1.2.2 跨页合并）；preview 返回表头+样本行结构契约测试；**禁绕过测试：import-linter 断言 bomdiff 模块不直读 MinIO 原件、不自建 xlsx/PDF 解析（csv 容器转换为例外白名单）**（AC1.6.1 复用）；被 run 引用的 BOM 删除被拒
- **依赖**：T02
- **粒度**：1 天

### T04 两级列映射猜测 + 人工确认 + 映射模板（FR6.1.2、FR6.1.3、FR6.1.5、A3、C-Q2）

- **目标**：`header_guess.py` 两级猜测——第一级确定性同义词表（料号/数量/名称/层级/版本/替代料/状态/单位八目标列各配同义词组：`料号/物料编码/Part No/P/N/part_number/物料号…` 等，归一化后精确匹配命中标 source=synonym）；第二级对未命中表头走 `f6.header_mapping` prompt（输入：全部表头 + 每列前 3 个样本值 + 目标列定义清单；输出逐表头 `{target_col,confidence,reason}`、无匹配输出 none 禁止硬凑，plan §4）标 source=llm；两级产物仅预填、**永不直接生效**（A3）；`substitutes.py` 替代料列确定性切分（正则 `[,;｜|、，；]`、去空格/去重/上限 20、料号区分大小写，C-Q2）并在映射页返回切分预览供人工确认；`GET /boms/{id}/mapping-suggestions` 返回带来源与置信度的建议；`POST /boms/{id}/mapping` 人工确认映射（`{column_mapping,version_label?,save_template?}`）→ 必选列校验（料号/数量，缺失 `BOMDIFF_REQUIRED_COLUMN_MISSING`，可选列缺失记 stats.skipped_optional_cols，FR6.1.3）→ 触发行级校验；`GET /boms/mapping-templates?name=` 模板查询 + 保存模板（audit `bomdiff.template.saved`，FR6.1.5，项目级优先命中）；LLM schema 校验失败重试 1 次后该列标记未映射由人工选择，不阻塞（plan §4 降级）。
- **涉及文件/模块**：`app/modules/bomdiff/import/header_guess.py`、`import/substitutes.py`、`import/api.py`（suggestions/mapping/templates）
- **完成标准**：同义词表命中/未命中分层单测（常规名命中 synonym、非常规名落 LLM 层，AC6.1.1 场景；大小写/空白归一）；LLM 桩驱动 suggestions 落库含 confidence/reason 且 none 输出不硬凑映射；schema 失败重试后降级为未映射（plan §4）；替代料切分矩阵单测（5 种分隔符、混用、去重/去空格、超 20 进错误列表不静默丢弃，C-Q2）；必选列缺失拦截 + skipped_optional_cols 说明（FR6.1.3）；保存模板 → 新导入按名应用映射预填（FR6.1.5）；**猜测结果未经 POST /mapping 确认不落 bom.column_mapping 生效值的架构断言**（A3）
- **依赖**：T03
- **粒度**：1.5 天

### T05 行级校验与修正闭环：错误列表 → 修正 → 重校验 → READY（FR6.1.4、A4）

- **目标**：`row_validate.py` 行级校验（料号为空/QTY 数量非正数值/层级格式非法/替代料超限 → error_code 落 `bom_import_errors` 含 raw_row 快照供修正表单回填）；`PUT /api/v1/boms/{id}/rows/errors`（`{corrections:[{error_id,raw_row}]}`）修正后重新校验可循环（FR6.1.4）；存在未修正错误行时 BOM 不 READY（`BOMDIFF_ROW_ERRORS_PENDING`）；全部通过 → 通过行落 `bom_rows`、bom 置 READY、row_count/stats 更新、错误行不进入比对；错误行显式修正、**不静默丢弃**（A4）；层级路径规范化器（分隔符折叠、深度数字提取，plan §6 风险缓解）与退化回落（层级列整体不可用时纯料号对齐并在运行信息说明）在此定口径。
- **涉及文件/模块**：`app/modules/bomdiff/import/row_validate.py`、`import/levelpath.py`（规范化器）、`import/api.py`（errors 修正端点）
- **完成标准**：四类 error_code 触发矩阵单测（空料号/0·负数·非数值/非法层级/替代料>20）；修正循环集成测试——上传含错行 xlsx → 错误列表返回 → 修正重校验 → READY 且 row_count=有效行数（FR6.1.4）；错误行不入 bom_rows 断言（A4）；未清零错误行时发起比对被 `BOMDIFF_ROW_ERRORS_PENDING` 拦截的前置语义可判定；层级路径规范化单测（`1.2.3`/`1/2/3`/缩进列 → 统一 level_path，plan §6）
- **依赖**：T04
- **粒度**：1 天

### T06 对齐与核对引擎：对齐键 → 六类差异 → 替代料集合 → 单位换算（FR6.2.1–FR6.2.4、A5、C-Q2）

- **目标**：纯函数模块（无 LLM、无 IO、无随机性，同输入同输出，A1）——`align.py`：对齐键=料号；提供层级列时=层级路径+料号（同名料号不同层级为不同对象，FR6.2.1）；`check.py`：逐对齐对产出六类差异 `QTY_DIFF/VERSION_DIFF/ONLY_A(新增)/ONLY_B(缺失)/SUBSTITUTE/STATUS_DIFF` + 一致料号落 MATCHED（FR6.2.2）；替代料三态判定——①料号缺失但出现在对方任一行替代料集合→替代料差异（FR6.2.3）、②双方均在但无序集合不等→替代料不一致、③均不满足才判 B 缺失；两类统一 SUBSTITUTE 展示、value_a/value_b 记双方集合（A5/C-Q2 Assumptions）；`quantity.py`：单位可换算则归一后比较、不可换算字符串精确比对并标注"单位不可换算"（FR6.2.4，plan §6 换算表风险缓解）；版本字符串精确比对。
- **涉及文件/模块**：`app/modules/bomdiff/engine/align.py`、`engine/check.py`、`engine/quantity.py`
- **完成标准**：对齐键单测（无层级=料号、有层级=路径+料号、同名不同层级为不同对象，FR6.2.1）；六类差异穷举 + MATCHED 计入断言（FR6.2.2）；替代料三态优先级单测（替代料差异先于 B 缺失；含分隔符边界用例；无序集合比较，A5/C-Q2）；单位换算单测（可换算归一比较、pcs/件/个 同义、不可换算字符串比对并标注，FR6.2.4）；纯函数性架构测试（模块 import 图无 LLM/无 IO 依赖，A1）——**此为 AC6.2.1 100% 一致性的实现基座**
- **依赖**：T02
- **粒度**：2 天

### T07 规则分级 + 关键件清单管理（FR6.3.1、C-Q1、A6）

- **目标**：`grading.py` 风险规则矩阵——版本不一致→高、数量不一致→中、新增/缺失→中、替代料→中、状态→低；APPROVED 关键件清单命中 → 数量差异升高（risk_reason 记命中规则如"关键件清单命中：电芯类"）；线上无 APPROVED 清单 → 数量不一致一律"中"兜底不阻塞（C-Q1 Assumptions）；优先级：人工覆盖（Phase 1 预留字段，无独立 API，plan 假设④）> 规则 > 默认矩阵；`criticalparts/` 模块——`GET/POST/PUT /api/v1/bom-diff/critical-parts`（版本化 CRUD，变更 audit `bomdiff.criticalpart.updated`）+ `POST /critical-parts/{id}/transition`（DRAFT→APPROVED，质量/研发负责人，F10 workflow）；**初版清单数据起草**：电池行业通用实践 ≥30 项料号规则（电芯/BMS/继电器/保险丝/高压连接器/防爆阀等三类匹配），DRAFT 态 seed 导入（C-Q1）；run 发起时取生效版本快照、仅影响新 run（已完成 run 不重算）。
- **涉及文件/模块**：`app/modules/bomdiff/engine/grading.py`、`app/modules/bomdiff/criticalparts/api.py`、`criticalparts/service.py`、`evals/bom_diff/critical_parts_seed_v1.json`
- **完成标准**：默认矩阵穷举单测（五类差异→高中低映射，FR6.3.1）；关键件命中数量升高 + risk_reason 记录断言；无 APPROVED 清单兜底全"中"且不阻塞（C-Q1 Assumptions，端到端单测）；清单 CRUD + transition 权限矩阵（工程师定版 403、质量/研发负责人成功，C-Q1）；seed 数据量断言（≥30 项、三类匹配规则齐备）；清单 APPROVED 后新 run 生效、旧 run 结果不变（快照语义，C-Q1 Assumptions）；变更审计 `bomdiff.criticalpart.updated` 含 who/version
- **依赖**：T06、T01
- **粒度**：1.5 天

### T08 比对管线编排：run 发起 → Celery 任务 → 分阶段执行 → SSE + Runs 查询 API（FR6.2 前置、FR6.4.1、C-Q3）

- **目标**：`POST /api/v1/bom-diff/runs`（body `{bom_a_id,bom_b_id}`）同步校验——两侧同项目 + 均 READY（否则 `BOMDIFF_BOM_NOT_READY`，失败同步 4xx 不入队）→ 创建 run（DRAFT/QUEUED）+ 记录 `critical_parts_version` 快照 → 投递 Celery `bomdiff` 队列返回 `{run_id,task_id}`；Celery 任务按 plan §1.2 编排：读 bom_rows（**禁绕过 F1 解析模型的导入链**）→ T06 align → T06 check → T06 quantity → T07 grading → stats/overview 落 run 行 → SUCCESS/FAILED + fail_reason（`BOM_NOT_READY/ENGINE_ERROR/ATTRIBUTION_FAIL`）；SSE 经 `GET /api/v1/tasks/{id}/events` 推送 `QUEUED→RUNNING(stage=align|check|grading|attribution, progress 0–100)→SUCCESS/FAILED`（specs/README 异步约定）；emit 审计 `bomdiff.run` + KPI `bomdiff.start`；`GET /bom-diff/runs`（分页 `{items,total,page}`，含状态/总览摘要，C-Q3 历史列表）、`GET /runs/{id}`（overview+stats，FR6.4.1 总览数据源）、`DELETE /runs/{id}`（仅发起人 + DRAFT + 无 Issue 关联，软删 + audit `bomdiff.run.deleted`，带 Issue 返回 `BOMDIFF_RUN_HAS_ISSUES`，C-Q3 Assumptions/A8）。
- **涉及文件/模块**：`app/modules/bomdiff/api/runs.py`、`app/modules/bomdiff/run/pipeline.py`、`app/worker/tasks/bomdiff_run.py`
- **完成标准**：未 READY BOM 发起返回 `BOMDIFF_BOM_NOT_READY` 且无 run 记录；fixtures 预置差异集 BOM 对端到端 SUCCESS 且 overview 与 items 一致（total_parts/matched/diff_count/risk 分布，FR6.4.1）；SSE 事件序列契约测试（QUEUED→RUNNING 各 stage→SUCCESS）；runs 分页列表含状态/总览摘要（C-Q3）；发起人删除 DRAFT 无 Issue 的 run 成功（软删+审计）、带 Issue 返回 `BOMDIFF_RUN_HAS_ISSUES`、非发起人 403（A8）；管线失败 → FAILED + fail_reason 可读；`bomdiff.run` 审计含 critical_parts_version 与两侧 bom id
- **依赖**：T05、T06、T07
- **粒度**：1.5 天

### T09 AI 归因建议 + grounding 校验（FR6.3.2、FR6.3.3）

- **目标**：管线 attribution 阶段以 `f6.diff_attribution` prompt 批量生成差异行归因——输入**仅** run 元数据（两侧文件名/version_label/导入时间/备注列摘录）+ 差异行结构化数据；系统指令"只允许基于输入数据推断，禁止引用外部知识/标准，输出一句中文建议（≤120 字），语气为'请确认'性质"（plan §4）；**确定性 grounding 校验（代码非 prompt，plan §4）**：归因文本中出现的料号必须存在于该 run 的差异行集合、出现的数值/版本串必须与对应行 value_a/value_b 归一后匹配，失败丢弃该条 ai_note + warning；schema 校验失败重试 1 次后 ai_note 置 NULL + `BOMDIFF_ATTRIBUTION_UNAVAILABLE` warning，**不阻塞比对结果、行照常可读可处置**（plan §3.2 降级）；ai_note_meta 持久化 `{prompt_id,prompt_version,model,model_version}`（spec §5 审计）；归因恒为草稿建议性质、UI [AI] 标识由 API 返回结构支持（FR6.3.2/6.3.3）。
- **涉及文件/模块**：`app/modules/bomdiff/attribution/generator.py`、`attribution/grounding.py`、`app/worker/tasks/bomdiff_run.py`（attribution 阶段接线）
- **完成标准**：grounding 校验器单测——构造引用外部料号/外部标准的归因断言被剔除并记 warning；合法归因（仅引用 run 元数据与差异行）通过入库（FR6.3.2）；mock LLM 失败 → run 仍 SUCCESS、ai_note NULL + `BOMDIFF_ATTRIBUTION_UNAVAILABLE` 可读、差异行照常可处置（plan §3.2）；ai_note_meta 四字段与实测模型一致（FR10.3.1）；"PLM 版本未更新，请确认是否漏改"类样例通过的正例断言
- **依赖**：T08
- **粒度**：1 天

### T10 处置闭环 + Issue 双向链接 + 定版锁定（FR6.5.1–FR6.5.4、AC6.5.1、A7）

- **目标**：`POST /bom-diff/items/{id}/dispose`（`{action: confirm|ignore|to_issue, issue:{title,assignee_id,due_date}?, note?}`）——to_issue 经 platform 统一 Issue 对象创建（`source_type=BOM_DIFF_ITEM` + `source_id` 正向链接、描述含差异快照，item.issue_id 反向回填，AC6.5.1 双向跳转）；`POST /runs/{id}/items/batch-dispose`（按 filters|item_ids，FR6.5.2，逐条记录处置人=同一操作人不支持代处置，对已处置行逐条冲突结果的部分成功语义）；`POST /items/{id}/dispose/revoke`（回 none + disposal_history 留痕 + audit `bomdiff.item.disposal.revoked`，FR6.5.3）；逐条/批量/撤销均 audit `bomdiff.item.disposed` 系（处置人/时间/意见，FR6.5.3）+ 处置耗时 KPI 打点；`POST /runs/{id}/confirm` → F10 通用 transition（DRAFT→APPROVED，研发主管，comment 必填）——前置校验无 disposition=none 的差异行（否则 `BOMDIFF_CONFIRM_INCOMPLETE`），成功后审计 `run.confirmed`（who/when/comment）+ KPI `bomdiff.confirm`；APPROVED 后明细锁定——处置/批量/撤销统一返回 `BOMDIFF_RUN_LOCKED`（FR6.5.4，A7）；`GET /runs/{id}/items/{item_id}/issue` 正向跳转（反向由 issues 详情带 source 链接）。
- **涉及文件/模块**：`app/modules/bomdiff/dispose/api.py`、`dispose/service.py`、`dispose/locks.py`（锁定谓词，供各端点共用）、`app/modules/bomdiff/api/runs.py`（confirm/issue 跳转）
- **完成标准**：**AC6.5.1 集成闭环**——to_issue 创建 Issue（标题/描述含差异快照/责任人/截止日期）→ item.issue_id 回填 → Issue 详情含 source 反向链接且双向可跳转（AC6.5.1/FR6.5.1）；批量处置逐条记录处置人 + 部分成功响应结构断言（FR6.5.2）；撤销回 none + history 含 revoked 留痕 + 审计（FR6.5.3）；未处置完 confirm 返回 `BOMDIFF_CONFIRM_INCOMPLETE`；研发主管定版成功（comment 必填）后处置/批量/撤销三端点全部 `BOMDIFF_RUN_LOCKED`（FR6.5.4）；锁定谓词单一实现多处共用（防绕过，A7）；`bomdiff.item.disposed/run.confirmed/run.deleted` 审计含 who/when；带 Issue 的 run 删除被拒（C-Q3 Assumptions）
- **依赖**：T08
- **粒度**：1.5 天

### T11 导出：Excel/PDF/Word 三格式异步生成 + 水印（FR6.6、A9）

- **目标**：`POST /bom-diff/runs/{id}/export`（`{format: pdf|excel|word}` → task_id，Celery `bomdiff` 队列，SSE stage=export）——Excel（openpyxl 三 Sheet：总览/差异明细含等级与 AI 归因/处置记录，FR6.6.1）、PDF（ReportLab，按 **run.state 定版时点**注入"草稿"水印——DRAFT 加水印、APPROVED 无水印，FR6.6.2/A9）、Word（python-docx，含总览/明细/处置/运行信息：文件、版本、时间、操作人，FR6.6.1）；产物写 MinIO 返回预签名 URL；`GET /runs/{id}/exports` 导出历史（format/file_url/state）。
- **涉及文件/模块**：`app/modules/bomdiff/export/excel.py`、`export/pdf.py`、`export/word.py`、`app/modules/bomdiff/api/export.py`、`app/worker/tasks/bomdiff_export.py`
- **完成标准**：Excel 三 Sheet 内容与 run 明细/处置数据一致性集成测试（FR6.6.1）；PDF DRAFT 态含水印、APPROVED 后（定版时点）无水印断言（FR6.6.2/A9）；Word 含运行信息四要素（文件/版本/时间/操作人）；三格式均走异步任务、SSE 可见 export stage、预签名 URL 可下载（specs/README 异步约定）；导出历史接口返回结构契约测试
- **依赖**：T08
- **粒度**：1 天

### T12 前端：BOM 工作台 + 导入向导三步（UI_GUIDE 页面11、FR6.1、AC6.1.1）

- **目标**：`pages/bom` BOM 工作台——设计 BOM/PLM BOM 页签列表（`GET /boms`）+ BOM 树 + 物料明细渲染（FR6.1，页面11；「料号匹配」页签与「ERP BOM」入口不做，plan 假设⑧）；`pages/bom/import` 导入向导三步——①上传（类型校验 + PDF 未确认提示 `BOMDIFF_PDF_NOT_CONFIRMED` 引导先校对）②列映射确认页（预览表头+样本行 + 两级建议预填：synonym/llm 来源与置信度展示 + 下拉调整 + 替代料切分结果预览（C-Q2 Assumptions）+ 模板一键应用/保存，目标 2 分钟完成映射的易用性 AC6.1.1）③错误行修正表格（错误行回填 raw_row、逐行修正重校验循环，FR6.1.4，plan A4）。
- **涉及文件/模块**：`apps/frontend/src/pages/bom/*`、`pages/bom/import/*`、`features/bom-viewer/*`（BOM 树渲染、错误行修正表格组件）
- **完成标准**：组件测试——向导三步流转 + 上传类型/未确认 PDF 拦截提示（FR6.1.1/A2）；映射页预填含 synonym/llm 来源标识、下拉调整后提交生效（FR6.1.2/A3）；替代料切分预览可确认（C-Q2 Assumptions）；模板应用一键预填 + 保存（FR6.1.5）；错误行修正表格回填与重校验循环（FR6.1.4）；必选列缺失/可选列缺失提示（FR6.1.3）；BOM 树 + 明细渲染（页面11）
- **依赖**：T04、T05
- **粒度**：2 天

### T13 前端：比对发起 + 结果页总览钻取 + 差异明细处置（UI_GUIDE 页面12、FR6.4、FR6.3.3、FR6.5）

- **目标**：`pages/bom/diff` 发起页——A/B BOM 选择（限 READY，C-Q3 历史列表入口）+ 发起后 SSE 进度条（stage=align/check/grading/attribution）；`pages/bom/diff/result` 结果页——总览卡片（总物料数/一致/差异/风险高中低分布，FR6.4.1）点击钻取到明细表并带对应筛选（FR6.4.1）；明细表按差异类型/风险等级/处置状态筛选与排序（FR6.4.2）；行结构展示差异类型/风险等级（色标）/两侧值对照/AI 归因列（恒带 [AI] 标识、"请确认"语气、仅建议性质，FR6.3.3）；行操作列处置（确认/忽略/转整改任务：标题+责任人+截止日期表单）与撤销（FR6.5.1/6.5.3）；按当前筛选批量处置（FR6.5.2）；Issue 双向跳转入口（AC6.5.1，跳转复用 Issue 列表页）；完成确认按钮（comment 必填弹窗、未处置完提示 `BOMDIFF_CONFIRM_INCOMPLETE`，FR6.5.4）+ 定版后锁定提示（`BOMDIFF_RUN_LOCKED`）；运行历史列表（状态/总览摘要/删除——发起人可见，C-Q3）；关键件清单管理入口（列表/版本/状态/定版，研发主管可见，C-Q1）；水印提示（DRAFT 导出带草稿水印说明）。
- **涉及文件/模块**：`apps/frontend/src/pages/bom/diff/*`、`pages/bom/diff/result/*`、`features/bom-viewer/*`（处置操作列组件）
- **完成标准**：组件测试——总览卡片四指标渲染 + 点击钻取带筛选（FR6.4.1）；明细三维筛选与排序正确（FR6.4.2）；行结构四要素齐备且 AI 归因列带 [AI] 标识（FR6.3.3/specs/README AI 语义）；处置三动作 + 撤销调用端点且 UI 态翻转（FR6.5.1/6.5.3）；批量处置按当前筛选生效（FR6.5.2）；to_issue 表单提交后 Issue 跳转链接可用（AC6.5.1 前端侧）；未处置完 confirm 提示 INCOMPLETE、无定版权限用户不显示定版按钮（权限隐藏）；RUN_LOCKED 触发锁定提示
- **依赖**：T08、T09、T10
- **粒度**：2 天

### T14 评测：引擎金标集 + 表头映射金标 + 归因小样本（AC6.2.1、A11）

- **目标**：`evals/bom_diff/` 离线评测（独立于线上埋点，A11）——① **引擎金标集（M3 硬门槛）**：预置差异集——六类差异每类 ≥5 条 + 替代料嵌套场景（X 缺失但出现在对方替代料集合/双方集合不等/替代料含分隔符边界）+ 含层级路径对齐用例，离线跑核对引擎（T05–T07）断言与预置答案 **100% 一致**（AC6.2.1），任何引擎/规则变更触发回归；② 表头映射金标集（≥50 个真实/扰动表头，含非常规列名）：同义词层/LLM 层分层统计，综合 top1 准确率 ≥90% 为**观测**指标（AC6.1.1 由 T15 走查验收，准确率用于监控猜测质量驱动词表迭代）；③ AI 归因小样本评测（≥30 条差异，双人标注"归因是否合理"）：合理率为观测指标、不设硬门槛（仅建议性质）；④ 报告版本化归档。
- **涉及文件/模块**：`evals/bom_diff/golden_diff_set_v1.json`、`evals/bom_diff/golden_headers_v1.json`、`evals/bom_diff/run_eval.py`、`evals/bom_diff/report_v1.md`
- **完成标准**：引擎金标集可重复运行且结果与预置答案 100% 一致（**AC6.2.1 判定逻辑落地**，含替代料三态与层级对齐用例）；表头映射 top1 ≥90% 统计口径实现 + 分层报表（观测）；归因合理率小样本流程跑通（观测，不阻塞）；评测脚本与报告版本化归档；金标集 JSON schema 与 plan §4 评测口径一致
- **依赖**：T04、T06、T07、T09
- **粒度**：1.5 天

### T15 端到端验收（覆盖 F6 全部 AC）

- **目标**：演示环境全链路验收：上传设计 BOM 与 PLM BOM（xlsx 主链 + PDF 已确认链 + csv 容器转换链各一）→ 导入向导三步走查——**含 500 行、2 列名非常规的 BOM 在映射页 2 分钟内完成映射（AC6.1.1 易用性走查）** → 错误行修正循环 → 发起比对 → SSE 各阶段进度 → 结果页总览卡片钻取（FR6.4.1）/明细筛选排序（FR6.4.2）→ 引擎金标报告核对 **AC6.2.1 100% 一致** → AI 归因 [AI] 标识与 grounding（FR6.3.2/6.3.3）→ 关键件清单 DRAFT 导入→质量/研发负责人 APPROVED→新 run 数量差异升高、旧 run 不变（C-Q1 快照）→ 逐条处置/批量处置/撤销审计留痕（FR6.5.1–6.5.3）→ 转整改任务双向链接跳转（**AC6.5.1**）→ 完成确认定版（comment 必填）→ 定版后处置 RUN_LOCKED（FR6.5.4）→ DRAFT 导出 PDF 带"草稿"水印、APPROVED 后无水印、Excel 三 Sheet/Word（FR6.6.1/6.6.2）→ run 删除约束（发起人 DRAFT 可删/带 Issue 不可删，C-Q3）→ 审计事件全链导出核对（`bomdiff.run/item.disposed/item.disposal.revoked/run.confirmed/run.deleted/criticalpart.updated/template.saved`）→ KPI 视图 `bomdiff.start→confirm` 耗时出具（对照人工基线验 ↓70%，spec §5）→ F4 bom_diff 技能经同一发起入口复验（plan 假设⑥）→ 禁绕过断言（AC1.6.1 复用）在 e2e 中复验。产出验收核对单逐项勾稽。
- **涉及文件/模块**：`apps/backend/tests/e2e/test_f6_acceptance.py`、F6 验收核对单（`specs/` 下 F6 验收记录）
- **完成标准**：以下 AC 全部通过——**AC6.1.1**（500 行/2 非常规列 BOM 映射页 2 分钟走查）、**AC6.2.1**（引擎金标 100% 一致，评测报告为准）、**AC6.5.1**（转整改任务 Issue 列表可见且双向链接可跳转）；并以用例覆盖 FR6.1.1–6.1.5、FR6.2.1–6.2.4、FR6.3.1–6.3.3、FR6.4.1/6.4.2、FR6.5.1–6.5.4、FR6.6.1/6.6.2；`bomdiff.start→confirm` 耗时数据可出具（KPI ↓70% 随 F10.6 基线联合判定）；新增模块行覆盖率 ≥80%（全局规则）；禁绕过断言（AC1.6.1 复用）复验通过
- **依赖**：T11、T12、T13、T14
- **粒度**：1 天

---

## 任务依赖图

```text
T01 → T02 ─┬→ T03 → T04 → T05 ────────┐
           └→ T06 → T07 ──────────────┼→ T08 ─┬→ T09 ─┐
                                      │       ├→ T10 ─┤
                                      │       └→ T11 ─┤
可并行：T06/T07（引擎线，仅依赖 T02）  │               │
与 T03/T04/T05（导入线）并行          │  T12（依赖 T04/T05）──┐
                                      │  T13（依赖 T08/T09/T10）─┤
                                      │  T14（依赖 T04/T06/T07/T09）─┤
                                      └──────────────────────────────┴→ T15
```

并行建议：T06（核对引擎）与 T03–T05（导入向导）在 T02 后即分线并行——引擎是纯函数可先行单测（A1）；T09/T10/T11 在 T08 管线打通后并行；T12 前端仅需 T04/T05 契约即可启动 mock 开发，与后端 T08–T11 并行；T14 金标集构建可在 T06 单测就绪后即开始，不依赖前端。

---

## Breakdown 决策与假设（Clarifications / Assumptions）

- **[D1] 集成测试不单列任务**：同 F5 [D1] 手法——导入向导闭环、比对管线 SSE 序列、Issue 双向链接（AC6.5.1）、定版锁定、清单版本快照、run 删除约束、导出水印、禁绕过（AC1.6.1 复用）、权限矩阵（5 角色 × 7 操作参数化）等集成/架构测试**分散进 T03–T11 各自的完成标准**；F6 的跨模块风险点（禁绕过解析、猜测结果不直接生效、锁定谓词单一实现、清单快照语义）都已绑定到对应实现任务的验收里。
- **[D2] 引擎线与导入线并行解耦**：T06/T07（确定性引擎 + 规则分级）与 T03–T05（导入向导）按 plan A1 分层天然解耦——引擎纯函数无 IO/LLM 依赖可先行单测，两线在 T08 管线处汇合（bom_rows 为接口契约）。理由：AC6.2.1 的 100% 一致性不依赖模型质量与导入 UI，先夯实 T06 可持续回归。
- **[D3] 初版关键件清单数据起草并入 T07**：C-Q1 决策由我方起草（≥30 项三类匹配规则），作为 seed 数据随清单 CRUD 交付，不单列内容任务；客户质量/研发负责人评审 APPROVED 节奏属业务流程，M3 Exit 前置检查推动（plan §6 风险表），不阻塞 T07 交付（无 APPROVED 时兜底全"中"已在 T06/T07 验收）。
- **[D4] AC6.1.1 走查验收方式**：2 分钟易用性验收属主观走查（spec 明示「走查」），T12 以映射页单屏预览 + 下拉调整 + 模板复用的最小交互实现并以组件测试覆盖交互路径；正式 2 分钟走查在 T15 验收环节由真实用户执行，准确率指标（≥90% 观测）在 T14 持续监控驱动同义词表迭代。
- **[D5] LLM 以桩起步**：同 F3/F5 手法——表头猜测/归因两个 LLM 点经 LLMGateway 桩（确定性返回 + 可注入故障/schema 违例）跑通全部逻辑与降级路径；真实模型接入属部署联调，纳入 T14 跑分与 T15 验收，不单列任务。
- **[D6] KPI ↓70% 的基线依赖**：`bomdiff.start→confirm` 耗时打点在 T01/T08/T10 落地，但 ↓70% 达标判定依赖 F10.6 人工基线测量（M1 交付项，plan §6 风险表）——T15 仅核对耗时数据可出具，达标判定与 F10 联合进行，不作为 F6 单独阻塞项。
- **[D7] 任务粒度校验**：拆解结果 15 条 = 15 条上限，plan 粒度合格（无超 2 人日任务），无需回改 plan；若实现期 T06（核对引擎）或 T08（管线编排）超期，优先在 T06 内按 align/check/quantity 再拆分而非新增顶层任务。
- **[D8] clarifications 全文有效**：C-Q1（关键件清单我方起草 + DRAFT→APPROVED 生效 + 未定版兜底全"中" + run 版本快照）、C-Q2（替代料确定性切分正则/上限 20/无序集合/统一 SUBSTITUTE 展示）、C-Q3（历史全量留存/软删约束/diff-of-diff 不做）已分别落位 T07、T04/T05/T06、T08/T10 的目标与完成标准；plan §7 假设①–⑧（PDF 宽严、csv 容器转换、bom 不暴露 transition、人工覆盖预留、换算表初版、F4 同入口、status/state 分离、页面11 裁剪）已分别落位 T03、T01、T07、T08、T11、T12。
