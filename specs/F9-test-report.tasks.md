# F9 测试报告生成 — 任务清单（Tasks）

| | |
| ---- | ---- |
| Feature | F9-test-report |
| 输入 | specs/F9-test-report.md、specs/F9-test-report.clarifications.md（C-Q1–Q3）、specs/F9-test-report.plan.md（冲突时以后两者为准）、specs/README.md |
| 关联 | specs/F10-platform-governance.tasks.md（M1 骨架为前置：BaseEntity/workflow（transition 钩子）/audit/rbac/kpi/LLMGateway/prompt_registry/OBJECT_REGISTRY/Task+SSE/issues 多态对象）、specs/F1-document-parsing.tasks.md（xlsx/csv native 通道为前置，禁绕过数据契约，A2）、specs/F8-test-case-generation.tasks.md（ADOPTED 用例集 + criteria_structured 落地为前置，C-Q1/A11 跨 feature 协调项）、specs/F2-knowledge-base.tasks.md（质量问题分类标签为前置，FR9.6.2）、specs/F3-rag-retrieval.tasks.md（统一检索服务 + kb_version 为前置，FR9.3.2）、specs/F7-fmea-generation.tasks.md（fmea_rows source/source_ref 契约与修订版本机制为前置，F7 plan A12）、specs/F4-ai-chat.tasks.md（report_gen 技能复用 `POST /test-reports/drafts` 与 `/body/generate` 同一入口，A13） |
| 阶段 | speckit-tasks |
| 粒度约定 | 每条任务 0.5–2 人日；超过 2 人日须继续拆分 |
| 前置 | F10 M1 骨架（BaseEntity/LLMGateway/prompt_registry/审计通道/require_perm/kpi_events/workflow 通用 transition + 钩子位/OBJECT_REGISTRY/issues(origin_type 多态)/Task+SSE）、F1.6 xlsx/csv native 通道（PARSED 数据契约）、F8 ADOPTED 用例集（含 `criteria_structured` 新列落地，A11）、F2 质量问题分类标签（quality/质量案例）、F3 统一检索服务（kb_version 快照）、F7 `fmea_rows` 的 `source='report_anomaly' + source_ref` 预留契约与 docxtpl 导出先例 |
| 里程碑内顺序 | M4：F9.1（T03/T04/T06）→ F9.2（T05）→ F9.3（T07）→ F9.4（T08/T09）→ {F9.5（T10）∥ F9.6（T11）}；T12/T13 前端仅需 API 契约即可 mock 启动；T14 评测在 T03 判定引擎就绪后即可开始 |

> 依赖列格式：依赖的任务号。编号即执行顺序（可并行：T03 判定引擎与 T04 导入管线在 T02 后衔接；T10 导出与 T11 联动在 T09 后并行；T12/T13 前端按契约先行；T14 评测不依赖前端）。

---

## 任务清单

### T01 F9 接入点骨架：审计事件定义、状态机接线、权限点、KPI 埋点

- **目标**：一次性定义 F9 挂接 F10 的接入点——① 审计事件常量：`report.imported / body.generated / anomaly.confirmed / report.approved / report.exported`（spec §5）+ `anomaly.suggestion.generated`（AI 操作必录，FR10.3.1，含 model/model_version、prompt_id/prompt_version、kb_version、citations）+ `anomaly.verdict.reviewed`（判定冲突复核，C-Q1 Assumptions）+ `report.template.updated`（模板替换，C-Q2）；`report.imported` 字段契约含 criteria_engine_version 与警告分类统计，`report.exported` 含模板版本/报告 revision/水印标志（FR9.5.1，FR10.3.1 字段完备性）。② 状态机接线：注册 `test_report` 进 F10 workflow 配置，映射 `DRAFT→IN_REVIEW→APPROVED`（F10 plan §2.2 报告行：定版权限工程师+、结论节须已确认）；实现 **approve transition 钩子注册位**——钩子① `conclusion_confirmed=true` 校验（spec §5「结论章节未确认时定版操作被拒」）、钩子② pending 判定行清零校验（A8/假设⑥）；APPROVED 锁定 → OBJECT_LOCKED、修订 revision+1（FR10.2.4）；AI 无直写 APPROVED 通路（FR10.2.2）。③ 权限点清单 `report.view / report.create / report.edit / report.row.judge / report.anomaly.manage / report.body.generate / report.approve / report.export`（= 工程师+，项目成员可见性继承 FR10.5.3）+ `report.template.manage`（系统管理员/AI 管理员，plan §3.2）；Phase 1 无删除类操作（全量留存供审计，F6 plan A8 同取向）。④ KPI 埋点契约：`report.start`（草稿创建）/`report.approve`/`report.export`（FR10.6.2 清单）注册进 KPI SQL 视图；**`report.start→report.export` 耗时 = 验收 KPI「测试报告制作时间 ↓≥70%」分子链路**；「异常项分析耗时」子段打点契约（suggestion 生成时点 → 该报告全部异常 confirmed 时点，spec §5）。同时登记错误码（`REPORT_IMPORT_TEMPLATE_MISMATCH / REPORT_IMPORT_TOO_LARGE / REPORT_UNKNOWN_CASES_CONFIRM_REQUIRED / REPORT_CONCLUSION_NOT_CONFIRMED / REPORT_PENDING_VERDICT_EXISTS / REPORT_NO_ANOMALIES_SELECTED / REPORT_FMEA_NOT_EDITABLE / REPORT_CLASSIFICATION_REQUIRED / REPORT_EXPORT_FAILED` + 复用 `INVALID_TRANSITION / FORBIDDEN / OBJECT_LOCKED`，plan §3.2）、配置项（`report.import.row_limit=10000`（A2）/ `report.stats.caliber_version=v1`（A3）/ `report.charts.types=[pass_rate_bar,fail_distribution]`（假设⑦）/ `report.export.formats=[pdf,word]`）、prompt 注册表条目骨架 `f9.anomaly_suggestion / f9.report_conclusion`（FR10.3.4，禁裸字符串）、Task 类型注册 `report_body_gen / report_suggestion / report_export`（specs/README 异步约定）。
- **涉及文件/模块**：`apps/backend/app/modules/platform/audit/events.py`（F9 事件段追加）、`app/modules/report/constants.py`（权限点/错误码/配置项）、`app/modules/platform/workflow/configs.py`（test_report 注册 + approve 钩子位）、`app/modules/platform/kpi/views.sql`（KPI 视图段 + 异常项分析耗时子段）、`app/modules/platform/prompts/registry.py`（f9.* 条目）、`app/modules/platform/objects/registry.py`（TestReport 注册 + issues origin_type=`report_anomaly` 枚举，FR10.1.1/FR10.1.2）、Celery 队列/任务类型注册（`report` 队列）
- **完成标准**：事件/权限/错误码/配置/prompt/Task 常量表与 spec §5、plan §3.2/§4 逐条对应并有单元断言；workflow 注册后 `test_report` 可经 F10 通用 transition 走 `DRAFT→IN_REVIEW→APPROVED`，approve 钩子位可注入且非法流转 → `INVALID_TRANSITION`；AI 上下文调用 transition 被拒绝（仅人工端点可触发，FR10.2.2）；APPROVED 锁定语义（OBJECT_LOCKED）与 revision+1 断言（FR10.2.4）；`report.start/report.approve/report.export` 写入 kpi_events 后可被 SQL 视图聚合、`report.start→report.export` 耗时查询冒烟通过（spec §5）；审计命名全部符合 `<domain>.<verb>`（FR10.3.3）；配置项默认值断言（行上限 10000 / caliber v1 / 两类图表 / 双格式）
- **依赖**：无（复用 F10 M1 已有常量与钩子骨架）
- **粒度**：0.5 天

