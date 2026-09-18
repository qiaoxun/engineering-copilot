# F5 规格书智能对比 — 任务清单（Tasks）

| | |
| ---- | ---- |
| Feature | F5-spec-comparison |
| 输入 | specs/F5-spec-comparison.md、specs/F5-spec-comparison.clarifications.md（C-Q1–Q3）、specs/F5-spec-comparison.plan.md（冲突时以后两者为准）、specs/README.md |
| 关联 | specs/F1-document-parsing.tasks.md（统一解析模型/定位端点为前置）、specs/F10-platform-governance.tasks.md（M1 骨架为前置）、specs/F4-ai-chat.tasks.md（spec_diff 技能复用 `POST /runs` 入口） |
| 阶段 | speckit-tasks |
| 粒度约定 | 每条任务 0.5–2 人日；超过 2 人日须继续拆分 |
| 前置 | F10 M1 骨架（LLMGateway/prompt_registry/审计通道/require_perm/kpi_events/workflow 通用 transition/KPI SQL 视图）、F1.6 统一解析模型读服务（`list_parse_versions()`/parse 模型读取/`GET .../parse/blocks/{block_id}/source` 定位端点）、F1 参数字典 `param_dict`（synonyms/si_unit，A3 同源复用） |

> 依赖列格式：依赖的任务号。编号即执行顺序（可并行：T03/T04 相互独立；T07/T08/T09/T10 在 T05 后可并行；T12/T13 前端可与后端 T07–T11 并行）。

---

## 任务清单

### T01 F5 接入点骨架：审计事件定义、状态机接线、权限点、KPI 埋点

- **目标**：一次性定义 F5 挂接 F10 的接入点——① 审计事件常量：`specdiff.run / mapping.confirmed / mapping.disabled / level.overridden / run.confirmed / specdiff.mapping_unapplied / levelrule.updated`（spec §5；`specdiff.run` 字段契约：A/B 文档与版本、实测 model/model_version、三个 prompt_id 版本、`mapping_library_version`、`level_rules_version`，即「模型与 prompt 版本可追溯」要求，plan §4 审计接入）；② 状态机接线：注册 `spec_diff_run`（`DRAFT→APPROVED`，定版权限=研发主管、comment 必填）与 `level_rules`（`DRAFT→APPROVED`，C-Q1）进 F10 workflow 配置；③ 权限点清单 `specdiff.run.start / specdiff.run.edit / specdiff.mapping.confirm / specdiff.level.override / specdiff.run.confirm / specdiff.levelrule.manage / specdiff.mapping.disable`（plan §3.2，映射库为部署域全局共享、无 project_id，C-Q3）；④ KPI 埋点契约：`specdiff.start` / `specdiff.export`（duration_ms，`start→export` 耗时对照人工基线 ↓80%，spec §5 KPI）注册进 F10 KPI SQL 视图（FR10.6.1）。同时登记错误码（`SPEC_DIFF_DOC_NOT_CONFIRMED / SPEC_DIFF_PARSE_VERSION_NOT_FOUND / SPEC_DIFF_RUN_LOCKED / SPEC_DIFF_MAPPING_DUPLICATE / SPEC_DIFF_SUMMARY_UNAVAILABLE`，plan §3.2）与 prompt 注册表条目骨架 `f5.mapping_judge / f5.level_suggest / f5.diff_summary`（FR10.3.4，禁裸字符串）。
- **涉及文件/模块**：`apps/backend/app/modules/platform/audit/events.py`（F5 事件段追加）、`app/modules/specdiff/constants.py`（权限点/错误码）、`app/modules/platform/workflow/configs.py`（spec_diff_run 与 level_rules 注册）、`app/modules/platform/kpi/views.sql`（KPI 视图段）、`app/modules/platform/prompts/registry.py`（f5.* 条目）
- **完成标准**：事件/权限/错误码/prompt 常量表与 spec §5、plan §3.2/§4 逐条对应并有单元断言；workflow 注册后 `spec_diff_run` 可经 F10 通用 transition 端点走 DRAFT→APPROVED（研发主管 + comment 必填断言，FR10.2）；`level_rules` 仅 APPROVED 生效语义在常量层可判定（C-Q1）；两个 KPI 事件写入 kpi_events 后可被 SQL 视图聚合（`specdiff.start→export` 耗时查询冒烟）；审计命名全部符合 `<domain>.<verb>`（FR10.3.3）
- **依赖**：无（复用 F10 M1 已有常量骨架）
- **粒度**：0.5 天

### T02 F5 数据模型 + 迁移

- **目标**：新表——`spec_diff_run`（继承 BaseEntity：state DRAFT→APPROVED、revision、audit_ref；另含 doc_a/b_id+parse_version、template_family、`mapping_library_version`、`level_rules_version`、summary JSONB、status 任务生命周期 `QUEUED/RUNNING/SUCCESS/FAILED` 与 state 分离、fail_reason、task_id、stats JSONB，plan §2.1）；`spec_diff_rows`（param_key/display_name、value_a/b JSONB `{value_raw,value_norm,unit,unit_si}`、delta_pct、diff_type、level、level_source、ai_level_suggestion、level_override、mapping_source、applied_mapping_id、locate_a/b JSONB，索引 `(run_id,level)/(run_id,diff_type)/(run_id,param_key)`，plan §2.2）；`field_mappings`（**不继承 BaseEntity、无 project_id**，key_a/key_b、scope 枚举 `{global,template_family}`、status `active/disabled`、confirmed_by/at、source_run_id、库级单调 version，`UNIQUE(key_a,key_b,scope,template_family)`，plan §2.3/A5）；`spec_diff_mapping_suggestions`（run 内建议区，embed_score、llm_judgment、status `SUGGESTED/CONFIRMED/REJECTED`、resolved_by/at、resulting_mapping_id，plan §2.3）；`specdiff_key_embeddings`（pgvector 键嵌入缓存，normalized_key 主键，plan §2.3）；`level_rules`（version、rules JSONB、state、approved_by/at，C-Q1，plan §2.4）。Alembic 迁移 + pgvector 扩展确认。
- **涉及文件/模块**：`app/modules/specdiff/models.py`、`alembic/versions/*`
- **完成标准**：迁移可上下执行；`spec_diff_run` BaseEntity 公共列齐备（FR10.1.3）；field_mappings 无 project_id 且 UNIQUE 防重生效断言（A5/C-Q3）；rows 三索引存在性迁移测试；status 与 state 两列语义独立（任务状态 ≠ 定版状态，plan §2.1 注）；disabled 映射保留历史不物理删（FR5.6.1）
- **依赖**：T01
- **粒度**：1.5 天

### T03 确定性 Diff 引擎：键归一化 → 对齐 → 差异类型 → Δ% → 规则分级（FR5.1.2/FR5.1.3/FR5.3.1）

- **目标**：纯函数模块（无 LLM、无 IO，A1）——`normalize.py`：小写/全半角折叠/空白剔除/单位写法折叠（Ah/A·h/aH 等价、mAh→A·h 数量级换算、℃/K），复用 F1 `param_dict` synonyms/si_unit，无字典命中键按字符归一（A3）；`align.py`：归一化键精确匹配对齐 + 按 scope 过滤应用映射库（template_family 优先回落 global，C-Q3/A5）→ 产出对齐行（mapping_source=exact|library）与未匹配集（仅A有/仅B有）；`grading.py`：level_rules APPROVED 子集规则匹配（keys[]/pattern → 🔴/🟠），未命中/仅单方存在默认 🟡，线上无 APPROVED 规则表时全部 🟡 兜底（C-Q1 Assumptions/A6），优先级 human>rule>ai>default_yellow；Δ% 计算基于 `unit_si` 归一后数值（0 值、负值、区间型不计算），单位写法不同但语义等价归 UNIT_DIFF 而非 VALUE_DIFF（plan §6 单位陷阱缓解）。
- **涉及文件/模块**：`app/modules/specdiff/diff_engine/normalize.py`、`align.py`、`grading.py`
- **完成标准**：归一化矩阵单测（大小写/全半角/空白/Ah 系/mAh→A·h/℃·K，FR5.1.2）；Δ% 单测（0 值/负值/区间 NULL，FR5.1.3）；diff_type 四类穷举断言；分级引擎单测（红橙黄命中、仅单方默认 🟡、无 APPROVED 规则表兜底全 🟡、优先级序，FR5.3.1/C-Q1）；scope 命中优先回落 global 单测（C-Q3）；100Ah vs 100mAh 误判一致场景反例单测（plan §6）
- **依赖**：T02
- **粒度**：2 天