### T02 F9 数据模型 + 迁移

- **目标**：新表——`test_reports`（继承 BaseEntity：state DRAFT→IN_REVIEW→APPROVED、audit_ref、revision（FR10.1.3/FR10.2.4，A7）；`report_no` UNIQUE `RB-{项目代号}-{年份}-{seq:03d}`（C-Q3，A10）、`external_report_no` NULL 可空企业受控编号（非空优先展示，C-Q3）、title、`case_set_ref` JSONB `{case_ids[], case_count, snapshot_at}`（FR9.4.1 测试范围节/FR9.5.2 附件清单）、`stats` JSONB `{caliber_version, case_total, sample_total, pass, fail, pending, pass_rate, auto_judge_coverage, by_item[]}`（FR9.2.1/FR9.2.3，C-Q1）、`charts` JSONB `[{type,title,enabled,file_key}]`（FR9.2.2，A3）、`body` JSONB 八节 `[{section, content, ai_generated?, fallback?}]`（FR9.4.1）、`conclusion_confirmed` BOOLEAN + `confirmed_by/at`、`conclusion_fallback` BOOLEAN（A5 观测）、`report_config` JSONB、`template_id` NULL（C-Q2）、`approved_by/at`，索引 `(project_id,state)`/`(report_no) UNIQUE`/`(external_report_no)`，plan §2.1）；`test_data_imports`（report_id、file_key/file_name/format xlsx|csv、row_count、`warnings` JSONB `[{row_no, case_id?, code: unknown_case|verdict_conflict|unit_mismatch|judge_failed|column_skipped, message}]`（FR9.1.2 + C-Q1 抽取版本载体）、`criteria_engine_version`（C-Q1 Assumptions 不回溯重判）、imported_by/at，索引 `(report_id)`）；`test_result_rows`（import_id/report_id/row_no、`case_id` NULL 逻辑引用（未知行不入库，FR9.1.2，A2）、case_no/test_item 冗余快照（A1）、sample_no/measured_value/unit、`verdict` pass|fail|pending（CHECK）、`verdict_source` manual|rule|extracted|pending（C-Q1）、`criteria_snapshot` JSONB（判定时点快照可复现，AC9.3.1，A1）、`delta_pct` NULL（FR9.3.1，A3）、note，索引 `(report_id,verdict)`/`(report_id,case_no)`/`(import_id,row_no)`）；`report_anomalies`（report_id、`result_row_id` UNIQUE（一行至多一条异常，A9）、location JSONB `{case_no,sample_no,row_no}`、measured_vs_criteria JSONB、`over_limit_pct`（=delta_pct，FR9.3.1）、impact（确定性文案 + 人工可改，假设⑧）、`ai_suggestion` JSONB NULL `{items[], model, model_version, prompt_id, prompt_version, kb_version, citations[], generated_at}`（FR10.3.1 审计字段内嵌，A4/A9）、`suggestion_status` none|draft|confirmed（FR9.3.2，A4）、suggestion_confirmed_by/at、owner/owner_note（FR9.3.3）、`fmea_row_id`/`issue_id` 反向回链（AC9.6.1/FR9.6.2，A9），索引 `(report_id)`/`(report_id,suggestion_status)`/`(result_row_id) UNIQUE`/`(fmea_row_id)`/`(issue_id)`，plan §2.2）；`report_templates`（name/file_key/version、is_default 内置默认种子行、placeholder_contract_version（C-Q2 契约冻结）、uploaded_by/at、state 复用 F10 workflow）；`report_exports`（report_id、format pdf|word、file_key（历史不重渲染，C-Q2 Assumptions）、template_id/template_version、report_revision、`watermarked` BOOLEAN（FR9.4.3）、exported_by/at，索引 `(report_id,exported_at)`）。**跨 feature 协调项（A11）**：`test_cases` 新增可空列 `criteria_structured JSONB`（F8 生成/采用侧写入、向后兼容 FR10.1.4，不修改 F8 plan/spec 文件）。`object_source_link` 本次不扩展 src_type（异常依据内嵌 criteria_snapshot/kb citations，plan §2.3）。Alembic 迁移。
- **涉及文件/模块**：`app/modules/report/models.py`、`alembic/versions/*`、`app/modules/testgen/models.py`（criteria_structured 新列，A11 协调）、`app/worker/queues.py`（report 队列）
- **完成标准**：迁移可上下执行；`test_reports` BaseEntity 公共列齐备且注册于 OBJECT_REGISTRY（FR10.1.1/FR10.1.3）；`(report_no)` UNIQUE 与 `(result_row_id)` UNIQUE 约束断言（C-Q3/A9）；verdict/verdict_source/suggestion_status/format 取值域 CHECK 断言；`criteria_snapshot` 结构含引擎版本字段（AC9.3.1 可复现前提，A1）；`ai_suggestion` JSONB 审计字段完备性 schema 断言（FR10.3.1）；`test_cases.criteria_structured` 可空列存在且 F8 既有流程不受影响（向后兼容断言，A11/FR10.1.4）；`report_exports` 含 template_version/report_revision/watermarked 列（FR9.5.1/FR9.4.3）；内置默认模板种子行 + placeholder_contract_version 落库（C-Q2）
- **依赖**：T01
- **粒度**：1.5 天

### T03 判定规则引擎 + 正则兜底抽取（FR9.1.3、AC9.3.1、C-Q1、A1/A3）

- **目标**：**纯确定性代码（零 LLM，C-Q1/A1）**——`judge.py` 判定规则引擎：消费 `criteria_structured` 三型——阈值型 `{type:threshold, op: gte|gt|lte|lt, limit, unit}`、区间型 `{type:range, min, max, min_inclusive, max_inclusive}`（默认闭区间，C-Q1 Assumptions）、布尔型 `{type:boolean}`（导入时判定列直填，系统不再计算，C-Q1）；多条 criteria 全部通过才 Pass（AND 语义）；优先级 人工直填(manual) > 结构化规则(rule) > pending；实测值单位与 criteria unit 不一致 → 不换算、置 pending + `unit_mismatch` 警告（C-Q1 Assumptions 保守策略）；`delta_pct` 纯函数：阈值型 `(|实测−limit|/limit)×100%`、区间型取偏离最近边界同式（AC9.3.1 口径，与 UI 页面21「超出判定阈值 12%」一致）；影响判定确定性文案生成（按超限幅度分档 + 是否致命项，人工可改，假设⑧）。`extract.py` 正则兜底抽取：用例仅自由文本 criteria 时解析数值限值 + 单位对齐（仅覆盖阈值/区间数字型），抽取结果记 `verdict_source='extracted'` + 引擎版本入 criteria_snapshot；抽取失败 → pending + `judge_failed` 警告，不阻塞其余行（C-Q1「判不了显式交人工」）。引擎整体版本化 `criteria_engine_version`，写入快照，升级不回溯重判（C-Q1 Assumptions）。纯函数/无 IO，供 T04 导入管线与 T14 评测复用。
- **涉及文件/模块**：`app/modules/report/import/judge.py`、`import/extract.py`、`app/modules/report/schemas.py`（criteria 三型 Pydantic 模型）
- **完成标准**：三型 criteria 判定矩阵单测——threshold 四算子、range 开闭边界（默认闭区间 + 显式开区间）、boolean 不参与计算（FR9.1.3/C-Q1）；多条件 AND 语义单测（一假即 Fail）；优先级断言 manual > rule > extracted > pending（C-Q1）；单位不匹配 → pending + 警告、无换算副作用（C-Q1 Assumptions）；正则抽取成功/失败样本单测（数值限值 + 单位对齐；失败 → pending + judge_failed 警告，C-Q1）；**delta_pct 公式与预置答案一致（阈值型/区间型/边界用例全覆盖，AC9.3.1 直接断言，A3 纯函数直验）**；影响判定文案分档断言（假设⑧）；`criteria_engine_version` 写入快照断言（C-Q1 Assumptions）；纯函数性架构测试（judge/extract 模块 import 图无 LLM/无 IO 依赖，A1）
- **依赖**：T02
- **粒度**：1.5 天