### T04 映射召回与建议生成：嵌入召回 + LLM 同义判定（FR5.2.1）

- **目标**：未匹配键的候选生成通路——归一化键经 LLMGateway embedding → `specdiff_key_embeddings` 缓存读写 → pgvector 余弦相似度召回对方文档未匹配键 top3（候选不足按实际数量，plan §4）→ 以 `f5.mapping_judge` prompt（输入候选键对 + 双侧 display_name/单位/样本值上下文）批量 LLM 同义判定 → 输出写入 `spec_diff_mapping_suggestions`（SUGGESTED 态，embed_score + `{is_synonym,confidence,reason}`，FR5.2.1）；结构化输出 JSON Schema 强制（Pydantic 校验，失败重试 1 次后该候选放弃，plan §4）；判定为非同义的候选不产生建议。**本任务只产出建议，不含任何 `field_mappings` 写入路径**（A4：AI 建议永不自动入库，FR5.6.2）。
- **涉及文件/模块**：`app/modules/specdiff/mapping/recall.py`、`judge.py`、`app/modules/specdiff/mapping/embeddings.py`（缓存）
- **完成标准**：top3 召回 + 候选不足降级单测（FR5.2.1）；LLM 桩驱动 is_synonym true/false 分支落库断言（建议仅入 suggestions 表）；schema 校验失败重试后放弃该候选、不中断管线（plan §4 降级）；嵌入缓存命中不再调用 embedding 模型断言；**架构测试：mapping/ 模块 import 图中不存在 field_mappings 写入依赖**（A4 禁令，防 AI 直写映射库）
- **依赖**：T02
- **粒度**：1.5 天

### T05 对比管线编排：run 发起 → Celery 任务 → 分阶段执行 → SSE（FR5.1.1–FR5.1.3）

- **目标**：`POST /api/v1/spec-diff/runs` 同步校验（A/B 均 `PARSE_CONFIRMED` 且解析 status=SUCCESS、项目可见性、parse_version 合法——失败同步 4xx 不入队，plan §3.2）→ 创建 run（DRAFT/QUEUED）+ 记录 `mapping_library_version`/`level_rules_version` 快照 → 投递 Celery `specdiff` 队列返回 `{run_id, task_id}`；Celery 任务按 plan §1.2 管线编排：读 F1 统一解析模型（含 override 合并视图，**禁自解析**，FR1.6.2/A2）→ T03 归一化对齐 → 未匹配键走 T04 召回 + 映射库自动应用（命中行标"已按历史映射对齐"，FR5.2.4）→ 规则分级（T03 grading）→ stats 汇总 → 状态 SUCCESS/FAILED + fail_reason；SSE 经 `GET /api/v1/tasks/{id}/events` 推送 `QUEUED→RUNNING(stage=align|mapping|grading|summary, progress)→SUCCESS/FAILED`（specs/README 异步约定）；emit 审计 `specdiff.run` + KPI `specdiff.start`。
- **涉及文件/模块**：`app/modules/specdiff/api/runs.py`（发起）、`app/modules/specdiff/run/pipeline.py`、`app/worker/tasks/specdiff_run.py`、`app/modules/documents/`（进程内只读读服务复用）
- **完成标准**：未确认文档发起返回 `SPEC_DIFF_DOC_NOT_CONFIRMED` 且无 run 记录（FR5.1.1）；非法版本返回 `SPEC_DIFF_PARSE_VERSION_NOT_FOUND`；fixtures 双文档端到端 SUCCESS 且行结构断言（value_raw 保留原文、diff_type、Δ%、locate 含 page/block_id，FR5.1.3/FR5.1.4）；stats 汇总与行数据一致；SSE 事件序列契约测试（QUEUED→RUNNING 各 stage→SUCCESS）；**禁绕过测试：import-linter 断言 specdiff 模块不直读 MinIO 原件/不自建解析，仅消费统一解析模型桩文档**（AC1.6.1 复用/A2）；管线失败 → FAILED + fail_reason 可读且 run 可重试
- **依赖**：T03、T04
- **粒度**：2 天