### T04 导入管线：模板下载 + 建草稿即导入（FR9.1.1–FR9.1.3、AC9.1.1、C-Q3、A2/A10/A13）

- **目标**：`GET /api/v1/test-reports/import-template`（列模板：Case ID/样本编号/实测值/实测单位/判定（可空）/备注，FR9.1.1）。`POST /api/v1/test-reports/drafts`（multipart: file + project_id + title，body 可携 `ignore_unknown_rows`）**同步一次完成建草稿+导入+判定+统计+异常（A2/假设①）**：权限 `report.create`；文件格式 xlsx/csv 校验 → `REPORT_IMPORT_TEMPLATE_MISMATCH`（列模板不符）/行数 > `report.import.row_limit`(10000) → `REPORT_IMPORT_TOO_LARGE`（A2）；**编号分配**：`RB-{项目代号}-{年份}-{seq:03d}` 经项目游标行 `SELECT ... FOR UPDATE` 串行化、创建事务内分配、终身不变、作废不回收（C-Q3，A10，F8 plan A6 同手法）；**用例集快照**：本项目 ADOPTED test_cases（含 criteria_structured）id 列表 + 快照时间 → case_set_ref（FR9.4.1）；**文件解析经 F1 xlsx/csv native 通道**（禁绕过数据契约，F8 plan A11 同构先例）；逐行校验：Case ID 不存在于用例集 → 未携 ignore_unknown_rows 时 422 `REPORT_UNKNOWN_CASES_CONFIRM_REQUIRED`（detail=警告列表，AC9.1.1），确认后未知行不入库、其余行正常入库（FR9.1.2）；判定列已填 → 人工直填优先，与规则引擎结果冲突 → 追加 `verdict_conflict` 警告（不阻塞，C-Q1 Assumptions）；判定为空 → T03 引擎判定/抽取/pending（FR9.1.3）；fail 行即时计算 delta_pct（FR9.3.1 口径）；**每个 Fail 行自动派生一条 report_anomalies**（location/measured_vs_criteria/over_limit_pct/impact + criteria_snapshot，A9/假设⑧）；写 test_data_imports（criteria_engine_version + warnings）+ test_result_rows；audit `report.imported` + KPI `report.start`（spec §5）；返回 `201 {report_id, report_no, stats, warnings[], pending_count}`。`GET /api/v1/test-reports?project_id=&state=&q=&page=&page_size=`（external_report_no 非空优先展示，C-Q3）、`GET /api/v1/test-reports/{id}`（report_no/external_report_no/stats/charts/body 摘要/anomalies 摘要/附件清单引用）、`PATCH /api/v1/test-reports/{id}`（title/report_config/external_report_no；APPROVED → OBJECT_LOCKED，A7）。F4 report_gen 技能经同一 drafts 入口发起（A13）。
- **涉及文件/模块**：`app/modules/report/api/drafts.py`（template/drafts/list/detail/patch）、`app/modules/report/import/parser.py`（F1 通道消费，禁自解析）、`import/validate.py`（列模板/未知行/冲突校验 + warnings）、`app/modules/report/numbering.py`（游标行锁编号分配）、`app/modules/report/service.py`（导入编排：判定→delta→异常派生→统计调用）
- **完成标准**：fixtures（项目 ADOPTED 用例集含三型 criteria 与仅自由文本用例 + xlsx/csv 样例）端到端导入成功；**AC9.1.1 集成断言——含 3 条未知 Case ID 文件 → 警告列表准确且其余行正常入库**（FR9.1.2/AC9.1.1）；未携 ignore_unknown_rows → 422 `REPORT_UNKNOWN_CASES_CONFIRM_REQUIRED` 且 detail 含逐行警告、确认后成功（FR9.1.2/A2）；列模板不符 → `REPORT_IMPORT_TEMPLATE_MISMATCH`、超 10000 行 → `REPORT_IMPORT_TOO_LARGE`（FR9.1.1/A2）；编号格式/3 位零填充/999 进位/事务内分配断言（C-Q3）；**并发导入断言——同项目并发 N 次编号互不重复且游标行锁串行化**（A10/C-Q3）；直填与规则冲突 → verdict_conflict 警告且不阻塞、人工值不被覆盖（C-Q1 Assumptions）；单位不匹配 → pending + unit_mismatch 警告；抽取失败 → pending + judge_failed 警告、其余行正常（C-Q1）；Fail 行自动派生异常且 result_row_id UNIQUE（A9）；criteria_snapshot 落行可复现（AC9.3.1，A1）；解析经 F1 通道的禁绕过断言（AC1.6.1 复用）；audit `report.imported`（含引擎版本与警告统计）+ KPI `report.start` 断言（spec §5/FR10.3.1）；同步响应结构 `{report_id, report_no, stats, warnings[], pending_count}` 契约测试；xlsx 与 csv 双格式各跑通（FR9.1.1）；F4 report_gen 复用同一入口断言（A13）；权限 report.create 403 断言（FR10.5）
- **依赖**：T02、T03
- **粒度**：2 天

### T05 统计与图表（FR9.2.1–FR9.2.3、C-Q1、A3/假设③④⑦）

- **目标**：**全确定性（无 LLM，A3）**——`stats.py` 统计服务，口径固化 `caliber_version='v1'` 并随 stats 写入（FR9.2.3）：用例数=快照内被引用用例数；样本数=入库行数；通过率=Pass/(Pass+Fail)，**pending 不入分母、单列展示**（假设③）；按测试项目分组（分组键=用例挂接主需求 test_item，复用 F8 挂接数据；未挂接归「未分组」显式展示，假设④）；自动判定覆盖率=自动判定行数/总行数（排除人工直填，C-Q1）；口径说明文本随 caliber_version 固化渲染进「数据统计」节（FR9.2.3）。`charts.py` 图表预渲染：各测试项目通过率柱状图 + 失败分布图两类（假设⑦），matplotlib 服务端渲染 PNG（中文字体随镜像打包）→ MinIO，charts JSONB 记 `{type,title,enabled,file_key}`；`report_config.charts_enabled` 启停配置生效（FR9.2.2）；**UI 与导出共用同一 PNG（所见即所得，plan A6）**。`POST /api/v1/test-reports/{id}/stats/refresh` 显式重算（FR9.2.1，供批量判定后调用）；口径变更 = caliber_version 升版 + 新报告生效、历史报告不重算（对齐 C-Q1 不回溯原则，plan §3.2）。
- **涉及文件/模块**：`app/modules/report/stats/service.py`、`stats/charts.py`、`app/modules/report/api/stats.py`
- **完成标准**：统计口径单测——通过率分母排除 pending、pending 单列输出（假设③/FR9.2.1）；分组汇总正确且未挂接归「未分组」（假设④）；自动判定覆盖率排除人工直填（C-Q1）；`caliber_version='v1'` 固化入 stats 且口径说明文本可渲染进数据统计节（FR9.2.3）；图表两类 PNG 生成入 MinIO、charts JSONB 结构断言、启用/停用配置生效（FR9.2.2/假设⑦）；PNG 中文字体渲染冒烟（无豆腐块）；`stats/refresh` 重算结果与导入时点一致（幂等）；空数据（0 行）不除零断言；纯确定性架构测试（stats/charts 无 LLM/无检索依赖，A3）
- **依赖**：T04
- **粒度**：1 天