### T06 Runs/Rows 查询 API + 行级定位代理（FR5.1.4）

- **目标**：`GET /runs`（分页 `{items,total,page}`，筛选项目/状态/模板族）、`GET /runs/{id}`（总览 + stats + summary，[AI] 标识字段）、`GET /runs/{id}/rows`（`?level=&diff_type=&mapping_source=&page=&page_size=`，FR5.1.3 输出行结构 + spec §4 筛选）；`GET /runs/{id}/rows/{row_id}/locate/{side=a|b}` → 内部转发 F1 定位端点返回 `{doc_id, block_id, page, bbox, source_url}`（A2，不修改 F1 对外 API）；`GET /spec-diff/documents/{doc_id}/parse-versions` 代理 documents 读服务 `list_parse_versions()` 供前端 A/B 版本下拉（A2）。
- **涉及文件/模块**：`app/modules/specdiff/api/runs.py`（查询）、`app/modules/specdiff/api/locate.py`、`app/modules/specdiff/api/documents_proxy.py`
- **完成标准**：rows 四维筛选 + 分页信封契约测试；行 JSON 字段完备性对照 FR5.1.3 逐项断言；locate 返回结构与 F1 端点契约一致（page/bbox/source_url，FR5.1.4）；parse-versions 下拉数据与 F1 版本列表一致（A2）；无项目可见性权限的 run 404/403（权限矩阵参数化用例）
- **依赖**：T05
- **粒度**：1 天

### T07 映射确认闭环：建议确认/拒绝 → 入库 → 自动应用 → 解除/停用（FR5.2.2–FR5.2.4、AC5.2.1、FR5.6.1）

- **目标**：`GET /runs/{id}/mappings`（建议区三分态）；`POST /runs/{id}/mappings/confirm` 批量 `{decisions:[{suggestion_id, action, scope?, template_family?}]}`——confirm 项写入 `field_mappings`（唯一写入路径，confirmed_by/at + source_run_id 溯源 + 库 version+1）+ 审计 `mapping.confirmed`；reject 项置 REJECTED；与库内 active 条目冲突返回 `SPEC_DIFF_MAPPING_DUPLICATE`；逐条返回成功/失败（部分成功语义，plan §5 API 契约）；`POST /runs/{id}/rows/{row_id}/unlink-mapping` 解除历史映射对齐（行回落 仅A有/仅B有 + audit `specdiff.mapping_unapplied`，FR5.2.4）；`GET /spec-diff/mappings`（`?key=&scope=&template_family=&status=`，含确认人与时间）+ `POST /mappings/{id}/disable`（audit `mapping.disabled`，FR5.6.1）。
- **涉及文件/模块**：`app/modules/specdiff/api/mappings.py`、`app/modules/specdiff/mapping/service.py`
- **完成标准**：**AC5.2.1 集成闭环**——第一次跨模板对比→建议区产出→批量确认（含 reject 分支）→field_mapping 落库含 confirmed_by/at→第二次同模板族对比自动应用且行上 `mapping_source=library`；解除对齐后行回落仅A有/仅B有且审计留痕（FR5.2.4）；停用后第三次对比不再应用（FR5.6.1）；DUPLICATE/部分成功语义断言；**集成测试断言确认是 field_mapping 唯一写入路径**（A4/FR5.6.2）；APPROVED run 上的确认/解除操作返回 `SPEC_DIFF_RUN_LOCKED`（spec §5 定版锁定）
- **依赖**：T04、T05、T06
- **粒度**：1.5 天

### T08 分级规则表 + LLM 等级建议 + 人工覆盖（FR5.3.1–FR5.3.3、C-Q1）