### T06 Pass-Fail 明细与待人工判定闭环（FR9.1.3、FR9.4.1、A8/假设⑥）

- **目标**：`GET /api/v1/test-reports/{id}/rows?verdict=&case_no=&page=&page_size=`——Pass-Fail 明细分页（与 FR9.4.1 明细节同源；verdict_source 可筛，抽取行可核对，plan §6 风险缓解）。`PATCH /api/v1/test-reports/{id}/rows/{row_id}`（body `{verdict: pass|fail, note?}`）——**待人工判定兜底闭环（FR9.1.3）**：更新 verdict + note → 同步重算 stats/anomalies 并随响应返回（stats/refresh 语义内聚，plan §1.2③）；pending 行存在时定版被拒的闸门字段以本闭环清零（A8）；判定冲突行的复核动作写 audit `anomaly.verdict.reviewed`（C-Q1 Assumptions）；APPROVED 报告行不可改（OBJECT_LOCKED，C-Q1 Assumptions 判定结果不可覆盖）。
- **涉及文件/模块**：`app/modules/report/api/rows.py`、`app/modules/report/import/validate.py`（冲突复核审计挂点）、`app/modules/report/service.py`（行更新→统计/异常重算编排）
- **完成标准**：rows 分页与 verdict/case_no/verdict_source 筛选契约测试（FR9.4.1/specs/README）；PATCH 人工判定 → verdict 更新 + stats 同步重算且响应含最新统计（FR9.1.3/plan §1.2③）；pending 行清零后异常与统计联动正确（A8 前置）；pending 行 PATCH 后定版闸门解除联动断言（A8）；冲突行复核写 audit `anomaly.verdict.reviewed` 断言（C-Q1 Assumptions）；APPROVED 报告行 PATCH → OBJECT_LOCKED 断言（C-Q1 Assumptions/FR10.2.4）；重算幂等（重复 PATCH 同值结果一致）；权限 report.row.judge 403 断言（FR10.5）
- **依赖**：T04、T05
- **粒度**：1 天

### T07 异常项分析：确定性四要素 + AI 整改建议 + 人工确认闸门（FR9.3.1–FR9.3.3、C-Q1、A4/A9）

- **目标**：`GET /api/v1/test-reports/{id}/anomalies`——异常清单（四要素：定位 {case_no, sample_no}、实测值 vs 判定标准（criteria_snapshot）、超限幅度 over_limit_pct、影响判定——导入时点已算，FR9.3.1）。`PATCH .../anomalies/{aid}`（`{owner_note?, owner_id?, impact?}`）——人工补充备注与责任归属（FR9.3.3）、影响判定可改（假设⑧）。`POST .../anomalies/{aid}/suggestion`——**[AI] 整改建议（异步 Celery `report` 队列，FR9.3.2/A4）**：RAG 召回知识库「历史质量问题」分类（F2 标签 quality/质量案例，经 F3 检索服务 + kb_version 快照，禁直查 chunks）→ LLMGateway 调 `f9.anomaly_suggestion` prompt（输入：异常四要素 + 召回片段含出处 + 输出要求 2–4 条可执行建议、逐条标注依据引用或显式「经验建议」、禁止编造检测数据，plan §4）→ 强制 JSON Schema `{"suggestions":[{"text","priority","basis":"kb|experience","kb_doc_ids"?}]}` → 落 ai_suggestion（model/prompt_version/kb_version/citations 全套审计字段内嵌，FR10.3.1）→ `suggestion_status='draft'`；kb_doc_ids 校验 ∈ 本次召回集合，非法引用降为 basis=experience（A5/plan §4 grounding③）。`POST .../suggestion/confirm`——人工确认（可携编辑后内容）→ `confirmed` + audit `anomaly.confirmed`；幂等（confirmed 后再 confirm 返回当前态，plan §3.2）；**未确认建议不进正文正式内容**（A4）。audit `anomaly.suggestion.generated`（模型/prompt/kb_version/citations）。KPI「异常项分析耗时」子段打点：suggestion 生成时点 → 该报告全部异常 confirmed 时点（spec §5）。body 重复触发 suggestion → 取消在途任务后重排（F4.5 语义，plan §3.2）。
- **涉及文件/模块**：`app/modules/report/anomaly/api.py`、`anomaly/suggestion.py`（RAG 召回 + LLMGateway + schema 校验 + kb 引用守卫）、`app/worker/tasks/report_suggestion.py`、`app/modules/rag/retrieval`（检索服务复用）
- **完成标准**：Fail 行四要素断言——定位/实测 vs criteria_snapshot/over_limit_pct（=delta_pct，与 AC9.3.1 预置答案一致）/影响判定（FR9.3.1/AC9.3.1/A9）；suggestion 异步任务 SSE `QUEUED→RUNNING(stage=suggest)→SUCCESS` 契约（specs/README）；落库断言——draft 态 + ai_suggestion 审计字段（model/model_version/prompt_id/prompt_version/kb_version/citations/generated_at）完备（FR10.3.1/A4）；kb_doc_ids ∉ 召回集 → 降级 experience 断言（A5）；未确认建议不出现在正文正式内容断言（A4，与 T08 联测）；confirm → confirmed + audit `anomaly.confirmed`、携编辑内容覆盖、重复 confirm 幂等（FR9.3.2/plan §3.2）；PATCH 备注与责任归属生效（FR9.3.3）；影响判定人工可改（假设⑧）；知识库无历史质量问题 → 全 experience 建议正常返回（C-Q1 兜底）；RAG 经 F3 检索服务、禁直查 chunks 的禁绕过断言（AC1.6.1 复用）；prompt 经注册表、无裸字符串断言（FR10.3.4）；异常项分析耗时子段打点可聚合（spec §5）；权限 report.anomaly.manage 403 断言（FR10.5）
- **依赖**：T04、T06
- **粒度**：2 天

### T08 报告正文生成：八节装配 + AI 结论草稿 + grounding 守卫（FR9.4.1、FR9.4.2、A4/A5）