- **目标**：`GET/POST/PUT /spec-diff/level-rules`（版本化 CRUD，变更 audit `levelrule.updated`）+ `POST /level-rules/{id}/transition`（DRAFT→APPROVED，研发主管，复用 F10 workflow）；**初版规则表数据起草**：按 GB 38031/IEC 62660 起草安全项 ≥30（🔴）+ 关键性能项 ≥40（🟠），DRAFT 态导入 fixtures/seed（C-Q1）；`f5.level_suggest` prompt 对差异行产出 `{level, reason}` 建议写入 `ai_level_suggestion`——仅标注 level_source=ai **不改生效等级**（FR5.3.2，schema 校验失败重试 1 次后不产出建议）；`POST /runs/{id}/rows/{row_id}/level` 人工覆盖（写 level_override `{from,to,by,at,comment}` + 审计 `level.overridden`，FR5.3.3，APPROVED 后 RUN_LOCKED）。
- **涉及文件/模块**：`app/modules/specdiff/levelrules/api.py`、`service.py`、`app/modules/specdiff/summary/`（等级建议调用点或独立 `grading/suggest.py`）、`evals/spec_diff/level_rules_seed_v1.json`（初版规则数据）
- **完成标准**：规则 CRUD + transition 权限矩阵（工程师定版 403、研发主管成功，C-Q1）；seed 数据量断言（🔴≥30、🟠≥40）；无 APPROVED 版本时管线兜底全 🟡 + LLM 建议不阻塞（C-Q1 Assumptions，端到端断言）；AI 建议仅落 ai_level_suggestion、生效 level 不变的断言（FR5.3.2）；人工覆盖后 level_source=human + 审计事件含 who/from/to（FR5.3.3）；APPROVED 后覆盖请求返回 RUN_LOCKED
- **依赖**：T03、T05、T01
- **粒度**：1.5 天

### T09 AI 差异总结 + grounding 校验（FR5.4）

- **目标**：管线 summary 阶段以 `f5.diff_summary` prompt（输入**仅** Diff 行结构化数据 + 等级分布；系统指令禁止引入外部知识，FR5.4.2）生成 `{summary_schema_version, overall_conclusion, top_diffs[], risk_notes[]}` 写入 run.summary；**确定性 grounding 校验（代码非 prompt，plan §4）**：总结中每个参数键必须存在于该 run diff 行集合、每个数值/百分比与对应行 value/delta_pct 归一后匹配，失败句剔除 + warning；schema 校验失败重试 1 次后 summary 置 NULL + `SPEC_DIFF_SUMMARY_UNAVAILABLE` warning，**不阻塞 Diff 结果**（FR5.4.1、plan §4 降级）；总结为草稿性质随 run 走 F10.2 定版（A7），UI [AI] 标识由 API 返回结构支持。
- **涉及文件/模块**：`app/modules/specdiff/summary/generator.py`、`grounding.py`、`app/worker/tasks/specdiff_run.py`（summary 阶段接线）
- **完成标准**：grounding 校验器单测——构造注入外部数值/外部标准的总结断言被剔除并记 warning（FR5.4.2）；合法总结入库为草稿态、字段结构符合 FR5.4.1（总体结论/Top差异/风险提示）；mock LLM 失败 → run 仍 SUCCESS、summary NULL + 错误码可读、行数据照常可读（plan §3.2）；"循环寿命 500 vs 800 次 ↓37.5%" 类样例通过校验的正例断言
- **依赖**：T05
- **粒度**：1.5 天

### T10 结论定版状态机接线（F10.2、spec §5）

- **目标**：`POST /runs/{id}/confirm` → F10 通用 transition（DRAFT→APPROVED，研发主管，comment 必填）→ 审计 `run.confirmed`（含 who/when/comment）；APPROVED 后行级/映射级写操作（level 覆盖、unlink、映射确认）统一返回 `SPEC_DIFF_RUN_LOCKED`（spec §5「定版后差异分级锁定」，A7）；修订走 revision 新 run 的语义验证（BaseEntity revision）。
- **涉及文件/模块**：`app/modules/specdiff/api/runs.py`（confirm）、`app/modules/specdiff/run/locks.py`（锁定谓词，供 T07/T08 复用）
- **完成标准**：工程师定版 403、研发主管缺 comment 4xx、成功路径审计 `run.confirmed` 含 who/when（集成测试）；APPROVED 后 level/unlink/mapping confirm 三类操作全部 RUN_LOCKED；锁定谓词为单一实现、三处端点共用（防绕过）；run.state 与 status 在定版前后各自正确（plan §2.1 两态分离）
- **依赖**：T05、T07、T08
- **粒度**：0.5 天