- **目标**：`POST /api/v1/test-reports/{id}/body/generate`（异步 Celery `report` 队列 → task_id，SSE stage=generate）——**八节装配（FR9.4.1）**：概要/测试范围（case_set_ref 用例集引用）/数据统计（含口径说明 FR9.2.3）/图表（charts PNG）/Pass-Fail 明细/异常项分析（confirmed 项为正式内容 + draft 项显式标「待确认」不入结论依据，A4）/附件清单七节为确定性模板装配；结论节 = AI 草稿（FR9.4.2）——LLMGateway 调 `f9.report_conclusion` prompt（输入**仅** stats JSONB 序列化 + confirmed 异常摘要 + pending 计数，FR9.4.2 禁数据外信息；输出要求：结论段 + 关键发现列表、只能使用输入中出现的数值、pending>0 须显式声明，plan §4），强制 JSON Schema `{"conclusion_md","key_findings":[{"finding","stat_ref"}]}`，**schema 不含可计算字段新数值、stat_ref 只能引用输入 stats 键路径**（构造性 grounding，plan §4）。**grounding 数值守卫（A5）**：代码抽取结论中数值（百分比/计数）与 stats/anomalies 交叉核对 → 数据外数值带差异反馈重试 1 次 → 仍失败降级模板化结论（统计句式拼装，无 LLM）+ `conclusion_fallback=true`，不阻塞流程；stat_ref 非法键剔除该 finding。body JSONB 八节落库（ai_generated/fallback 标注）+ audit `body.generated`（prompt/model/kb_version，FR10.3.1）。`PATCH /api/v1/test-reports/{id}` body 各章节人工编辑（章节内容覆盖；APPROVED → OBJECT_LOCKED，A7）；整体 DRAFT + [AI] 标识（specs/README）。
- **涉及文件/模块**：`app/modules/report/body/assemble.py`（七节确定性装配）、`body/conclusion.py`（AI 结论 + 数值守卫 + 降级）、`app/worker/tasks/report_body_gen.py`、`app/modules/report/api/body.py`
- **完成标准**：八节装配完整性单测——八节齐全、章节顺序与 FR9.4.1 一致、图表启用配置生效、统计口径说明入 stats 节、测试范围含用例集引用（FR9.4.1/FR9.2.3/C-Q3）；异常项分析节只渲染 confirmed 为正式内容、draft 项标「待确认」且不入结论输入（A4，与 T07 联测）；结论 prompt 输入仅统计+异常摘要断言（FR9.4.2 禁数据外信息）；**grounding 守卫矩阵单测——结论含数据外数值 → 重试 1 次 → 降级模板化 + conclusion_fallback 标记；stat_ref 非法键剔除**（A5/FR9.4.2）；pending>0 时结论显式声明断言（plan §4）；SSE 事件序列契约（specs/README）；落库断言——body JSONB 八节 + ai_generated/fallback 标注 + audit `body.generated`（prompt/model/kb_version，FR10.3.1）；人工编辑章节覆盖生效且 APPROVED 后 OBJECT_LOCKED（FR9.4.2/A7）；重复触发 → 取消在途任务后重排（F4.5/plan §3.2）；LLM 以桩注入跑通全部降级路径（禁直连模型 SDK 断言，AC1.6.1 复用）；F4 report_gen 经同一入口发起断言（A13）
- **依赖**：T05、T07
- **粒度**：1.5 天

### T09 结论确认 + 状态机定版（FR9.4.2、FR9.4.3、spec §5、A4/A7/A8）

- **目标**：`POST /api/v1/test-reports/{id}/conclusion/confirm`——人工修改或明确确认结论（FR9.4.2）→ `conclusion_confirmed=true` + confirmed_by/at 留痕 + diff 摘要（plan §1.2⑤）。`POST /api/v1/test-reports/{id}/transition`（F10.2 通用端点，`{action: submit_review|approve, comment}`，comment 必填、权限=工程师+）——**approve 双重闸门（T01 钩子落地）**：① `conclusion_confirmed=false` → 409 `REPORT_CONCLUSION_NOT_CONFIRMED`（spec §5「结论章节未确认时定版操作被拒」，A4/A7）；② 存在 pending 判定行 → `REPORT_PENDING_VERDICT_EXISTS`（A8/假设⑥，宁可阻塞定版不可带未判定行进入正式体系）；通过后 DRAFT→IN_REVIEW→APPROVED → APPROVED 锁定（OBJECT_LOCKED、编辑被拒、修订 revision+1，FR10.2.4）+ audit `report.approved` + KPI `report.approve`。`GET /api/v1/test-reports/{id}/transitions` 转换历史。AI 无直写 APPROVED 通路（FR10.2.2）。
- **涉及文件/模块**：`app/modules/report/api/conclusion.py`、`app/modules/report/api/transition.py`（语义化包装）、`app/modules/platform/workflow/hooks.py`（approve 双钩子实现）
- **完成标准**：conclusion/confirm → conclusion_confirmed=true + who/when/diff 摘要留痕断言（FR9.4.2/plan §1.2⑤）；**结论未确认 → transition(approve) 409 `REPORT_CONCLUSION_NOT_CONFIRMED`（spec §5 硬断言）**；pending 未清零 → `REPORT_PENDING_VERDICT_EXISTS`（A8/假设⑥）；双闸门通过 → IN_REVIEW→APPROVED 成功且 comment 必填校验（FR10.2.1）；APPROVED 后编辑/行判定 → OBJECT_LOCKED、revision+1（FR10.2.4/C-Q1 Assumptions）；非法流转 → `INVALID_TRANSITION`；audit `report.approved` + KPI `report.approve` 断言（spec §5）；**AI 上下文调用 transition 被拒（AI 无直写 APPROVED 通路，FR10.2.2）**；转换历史端点契约测试；定版权限矩阵参数化断言（工程师+；与 FMEA 定版研发主管差异显式断言，FR10.5）
- **依赖**：T08
- **粒度**：1 天

### T10 报告导出：docxtpl 渲染 + DRAFT 水印 + 模板管理（FR9.4.3、FR9.5.1、FR9.5.2、C-Q2、A6/假设⑤）

- **目标**：`POST /api/v1/test-reports/{id}/export`（`{format: pdf|word}`，异步 Celery `report` 队列 → task_id，假设⑤）——docxtpl 渲染（占位符契约 C-Q2 冻结：`{{stats.*}}/{{charts.*}}/{{anomalies.*}}/{{conclusion}}/{{detail_rows}}/{{attachments}}`，八节即 FR9.4.1）；**未 APPROVED 叠加 "DRAFT" 水印 + [AI] 内容脚注（「AI 草稿」/「AI 生成，已经人工确认」，FR9.4.3/C-Q2 Assumptions）**；PDF 转换（转换器字体随镜像打包，plan §6）；MinIO file_key → `report_exports` 记录（谁/何时/模板版本/报告 revision/水印标志，FR9.5.1；历史导出不重渲染，C-Q2 Assumptions）；渲染/转换失败 → task FAILED + `REPORT_EXPORT_FAILED` 附原因（A6）；audit `report.exported` + KPI `report.export`（**report.start→report.export 耗时 = 验收 KPI ↓70% 分子链路**，spec §5）。`GET /api/v1/test-reports/{id}/exports` 导出记录列表。`GET /api/v1/test-reports/{id}/attachments` 附件清单：原始数据文件 file_key + 关联 FMEA/用例集引用（从 case_set_ref/import/linkage 反查装配，FR9.5.2）。模板管理（管理员）：`GET /api/v1/report-templates`、`POST /api/v1/report-templates`（上传 docxtpl，版本化留存 + audit `report.template.updated`，C-Q2；替换仅影响后续渲染，契约版本校验）。Word/PDF 双格式共用同一数据装配层（C-Q2）。
- **涉及文件/模块**：`app/modules/report/export/render.py`（docxtpl + 占位符装配 + 水印/脚注）、`export/pdf.py`（转换）、`export/service.py`（记录/审计/KPI）、`app/modules/report/api/export.py`、`app/modules/report/api/templates.py`、`app/worker/tasks/report_export.py`、内置默认模板资产（`app/modules/report/export/templates/default.docxtpl`）
- **完成标准**：占位符契约 schema 校验断言（装配数据覆盖全部冻结占位符，C-Q2）；**水印金标断言——APPROVED 前导出 PDF/Word 各一：DRAFT 水印 + 「AI 草稿」脚注；APPROVED 后：无水印 + 「AI 生成，已经人工确认」脚注**（FR9.4.3/C-Q2 Assumptions，F5/F6/F7 先例对齐）；导出记录断言——谁/何时/template_version/report_revision/watermarked（FR9.5.1）；模板替换后历史导出 file_key 不变不重渲染（C-Q2 Assumptions）；双格式内容一致性断言（八节齐全，共用装配层，C-Q2）；附件清单含原始数据文件 + FMEA/用例集引用（FR9.5.2，与 T11 联测）；渲染失败 → FAILED + `REPORT_EXPORT_FAILED`（A6）；audit `report.exported`（含模板版本/水印标志）+ KPI `report.export` + start→export 耗时可出具（spec §5/FR10.3.1）；模板上传版本化 + audit `report.template.updated` + 非 `report.template.manage` 角色 403（C-Q2/FR10.5）；PDF 字体渲染冒烟（中文无缺字）；SSE SUCCESS 后 file_key 可下载（specs/README）
- **依赖**：T08、T09
- **粒度**：1.5 天

### T11 后续联动：to-fmea / to-issues + 双向回链（FR9.6.1、FR9.6.2、AC9.6.1、A9）

- **目标**：`POST /api/v1/test-reports/{id}/to-fmea`（`{anomaly_ids[], fmea_id, fmea_revision?}`）——目标 FMEA 仅 DRAFT/IN_REVIEW 可写；APPROVED 需携 fmea_revision 开修订版本，否则 `REPORT_FMEA_NOT_EDITABLE`（A9/F7 修订机制）；经 F7 行服务写 `fmea_rows`：function（用例/测试项目）、failure_mode/effect（异常信息）、**source='report_anomaly'、source_ref={report_id, anomaly_id}**（F7 plan A12 预留契约，不新建 FMEA 侧表）、row_status='manual'、s/o/d 留空待 F7 打分 → 进入 F7 审核流；回填 anomaly.fmea_row_id；**AC9.6.1 由 FMEA 工作台列表按 source 筛选断言**。`POST /api/v1/test-reports/{id}/to-issues`（`{anomaly_ids[], classification_id, assignee_id?, due_date?}`）——经 platform objects 创建 Issue（**origin_type='report_anomaly'**，F10 plan 对象模型/F6.5 同一 Issue 模型）+ 分类必填（F2 质量问题分类 id，缺省 → `REPORT_CLASSIFICATION_REQUIRED`）+ 描述含异常快照与 report_no 引用（C-Q3）→ 回填 anomaly.issue_id。`GET /api/v1/test-reports/{id}/anomalies/{aid}/issue` 正向跳转（F6 plan A7 先例）。未选或所选异常无 Fail 依据 → `REPORT_NO_ANOMALIES_SELECTED`；幂等：anomaly 已有 fmea_row_id/issue_id → 跳过并计入响应逐条结果（部分成功语义，plan §3.2）。
- **涉及文件/模块**：`app/modules/report/linkage/fmea.py`、`linkage/issues.py`、`app/modules/report/api/linkage.py`、`app/modules/fmea/rows`（F7 行服务消费，source/source_ref 契约）、`app/modules/platform/objects/issues`（Issue 创建）
- **完成标准**：to-fmea 写入断言——fmea_rows 的 source='report_anomaly'/source_ref/function/failure_mode/effect/row_status/s-o-d 留空齐备（FR9.6.1/F7 plan A12）；**AC9.6.1 集成断言——FMEA 工作台列表按 source='report_anomaly' 筛选可见且带来源引用**；目标 FMEA APPROVED 无修订 → `REPORT_FMEA_NOT_EDITABLE`、携 fmea_revision → 走修订版本成功（A9/F7）；写入后进入 F7 审核流（row_status/审核状态断言）；anomaly.fmea_row_id 回填断言；to-issues → Issue 创建 origin_type='report_anomaly' + 分类写入 + 描述含异常快照与 report_no（FR9.6.2/C-Q3）；分类缺失 → `REPORT_CLASSIFICATION_REQUIRED`；anomaly.issue_id 回填 + issue 跳转端点可读（F6 plan A7 先例）；未选异常/无 Fail 依据 → `REPORT_NO_ANOMALIES_SELECTED`；**幂等断言——重复提交跳过已关联项、部分成功响应逐条结果**（plan §3.2）；联动物料进入 T10 附件清单反查（FR9.5.2 联测）；权限矩阵参数化断言（FR10.5）
- **依赖**：T07
- **粒度**：1.5 天

### T12 前端：页面21 报告列表 + 导入向导 + 数据状态卡 + 明细与异常分析卡（UI_GUIDE 页面21、FR9.1、FR9.2.1、FR9.3）

- **目标**：`pages/test/report/` 报告列表（report_no/external_report_no 非空优先展示，C-Q3；state 筛选）+ 导入向导（模板下载 → 上传 xlsx/csv → 未知行警告确认「忽略未知行」→ 同步结果 stats/warnings/pending_count 反馈，FR9.1.1/FR9.1.2/AC9.1.1）+ **数据状态卡**（样本/Pass/Fail/pending + 警告列表可展开逐行展示，UI 页面21）+ 明细表（Pass-Fail 分页、verdict/verdict_source 筛选、待人工判定行内编辑 verdict+note，FR9.1.3）+ **[AI] 异常分析卡**（定位/实测 vs 标准/超限幅度「超出判定阈值 N%」/影响判定 + [AI] 建议生成按钮 + SSE 进度 + 建议 draft/confirmed 态展示 + 确认按钮（可编辑后确认）+ 备注与责任归属编辑，FR9.3.1–FR9.3.3）+ 图表展示与启用配置（FR9.2.2）。所有 DRAFT/AI 产物带 [AI] 角标（specs/README）；操作入口按权限显隐（F10 plan A7）。
- **涉及文件/模块**：`apps/frontend/src/pages/test/report/*`（列表/导入向导/明细）、`features/report/*`（数据状态卡、警告列表、判定标准快照卡、异常项卡片、图表组件）
- **完成标准**：组件测试——导入向导模板下载→上传→警告列表→忽略未知行确认→结果反馈全流程（FR9.1.1/FR9.1.2/AC9.1.1）；数据状态卡与后端 stats/warnings 一致、警告可展开（UI 页面21/FR9.2.1）；待人工判定行编辑后统计卡即时刷新（FR9.1.3/T06 联动）；异常卡四要素渲染、超限幅度口径与后端一致（FR9.3.1/AC9.3.1 前端侧）；[AI] 建议生成 SSE 进度 + draft/confirmed 态 + 确认（可携编辑）流（FR9.3.2/ specs/README AI 语义）；备注与责任归属编辑保存（FR9.3.3）；图表启停配置生效（FR9.2.2/假设⑦）；external_report_no 优先展示（C-Q3）；按钮按权限显隐（report.create/report.row.judge/report.anomaly.manage，F10 plan A7）
- **依赖**：T04、T05、T06、T07（仅需 API 契约即可 mock 启动）
- **粒度**：1.5 天

### T13 前端：正文八节编辑器 + 定版/导出/联动交互 + 模板管理（UI_GUIDE 页面21、FR9.4、FR9.5、FR9.6、C-Q2）