### T11 导出：Excel/PDF 异步生成 + 水印 + KPI 打点（FR5.5）

- **目标**：`POST /runs/{id}/export`（`{format: excel|pdf}` → task_id，Celery `specdiff` 队列，A8）——Excel（openpyxl 三 Sheet：Sheet1 差异明细含等级/偏差/来源页码、Sheet2 映射关系、Sheet3 AI 总结）与 PDF（同内容排版）；产物写 MinIO 返回预签名 URL；PDF 水印按 **run.state 定版时点**注入（DRAFT 加"草稿"水印、APPROVED 无水印，FR5.5.2/A8）；`GET /runs/{id}/exports` 导出历史；SSE stage=export；KPI `specdiff.export` 打点（与 `specdiff.start` 构成 `start→export` 耗时，spec §5）。
- **涉及文件/模块**：`app/modules/specdiff/export/excel.py`、`pdf.py`、`app/modules/specdiff/api/export.py`、`app/worker/tasks/specdiff_export.py`
- **完成标准**：Excel 三 Sheet 内容与行数据一致性集成测试（FR5.5.1，含等级/Δ%/页码列）；DRAFT 态 PDF 含水印、APPROVED 后无水印断言（FR5.5.2，以定版时点为准：定版后发起的导出无水印）；导出走异步任务、SSE 可见 export stage、产物预签名 URL 可下载；`specdiff.export` 入 kpi_events 且 SQL 视图可算出 `start→export` 耗时（KPI 验收数据源，spec §5）
- **依赖**：T06、T07、T09
- **粒度**：1.5 天

### T12 前端：对比发起页 + 差异结果页（UI_GUIDE 页面13）

- **目标**：`pages/specdiff` 发起页——A/B 文档选择（限 PARSE_CONFIRMED 文档）+ 各自解析版本下拉（`/parse-versions` 代理）+ template_family 手动选择（建议值来自 F1 模板识别元数据，C-Q3）+ 发起后任务进度条（SSE stage 对齐/映射/分级/总结）；`pages/specdiff/result` 结果页——三栏参数对比表（参数/A值/B值/差异）+ 等级色标 🔴🟠🟡 与等级/类型/映射来源筛选 + Δ% 列 + 仅A有/仅B有显式呈现（plan §6 不静默丢弃）+ [AI] 总结卡（[AI] 草稿标识 + 定版按钮按权限显隐）+ 定版确认流（comment 必填弹窗）+ 定版后锁定提示；`features/diff-viewer`——参数名点击 → 经 locate 端点在 A/B 原文视图高亮（复用 F1 parse-viewer 定位组件，FR5.1.4）。
- **涉及文件/模块**：`apps/frontend/src/pages/specdiff/*`、`pages/specdiff/result/*`、`features/diff-viewer/*`
- **完成标准**：组件测试——发起表单校验（未确认文档不可选，FR5.1.1）；SSE 进度按 stage 更新；三栏表渲染等级色标与 Δ%、四类 diff_type + 三种映射来源筛选正确（FR5.1.3）；参数名点击触发 A/B 原文高亮（FR5.1.4）；[AI] 标识出现在总结/映射理由/AI 等级处（specs/README AI 语义）；无定版权限用户不显示定版按钮（权限隐藏）
- **依赖**：T06、T10
- **粒度**：2 天

### T13 前端：映射确认区 + 映射库管理页 + 分级操作（UI_GUIDE 页面13）

- **目标**：结果页内独立「映射确认区」面板——建议逐条展示（键对 + embed_score + LLM 理由带 [AI] 标识 + 置信度）+ 批量/逐条 确认（选 scope/template_family）/拒绝（FR5.2.2）；已对齐行「已按历史映射对齐」标注 + 解除对齐按钮（FR5.2.4）；行级分级覆盖操作（等级下拉 + comment，显示 AI 建议等级与理由标注"AI建议"，FR5.3.2/5.3.3）；`pages/specdiff/mappings` 映射库管理页——按参数/模板族/状态查询、确认人与时间展示、停用操作（FR5.6.1）；分级规则表管理入口（列表/版本/状态/定版，研发主管可见，C-Q1）。
- **涉及文件/模块**：`apps/frontend/src/pages/specdiff/result/mapping-panel/*`、`pages/specdiff/mappings/*`、`pages/specdiff/levelrules/*`
- **完成标准**：组件测试——建议逐条确认/拒绝调用批量端点且 UI 态翻转（FR5.2.2）；确认后行出现"已按历史映射对齐"标注（AC5.2.1 前端侧）；解除对齐带确认弹窗且成功后行回落仅A有/仅B有（FR5.2.4）；人工覆盖写入 comment 且 AI 建议带标识不可直接生效（FR5.3.2/5.3.3）；映射库页查询/停用/确认人时间齐备（FR5.6.1）；RUN_LOCKED 错误码触发 UI 锁定提示；无 `specdiff.mapping.confirm` 权限时确认区只读
- **依赖**：T07、T08、T12
- **粒度**：2 天