- **目标**：正文编辑器按八节分块（确定性节可编辑、结论节 AI 草稿 + [AI] 标识 + 「修改或明确确认」确认流，FR9.4.1/FR9.4.2）+ 定版对话框（submit_review/approve + comment 必填 + 闸门错误 `REPORT_CONCLUSION_NOT_CONFIRMED`/`REPORT_PENDING_VERDICT_EXISTS` 明确提示引导，spec §5/A8）+ 状态流转展示（DRAFT→IN_REVIEW→APPROVED + 转换历史）+ **水印预览**（未 APPROVED 预览带 DRAFT 水印，FR9.4.3）+ 三动作按钮 **[生成正式报告][生成FMEA风险][创建问题单]**（UI 页面21）：导出对话框（pdf/word + 异步进度 + 导出记录列表含谁/何时/版本/水印标志，FR9.5.1）+ 联动对话框（to-fmea：选目标 FMEA + APPROVED 修订提示；to-issues：选质量问题分类（必填）/责任人/期限；部分成功逐条反馈，FR9.6.1/FR9.6.2）+ anomaly→fmea_row/issue 回链跳转（AC9.6.1 前端侧/F6 plan A7 先例）+ 附件清单展示（原始数据文件 + FMEA/用例集引用，FR9.5.2）+ 模板管理页（管理员：模板列表/上传替换/契约版本展示，C-Q2）。
- **涉及文件/模块**：`apps/frontend/src/pages/test/report/*`（正文编辑/预览导出/联动对话框）、`features/report/*`（八节编辑器、定版对话框、水印预览、联动对话框、导出记录列表、模板管理）
- **完成标准**：组件测试——八节分块编辑与章节覆盖保存、结论节 [AI] 标识与确认流（FR9.4.1/FR9.4.2）；结论未确认时定版按钮触发后端 409 并前端引导提示（spec §5）；pending 未清零提示引导（A8）；定版 comment 必填校验（FR10.2.1）；APPROVED 后编辑入口禁用 + 锁定标识（FR10.2.4）；水印预览随状态切换（FR9.4.3）；导出对话框双格式 + SSE 进度 + 导出记录渲染（FR9.5.1）；联动对话框选 FMEA/修订提示、选分类必填/责任人（FR9.6.1/FR9.6.2）；回链跳转可达（AC9.6.1 前端侧）；附件清单渲染（FR9.5.2）；模板管理仅管理员可见（C-Q2/report.template.manage）；全部按钮按权限显隐（F10 plan A7）
- **依赖**：T08、T09、T10、T11（仅需 API 契约即可 mock 启动）
- **粒度**：1.5 天

### T14 评测：AC9.3.1 超限计算金标 + AC9.1.1 集成金标 + 结论 grounding 评测（AC9.3.1、AC9.1.1、C-Q1、A5）

- **目标**：`evals/report_anomaly/` 离线评测（测试资产不入线上库、不走状态机）——① **AC9.3.1 金标场景固化（M4 硬门槛）**：预置含超限样本数据集 + 预置答案，离线断言 delta_pct 计算与预置答案一致（阈值型/区间型/边界用例/单位不匹配用例全覆盖，A3 纯函数直验，C-Q1 口径）；② **AC9.1.1 集成金标**：含 3 条未知 Case ID 文件 → 警告列表准确 + 其余行正常入库（FR9.1.2）；③ **结论 grounding 评测**：金标集（≥2 组统计+异常输入）断言数值守卫零漏报（结论数值 ⊆ 输入数据）+ 人工走查清单（结论覆盖 Pass/Fail 概况、异常、pending 声明的可用性，A5/FR9.4.2）；④ 建议质量人工走查清单：可执行性、依据正确性（kb 引用抽查）、采纳率观测口径（FR9.3.2）；⑤ 自动观测指标：conclusion_fallback 率、建议确认率、pending 率、自动判定覆盖率分布（plan §4 评测⑤）；⑥ prompt/模型版本变更触发 ①③ 回归（plan §4 评测⑥）；⑦ 评测报告版本化归档。
- **涉及文件/模块**：`evals/report_anomaly/golden_set_v1.json`、`evals/report_anomaly/run_eval.py`、`evals/report_anomaly/report_v1.md`
- **完成标准**：金标场景可重复运行且 AC9.3.1 判定落地——超限幅度计算与预置答案一致（阈值型/区间型/边界/单位不匹配全用例，**评测报告为准，M4 硬门槛**）；AC9.1.1 金标断言通过（警告准确 + 其余行入库）；grounding 评测数值守卫零漏报断言 + 人工走查清单随报告出具；建议质量走查清单与观测口径实现；四项自动观测指标统计口径实现；prompt/模型版本回归触发机制可用；评测脚本与报告版本化归档；金标集 JSON schema 与 plan §4 评测口径一致
- **依赖**：T03、T04、T07、T08
- **粒度**：1 天

### T15 端到端验收（覆盖 F9 全部 AC）

- **目标**：演示环境全链路验收：页面21 报告列表 → 导入向导（模板下载 → 上传含 3 条未知 Case ID 的 xlsx/csv → **AC9.1.1 走查：警告列表准确、忽略未知行后其余行正常入库**，FR9.1.1/FR9.1.2）→ 数据状态卡核对（样本/Pass/Fail/pending + 警告展开）→ 自动判定核对（三型 criteria 判定 + 正则抽取 + pending 兜底 + criteria_snapshot 可复现，FR9.1.3/C-Q1）→ **AC9.3.1 金标评测报告核对（超限幅度与预置答案一致：阈值型/区间型/边界/单位不匹配）** → 统计与图表核对（通过率口径 pending 不入分母、分组汇总、自动判定覆盖率、caliber 说明入数据统计节、两类图表 UI 与导出同源，FR9.2.1–FR9.2.3/C-Q1/假设③④⑦）→ 待人工判定闭环（行判定 → 统计重算，FR9.1.3/A8）→ 异常项分析（四要素 + [AI] 建议生成/确认 + 备注与责任归属，FR9.3.1–FR9.3.3）→ 正文生成（八节装配 + AI 结论 + 数值守卫降级演示 + 人工编辑，FR9.4.1/FR9.4.2/A5）→ **定版闸门走查：结论未确认 approve 被拒 → 确认后仍有 pending 被拒 → 双闸门通过 APPROVED + 锁定 + revision+1（spec §5/FR10.2.4/A8）** → **水印金标走查：APPROVED 前导出 PDF/Word 带 DRAFT 水印 + 「AI 草稿」脚注、APPROVED 后无水印（FR9.4.3/C-Q2 Assumptions）** → 导出记录核对（谁/何时/模板版本/revision，FR9.5.1）+ 附件清单核对（原始数据文件 + FMEA/用例集引用，FR9.5.2）→ 联动走查：[生成FMEA风险] → FMEA 工作台按 source='report_anomaly' 可见且带来源引用（**AC9.6.1**）、[创建问题单] → Issue origin_type='report_anomaly' + 分类必填 + 双向跳转（FR9.6.1/FR9.6.2）→ 编号核对（RB-{项目代号}-{年份}-{seq:03d}、external_report_no 优先展示，C-Q3）→ 审计事件全链导出核对（`report.imported/anomaly.suggestion.generated/anomaly.confirmed/anomaly.verdict.reviewed/body.generated/report.approved/report.exported/report.template.updated`，FR10.3.1 字段完备性）→ KPI 视图 `report.start→report.export` 耗时与异常项分析耗时子段出具（对照 F10.6.3 人工基线，达标判定联合进行，spec §5）→ 权限走查（导入/编辑/行判定/建议确认/定版/导出/联动 = 工程师+、模板管理 = 管理员、AI 无直写 APPROVED 通路）→ F4 report_gen 技能经同一入口复验（A13）→ 禁绕过断言（AC1.6.1 复用：禁自解析 xlsx/csv 必经 F1 通道、禁直连模型 SDK 必经 LLMGateway、禁直查 chunks 必经 F3 检索服务、worker 禁 import transition service）在 e2e 中复验。产出验收核对单逐项勾稽。
- **涉及文件/模块**：`apps/backend/tests/e2e/test_f9_acceptance.py`、F9 验收核对单（`specs/` 下 F9 验收记录）
- **完成标准**：以下 AC 全部通过——**AC9.1.1**（3 条未知 Case ID 警告列表准确且其余行正常入库）、**AC9.3.1**（超限幅度计算与预置答案一致，金标评测报告为准）、**AC9.6.1**（一键生成的 FMEA 行在 FMEA 工作台可见且带来源引用）；并以用例覆盖 FR9.1.1–FR9.1.3、FR9.2.1–FR9.2.3、FR9.3.1–FR9.3.3、FR9.4.1–FR9.4.3、FR9.5.1/FR9.5.2、FR9.6.1/FR9.6.2；`report.start→report.export` 耗时与异常项分析耗时子段数据可出具（KPI ↓70% 达标判定随 F10.6.3 基线联合进行）；报告可统计、可导出、可联动全链路（PHASE1_FEATURES F9 整体验收）；新增模块行覆盖率 ≥80%（全局规则）；禁绕过断言（AC1.6.1 复用）复验通过
- **依赖**：T05、T06、T07、T08、T09、T10、T11、T12、T13、T14
- **粒度**：1 天