### T14 评测：标注集装载与全管线跑分（AC5.1.1、C-Q2、A10）

- **目标**：`evals/spec_diff/` 离线评测（独立于线上埋点，A10）——标注集构建：3 组真实规格书对（≥1 同模板 + ≥2 跨模板，优先取自 F1 golden_set_v1 已确认解析产出，C-Q2 Assumptions）、≥180 条字段级差异、双人标注 + 分歧仲裁（统一标注模板）；评测脚本跑全管线输出——**差异召回率（≥95%，M3 硬门槛；跨模板组按"人工确认映射后"口径统计，C-Q2）**、映射建议召回率（≥90%，观测）、精确率、AI 等级采纳率（观测）；分同模板/跨模板分项报表 + 报告版本化归档；规则表/prompt/模型变更触发回归的执行说明。
- **涉及文件/模块**：`evals/spec_diff/golden_set_specdiff_v1.json`、`evals/spec_diff/run_eval.py`、`evals/spec_diff/report_v1.md`
- **完成标准**：评测脚本对标注集可重复运行并输出四指标 + 分项报表；召回率 ≥95% 判定逻辑落地（含跨模板"确认映射后"口径，AC5.1.1/C-Q2）；映射建议召回率 ≥90% 统计口径实现（观测，C-Q2）；内部自建标注集先跑通管线，客户标注延迟不阻塞（C-Q2 Assumptions）；标注集 JSON schema 与标注模板一致
- **依赖**：T05、T07、T08、T09
- **粒度**：2 天

### T15 端到端验收（覆盖 F5 全部 AC）

- **目标**：演示环境全链路验收：选两份 PARSE_CONFIRMED 文档（同模板 + 跨模板各一组）发起对比 → SSE 各阶段进度 → 结果页三栏差异表/等级色标/Δ%/定位跳转原文高亮（FR5.1.1–FR5.1.4）→ 跨模板组映射建议逐条确认（[AI] 理由）→ **第二次同模板族对比自动应用且行上可见标注（AC5.2.1）** → 解除对齐回落并审计 → LLM 等级建议仅"AI建议"标注 → 人工覆盖入审计 → 规则表 DRAFT 导入→研发主管 APPROVED→分级生效 → 定版（研发主管 comment）→ 定版后编辑 RUN_LOCKED → DRAFT 导出 PDF 带"草稿"水印 → APPROVED 后导出无水印、Excel 三 Sheet → 映射库管理页查询/停用 → 审计事件全链导出核对（`specdiff.run/mapping.confirmed/mapping.disabled/level.overridden/run.confirmed/levelrule.updated`）→ KPI 视图 `specdiff.start→export` 耗时出具（对照 F10.6 人工基线验 ↓80%）→ 评测报告达标核对 → 私有化核对（LLM/embedding 经 LLMGateway 本地化配置，AI 生成物全部 DRAFT 人工确认，无 AI 直写 APPROVED 路径）。产出验收核对单逐项勾稽。
- **涉及文件/模块**：`apps/backend/tests/e2e/test_f5_acceptance.py`、F5 验收核对单（`specs/` 下 F5 验收记录）
- **完成标准**：以下 AC 全部通过——**AC5.1.1**（标注集差异召回率 ≥95%，评测报告为准）、**AC5.2.1**（第二次同模板族对比已确认映射自动生效且行上可见标注）；并以用例覆盖 FR5.1.1–5.1.4、FR5.2.1–5.2.4、FR5.3.1–5.3.3、FR5.4.1/5.4.2、FR5.5.1/5.5.2、FR5.6.1/5.6.2；`specdiff.start→export` 耗时数据可出具（KPI ↓80% 随 F10.6 基线联合判定）；新增模块行覆盖率 ≥80%（全局规则）；禁绕过断言（AC1.6.1 复用）在 e2e 中复验
- **依赖**：T11、T12、T13、T14
- **粒度**：1 天