---

## 任务依赖图

```text
T01 → T02 ─→ T03（判定引擎，纯确定性）─┐
            └──────────────────────────┴→ T04（导入管线）→ T05（统计图表）→ T06（行判定闭环）─┬→ T07（异常+AI建议）→ T08（正文+结论）→ T09（确认+定版）─┬→ T10（导出+模板）
                                                      │                                     │                                           └→ T11（to-fmea/to-issues，与 T10 并行）
                                                      │                                     └→ T07（异常线可自 T04 后并行推进）
可并行：T10 与 T11 在 T09 后并行（F9.5 ∥ F9.6）        │
T12（依赖 T04–T07 契约）─┐                            │
T13（依赖 T08–T11 契约）─┴→ T15                       │
T14（依赖 T03/T04/T07/T08）───────────────────────────┴────────────────────────────────────────────────────────────────────────────────────────→ T15
```

并行建议：T03（判定引擎纯函数）在 T02 后先行，为 T04 与 T14 金标铺路；T07 异常线在 T04 后即可推进（异常于导入时点派生），与 T05/T06 弱耦合、在 T08 处汇合；T10（导出）与 T11（联动）按里程碑 {F9.5 ∥ F9.6} 在 T09 后并行；T12/T13 前端仅需后端 API 契约即可 mock 启动；T14 金标集在 T03 判定引擎单测就绪后即可构建，不依赖前端。

---

## Breakdown 决策与假设（Clarifications / Assumptions）

- **[D1] 集成测试不单列任务**：同 F5–F8 [D1] 手法——AC9.1.1 未知行警告闭环、并发编号互斥、判定冲突警告不阻塞、单位不匹配 pending、suggestion SSE 与 confirm 幂等、grounding 守卫降级矩阵、定版双闸门拒绝、水印金标（PDF/Word 各一）、模板替换不重渲染、to-fmea/to-issues 幂等与部分成功、AC9.6.1 按 source 筛选、禁绕过（AC1.6.1 复用）、权限矩阵（5 角色 × 导入/编辑/行判定/建议确认/定版/导出/联动/模板管理参数化）等集成/架构测试**分散进 T03–T11 各自的完成标准**；F9 的跨模块风险点（判定零 LLM 可复现、AI 仅两处且都过人工闸门、结论数值守卫、pending 定版硬闸门、编号终身不变、导出物可复现）都已绑定到对应实现任务的验收里。
- **[D2] 判定引擎单列任务（T03）**：F9 与 F8 的 T05 不同——判定规则引擎是 AC9.3.1 金标的直接被测对象（plan A1/A3 纯函数直验），且被 T04 导入管线与 T14 评测双重复用，故从导入管线中独立成纯函数任务，保证「零 LLM、可复现、可审计」（C-Q1）有独立验收面。
- **[D3] 统计与导入分任务（T04/T05）**：导入管线（编号/校验/判定/落库）与统计图表（口径固化/matplotlib 渲染）在 plan §1.2①② 内聚但技术栈不同（IO 编排 vs 纯计算 + 图像渲染），拆分后 T05 可独立回归口径变更（caliber_version），并避免 T04 超 2 人日上限。
- **[D4] LLM 以桩起步**：同 F3/F5–F8 手法——两处 LLM（f9.anomaly_suggestion / f9.report_conclusion）经 LLMGateway 桩（确定性返回 + 可注入数据外数值/非法 stat_ref/非法 kb_doc_ids/schema 违例）跑通全部逻辑与降级路径（A5）；真实模型接入属部署联调，纳入 T14 跑分与 T15 验收，不单列任务。
- **[D5] AC9.3.1/AC9.1.1 金标以评测集预置**：线上数据冷启动不阻塞验收——T14 金标集预置含超限样本与未知 Case ID 的数据文件离线验证（plan §4 评测①②），T04/T06 集成测试提供全链路代码级保障，T15 双重复验。
- **[D6] KPI 耗时达标的基线依赖**：`report.start/report.approve/report.export` 与异常项分析耗时子段打点在 T01/T04/T07/T10 落地，但 ↓70% 达标判定依赖 F10.6.3 人工基线测量（M1 交付项）——T15 仅核对耗时数据可出具，达标判定与 F10 联合进行，不作为 F9 单独阻塞项（同 F7/F8 [D6]）。
- **[D7] 任务粒度校验**：拆解结果 15 条 = 上限内，plan 粒度合格（无超 2 人日任务，T04/T07 为 2 天已达上限），无需回改 plan；若实现期 T04（导入管线）超期，优先按 drafts+numbering / parser+validate / 异常派生 再拆分而非新增顶层任务；T07 同理按 anomaly 确定性线 / suggestion AI 线拆分。
- **[D8] clarifications 与 plan 假设全文有效、逐条落位**：C-Q1（criteria_structured 三型 + AND 语义 + 优先级 + 正则兜底 + delta_pct 分支公式 + 引擎版本化不回溯 + 覆盖率口径 + 冲突警告）→ T01/T02/T03/T04/T06/T14/T15；C-Q2（内置默认模板 + 占位符契约冻结 + 实施期替换版本化 + PNG 注入 + 双格式共用装配层 + 历史导出不重渲染 + [AI] 脚注）→ T01/T02/T08/T10/T13/T15；C-Q3（RB-{项目代号}-{年份}-{seq:03d} + 事务内分配终身不变作废不回收 + external_report_no 优先展示）→ T01/T02/T04/T10/T11/T12/T15；plan 假设①（导入同步 + ≤10000 行）→ T01/T04、假设②（草稿即报告对象，report_id 外键）→ T02/T04、假设③（pending 不入通过率分母）→ T05/T12/T15、假设④（分组键=挂接主需求 test_item + 未分组显式）→ T02/T05、假设⑤（导出异步 Celery）→ T01/T10、假设⑥（pending 清零定版硬闸门）→ T01/T06/T09/T15、假设⑦（图表两类固定 + 启停配置）→ T01/T05/T12、假设⑧（影响判定确定性文案 + 人工可改）→ T03/T04/T07。