---

## 任务依赖图

```text
T01 → T02 ─┬→ T03 ────────┐
           └→ T04 ────────┼→ T05 → T06 ─┬→ T07 ─┐
                          │             ├→ T08 ─┼→ T10 ┐
                          │             └→ T09 ─┤      ├→ T15
                          │      T11（依赖 T06/T07/T09）┤
                          │      T12（依赖 T06/T10）→ T13 ┤
                          │      T14（依赖 T05/T07/T08/T09）─┘
可并行：T03 / T04（仅依赖 T02）；T07 / T08 / T09（T05 后）；T12 / T13 前端与 T07–T11 后端并行
```

并行建议：T03（Diff 引擎）与 T04（映射召回）互不依赖可并行（T04 单测用夹具键对）；T07/T08/T09 在 T05 管线打通后并行；T12 前端结果页仅需 T06 契约即可启动 mock 开发；T14 评测在 T09 后即可装载标注集跑分，与前端 T12/T13 并行。

---

## Breakdown 决策与假设（Clarifications / Assumptions）

- **[D1] 集成测试不单列任务**：同 F3 [D1] 手法——映射闭环（AC5.2.1）、SSE 事件序列、RUN_LOCKED 锁定、grounding 校验、禁绕过（AC1.6.1 复用）等集成/架构测试**分散进 T05–T11 各自的完成标准**；F5 的跨模块风险点（映射唯一写入路径、定版锁定、单位陷阱、总结幻觉）都已绑定到对应实现任务的验收里。
- **[D2] Diff 引擎与 AI 三处使用点分离为并行线**：T03（确定性引擎）与 T04（嵌入+LLM 判定）按 plan A1 的分层天然解耦——T03 无 LLM 依赖可先行单测；两线在 T05 管线处汇合。理由：AC5.1.1 召回率的确定性部分不依赖模型质量，先夯实 T03 可在 LLM 桩未就绪时持续验证。
- **[D3] 初版分级规则表数据起草并入 T08**：C-Q1 决策由我方起草（≥30🔴 + ≥40🟠），作为 seed 数据随规则表 CRUD 交付，不单列内容任务；其客户评审 APPROVED 节奏属业务流程，M3 Exit 前置检查推动（plan §6 风险表），不阻塞 T08 交付（无 APPROVED 时兜底全 🟡 已在 T03/T08 验收）。
- **[D4] 标注集就绪节奏（T14）**：同 F3 [D3] 模式——双人标注依赖业务方资源（C-Q2 Assumptions），T14 先以内部自建标注集（优先复用 F1 golden_set_v1 产出）跑通评测管线与 ≥95% 判定逻辑；客户方标注集就绪后复测作为 M3 Exit 前置检查项，AC5.1.1 正式达标在 T15 验收核对单标注「标注集版本」。
- **[D5] LLM 以桩起步**：同 F3 [D4]——映射判定/等级建议/总结三个 LLM 点经 LLMGateway 桩（确定性返回 + 可注入故障/schema 违例）跑通全部逻辑与降级路径；真实模型接入属部署联调，纳入 T14 跑分与 T15 验收，不单列任务。
- **[D6] KPI ↓80% 的基线依赖**：`specdiff.start→export` 耗时打点在 T01/T11 落地，但 ↓80% 达标判定依赖 F10.6 人工基线测量（M1 交付项，plan §6 风险表）——T15 仅核对耗时数据可出具，达标判定与 F10 联合进行，不作为 F5 单独阻塞项。
- **[D7] 任务粒度校验**：拆解结果 15 条 = 15 条上限，plan 粒度合格（无超 2 人日任务），无需回改 plan；若实现期 T05（管线编排）或 T03（Diff 引擎）超期，优先在 T03 内按 normalize/align/grading 再拆分而非新增顶层任务。
