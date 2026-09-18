# F8 测试需求与用例生成 — 任务清单（Tasks）

| | |
| ---- | ---- |
| Feature | F8-test-case-generation |
| 输入 | specs/F8-test-case-generation.md、specs/F8-test-case-generation.clarifications.md（C-Q1–Q4）、specs/F8-test-case-generation.plan.md（冲突时以后两者为准）、specs/README.md |
| 关联 | specs/F10-platform-governance.tasks.md（M1 骨架为前置：BaseEntity/workflow/audit/rbac/kpi/LLMGateway/prompt_registry/OBJECT_REGISTRY/Task+SSE）、specs/F1-document-parsing.tasks.md（统一解析模型读服务 + PARSE_CONFIRMED 判定为前置，C-Q1）、specs/F2-knowledge-base.tasks.md（项目关联文档分类标签为前置，假设⑦）、specs/F3-rag-retrieval.tasks.md（统一 embedding 通道 + object_source_link 共用表 + /api/v1/links 通用链接接口为前置，A4/A5）、specs/F4-ai-chat.tasks.md（testcase_gen 技能复用 `POST /test-gen/runs` 入口，A13）、specs/F9-test-report.tasks.md（external_case_no 展示约定与 Case ID 校验契约对齐，C-Q4） |
| 阶段 | speckit-tasks |
| 粒度约定 | 每条任务 0.5–2 人日；超过 2 人日须继续拆分 |
| 前置 | F10 M1 骨架（BaseEntity/LLMGateway/prompt_registry/审计通道/require_perm/kpi_events/workflow 通用 transition/OBJECT_REGISTRY/Task+SSE）、F1.6 统一解析模型读服务（sections/fields/tables 读取 + PARSE_CONFIRMED 状态判定）、F2 项目关联文档分类标签（spec_sheet/customer_req/test_standard）、F3 统一 embedding 通道（bge-m3）+ /api/v1/links |
| 里程碑内顺序 | M4：F8.1（T03）→ {F8.2 ∥ F8.3}（T04∥T05）→ {F8.4 ∥ F8.5}（T07/T13 ∥ T06 收口）→ F8.6（T09/T10） |

> 依赖列格式：依赖的任务号。编号即执行顺序（可并行：T04 生成线与 T05 确定性判定线在 T02 后分线并行；T07/T09/T10 在 T06 管线打通后并行；T11/T12 前端仅需 API 契约即可 mock 启动；T13 评测集可在 T05 后即开始）。

---

## 任务清单

### T01 F8 接入点骨架：审计事件定义、状态机接线、权限点、KPI 埋点

- **目标**：一次性定义 F8 挂接 F10 的接入点——① 审计事件常量：`testgen.run / testreq.edited / testreq.adopted / testreq.ignored / case.edited / case.adopted / case.ignored / case.exec_status.changed / case.exec_status.imported / case.set.archived`（spec §5 + plan §4；`testgen.run` 字段契约：实测 model/model_version、prompt_req/prompt_case 版本、kb_version、输入清单 inputs、输出数 + stats{new,reused,suspected,unmapped,invalid_dropped,req_total,case_total}，FR10.3.1；`*.edited` 引用 diff id 列表，FR8.5.2）；② 状态机接线：注册 `test_requirement` 与 `test_case` 进 F10 workflow 配置，映射 `DRAFT→ADOPTED|IGNORED`（无 IN_REVIEW 中间态，处置即定版，C-Q3 Assumptions）且 **允许 `IGNORED→ADOPTED` 重采用**（处置可逆入审计，A7）——transition 仅暴露人工 dispose 端点，AI 无直写 ADOPTED 通路（FR10.2.2）；执行状态 exec_status **不注册**进 F10 状态机（独立列 + case_exec_history 留痕，假设①）；③ 权限点清单 `testgen.create / testgen.edit / testgen.dispose / testgen.exec.update / testgen.import / testgen.archive`（plan §3.2：发起生成/查看/编辑/处置/执行状态/导入/归档 = 工程师+，项目成员可见性继承 FR10.5.3；历史用例库跨项目列表 = 项目成员，假设⑤）；④ KPI 埋点契约：`testgen.generate`（run 任务耗时）+ `testgen.start→处置完成` 耗时（run.created_at → 该 run 全部产出对象达终态时点，spec §5）+ `*.adopted/*.edited` 埋点（采纳率/修改率报表数据源，FR8.5.2、PRD §50）注册进 F10 KPI SQL 视图。同时登记错误码（`TESTGEN_INPUT_REQUIRED / TESTGEN_SOURCE_DOC_NOT_READY / TESTGEN_GENERATION_FAILED / TESTGEN_RUN_NOT_CANCELABLE / TESTCASE_EXEC_STATUS_INVALID / TESTCASE_IMPORT_TEMPLATE_MISMATCH / TESTCASE_ARCHIVE_NOT_ADOPTED` + 复用 `INVALID_TRANSITION / FORBIDDEN`，plan §3.2）、配置项（`testgen.reuse.threshold=0.90 / testgen.reuse.band_width=0.05 / testgen.coverage.weights=全1 / testgen.import.row_limit=5000`，C-Q2/C-Q3/A11）与 prompt 注册表条目骨架 `f8.test_requirements / f8.test_cases`（FR10.3.4，禁裸字符串）。
- **涉及文件/模块**：`apps/backend/app/modules/platform/audit/events.py`（F8 事件段追加）、`app/modules/testgen/constants.py`（权限点/错误码/配置项）、`app/modules/platform/workflow/configs.py`（test_requirement/test_case 注册）、`app/modules/platform/kpi/views.sql`（KPI 视图段）、`app/modules/platform/prompts/registry.py`（f8.* 条目）、`app/modules/platform/objects/registry.py`（TestCase + TestRequirement 注册，FR10.1.1）
- **完成标准**：事件/权限/错误码/配置/prompt 常量表与 spec §5、plan §3.2/§4 逐条对应并有单元断言；workflow 注册后 `test_requirement`/`test_case` 可经 F10 通用 transition 走 `DRAFT→ADOPTED/IGNORED` 且 `IGNORED→ADOPTED` 合法、AI 上下文调用 transition 被拒绝（仅人工端点可触发，FR10.2.2、A7）；exec_status 不在 F10 状态机断言（假设①）；`testgen.generate` 与 start→处置完成两个 KPI 事件写入 kpi_events 后可被 SQL 视图聚合（耗时查询冒烟）；审计命名全部符合 `<domain>.<verb>`（FR10.3.3）；配置项默认值断言（阈值 0.90 / 边界带 0.05 / 权重全 1 / 导入上限 5000，C-Q2/C-Q3/A11）
- **依赖**：无（复用 F10 M1 已有常量骨架）
- **粒度**：0.5 天

### T02 F8 数据模型 + 迁移

- **目标**：新表——`test_requirements`（继承 BaseEntity：state DRAFT→ADOPTED|IGNORED、audit_ref，FR10.1.3；run_id→generation_runs NULL、seq（UNIQUE(run_id,seq)）、七要素 test_item/purpose/test_condition/test_method/test_equipment/sample_quantity/criteria、ai_generated、evidence_status linked|unverified（A4）、disposed_by/at，索引 `(project_id,state)`/`(run_id,seq) UNIQUE`，plan §2.1）；`test_cases`（BaseEntity 同构 state；run_id/seq、case_no UNIQUE `TC-{项目代号}-{seq:03d}`（FR8.3.2，C-Q4，A6）、external_case_no NULL 可空企业编号（C-Q4）、requirement_ids JSONB 冗余快照（假设⑧）、七字段 precondition/input_condition/steps JSONB 编号列表/expected/criteria/equipment、requirement_mapped BOOLEAN、reuse_flag `new|reused|suspected`、reuse_of→historical_cases、reuse_score NUMERIC、ai_generated、exec_status `not_started|in_progress|passed|failed`（独立于 state，假设①）、exec_note、exec_updated_by/at、evidence_status linked|unverified|no_mapping、archived_case_id→historical_cases（A10 幂等回指），索引 `(project_id,state)`/`(project_id,exec_status)`/`(case_no) UNIQUE`/`(external_case_no)`/`(reuse_flag)`/`(run_id,seq)`，plan §2.1）；`test_case_requirements`（case_id/requirement_id/linked_by generation|manual，UNIQUE(case_id,requirement_id)——覆盖率统计真值，FR8.3.3，A9/假设⑧）；`testreq_diffs`/`case_diffs`（对象id/project_id/field/old_value JSONB/new_value JSONB/edited_by/edited_at，append-only 禁 UPDATE/DELETE（冲正以新记录追加），索引 `(对象id)`/`(project_id,edited_by,edited_at)`，A8）；`historical_cases`（source_case_id→test_cases UNIQUE 幂等键、project_id 来源项目、case_no/external_case_no/test_item/七字段冗余、exec_summary JSONB {passed,failed,total}、embedding vector + embedding_model（A5 预计算）、archived_by/at/source_case_updated_at，索引 `(project_id)` + pgvector ivfflat(embedding)，plan §2.2）；`generation_runs`（project_id/created_by/at、inputs JSONB `[{document_id,doc_version,parse_version,tag,ocr_ratio,low_conf_ratio}]`（C-Q1 观测元数据，FR10.3.1）、historical_case_ids JSONB、reserved_from/reserved_to 号段预占（C-Q4）、model/model_version/prompt 版本/kb_version（FR10.3.1）、stats JSONB、status QUEUED/RUNNING/SUCCESS/FAILED/CANCELED、task_id，索引 `(project_id,created_at)`，plan §2.2）；`case_exec_history`（case_id/old_status/new_status/changed_by/changed_at/source manual|excel_import/note，索引 `(case_id,changed_at)`，FR8.6.1/AC8.6.1）。`object_source_link` 扩展 src_type 枚举 `test_requirement|test_case`（F3 plan A8 共用表，不新建表）。Alembic 迁移。
- **涉及文件/模块**：`app/modules/testgen/models.py`、`alembic/versions/*`、`app/modules/rag/links`（src_type 枚举扩展，与 F3 侧协调）
- **完成标准**：迁移可上下执行；两主表 BaseEntity 公共列齐备且注册于 OBJECT_REGISTRY（FR10.1.1/FR10.1.3）；`(run_id,seq)` 与 `(case_id,requirement_id)` 唯一约束断言；case_no UNIQUE 断言（终身唯一，C-Q4）；diffs 双表 append-only 语义以仓储层禁 update/delete 断言（A8）；historical_cases `source_case_id` UNIQUE 幂等键 + ivfflat 索引存在性迁移测试（A10/A5）；exec_status 取值域 CHECK 断言且与 state 无外键关联（假设①）；generation_runs.inputs 结构含 OCR 比例/低置信度比例字段（C-Q1）；object_source_link 新 src_type 枚举生效且 /links 反查可读（F3 plan A8）
- **依赖**：T01
- **粒度**：1.5 天

### T03 输入资料候选 + run 发起与号段预占（FR8.1.1–FR8.1.3、FR8.3.2 预占侧、C-Q1/C-Q4、A2/A6）

- **目标**：`GET /api/v1/projects/{id}/test-gen/inputs`——四类候选分组 `{spec_docs[], customer_req_docs[], test_standard_docs[], historical_cases[]}`：文档按 F2 分类标签三分类（spec_sheet/customer_req/test_standard，假设⑦；标签缺失文档不入候选并返回补标提示，不阻塞）；仅返回当前项目关联文档（FR8.1.1）；历史用例支持 `?q=&source_project=` 筛选（FR8.1.3，可见性按假设⑤/FR10.5.3）。`POST /api/v1/test-gen/runs`（body `{project_id, document_ids[], historical_case_ids[]?}`）同步校验——权限 `testgen.create`；≥1 项输入否则 `TESTGEN_INPUT_REQUIRED`（FR8.1.2）；文档属当前项目且 F1 解析可用且 **PARSE_CONFIRMED** 否则 `TESTGEN_SOURCE_DOC_NOT_READY`（detail 列出不合格文档，A2/C-Q1）→ 创建 generation_run（inputs 快照含 doc_version/parse_version/tag/ocr_ratio/low_conf_ratio，C-Q1；historical_case_ids 勾选快照）→ **号段预占**：预估产出 ×1.2 缓冲，经项目级 case_no 游标行 `SELECT ... FOR UPDATE` 串行化取区间写入 reserved_from/reserved_to（C-Q4，A6）→ 投递 Celery `testgen` 队列返回 `201 {run_id, task_id}`。`GET /api/v1/test-gen/runs?project_id=&status=&page=&page_size=` 分页列表。LLM 预估产出数在 T06 管线内细化，本任务先以配置项保守预估。
- **涉及文件/模块**：`app/modules/testgen/inputs/api.py`、`inputs/assemble.py`（四类候选组装）、`app/modules/testgen/api/runs.py`（发起/列表）、`app/modules/testgen/numbering.py`（号段预占：游标行锁 + 区间登记）
- **完成标准**：inputs 四类分组正确断言（F2 标签驱动，假设⑦）；标签缺失文档不入候选且提示存在（假设⑦）；零输入 → `TESTGEN_INPUT_REQUIRED`（FR8.1.2）；未 PARSE_CONFIRMED / 跨项目文档 → `TESTGEN_SOURCE_DOC_NOT_READY` 且 detail 列出文档、无任务入队（A2，同步 4xx）；权限 `testgen.create` 403 断言（FR10.5）；历史用例筛选参数生效且跨项目可见性受控（FR8.1.3/假设⑤）；run 创建后 inputs 快照六元组齐备（C-Q1/FR10.3.1）；**并发发起断言**——同项目并发 N 个 run 号段区间互不重叠且游标行锁串行化（A6/C-Q4）；`{run_id, task_id}` 返回结构契约测试（specs/README 异步约定）
- **依赖**：T02
- **粒度**：1 天

### T04 生成管线核心：解析模型读取 + 两级 LLM 结构化生成 + 代码级自检（FR8.2.1、FR8.2.2、FR8.3.1、FR8.3.3、FR8.3.4、C-Q1、A1/A2/A3/A4）

- **目标**：`gather.py`——读取所选文档 F1 统一解析模型（sections/blocks/tables/fields，**禁自解析**，FR1.6.2/C-Q1），按序列化上限组装 LLM 输入，Fields 参数表（值+单位）优先保留（FR8.3.4 量化阈值来源，A2）；`llm_requirements.py`——经 LLMGateway 调 `f8.test_requirements` prompt（输出要求：七要素齐全、逐条附证据锚点、判定标准含量化阈值时引用参数字段，plan §4），强制 JSON Schema 输出 `{"requirements":[{seq, 七要素, evidence:{document_id, anchor, quote}?}]}`——**schema 不含 case_no/复用标记/任何统计字段**（构造性保证 A1）；`llm_cases.py`——调 `f8.test_cases` prompt（输入：本轮需求集 seq+全文 + 输出要求：七字段齐全、steps 编号列表、每条挂接 ≥1 requirement_seq、无法挂接显式输出 unmapped、禁止编造 Case ID），强制 JSON Schema 输出 `{"cases":[{seq, requirement_seqs|unmapped, 七字段}]}`；`validate.py`——代码级自检①：七要素任一为空 → 无效行，无效集构造错误反馈重试 1 次（FR8.2.1，A3）；证据锚点代码校验：document_id ∈ run inputs 且锚点真实存在于解析模型，非法锚点剔除（evidence_status='unverified'，不判行无效）、合法锚点准备写 object_source_link（A4）；自检②：七字段完整性 + steps 编号列表规范化 + requirement_seq 命中本轮需求集（未命中 → 保留用例标 unmapped，FR8.3.3），无效行重试 1 次后剔除并计数 invalid_dropped（不静默丢弃）；两级均空 → `TESTGEN_GENERATION_FAILED`（A3）。纯管线核心（LLM 经桩注入，[D5]），不涉 IO 编排。
- **涉及文件/模块**：`app/modules/testgen/generate/gather.py`、`generate/llm_requirements.py`、`generate/llm_cases.py`、`generate/validate.py`
- **完成标准**：七要素/七字段空值剔除矩阵单测（FR8.2.1）；无效集错误反馈重试 1 次、仍无效剔除且 invalid_dropped 计数正确、两级均空 → `TESTGEN_GENERATION_FAILED` 断言（A3）；steps 非编号列表规范化单测（FR8.3.1）；requirement_seq 未命中 → unmapped 标注且用例保留（FR8.3.3，构造 unmapped/挂接混合样例）；证据锚点校验单测——document_id 不在 inputs / 锚点不存在 → 剔除 + evidence_status='unverified'，合法锚点通过（FR8.2.2，A4）；LLM 输出 schema 不含 case_no/复用标记/统计字段的结构断言（A1 构造性防幻觉）；prompt 携带锚点编号清单降低幻觉 + Fields 参数表优先保留断言（FR8.3.4/C-Q1，A2）；**禁绕过测试：import-linter 断言 testgen 模块不直读 MinIO 原件、不自建文档解析（一律消费 F1 解析模型）、不直连模型 SDK（必须经 LLMGateway）、不自行查 chunks 表（embedding 走统一通道）**（AC1.6.1 复用、FR10.3.4）
- **依赖**：T02
- **粒度**：2 天

### T05 确定性模块线：复用判定引擎 + 号段分配器（FR8.4.1、FR8.4.2、FR8.3.2、C-Q2/C-Q4、A1/A5/A6）

- **目标**：**纯确定性代码（无 LLM，A1/A5）**——`reuse.py` 复用判定两段算法：① 关键词预筛：「测试项目 + 判定标准」分词粗匹配（zhparser 通道）淘汰测试对象明显不同的候选；② 平台统一 embedding（bge-m3，与 F3 一致，**进程内复用统一通道，禁直查 chunks 表**）余弦相似度 ≥ `testgen.reuse.threshold`(0.90) → `reuse_flag='reused'` + reuse_of + reuse_score；`[阈值−band_width, 阈值)` → `suspected`（疑似复用不计复用统计，C-Q2）；候选 = 历史用例库 + 本项目已采用用例（C-Q2 Assumptions），embedding 在归档/采用时点预计算存储、判定阶段零在线 embedding 调用；历史库为空 → 全 new 且统计正常（C-Q2 Assumptions）。`numbering.py` 号段分配器：从 run 预占区间顺序取号 `TC-{项目代号}-{seq:03d}`（超 999 自然进位），任务失败/用例忽略后号段作废不回收（宁留空洞不重号，C-Q4）；项目代号取项目短代号、变更不回溯已生成 ID（C-Q4 Assumptions）。两模块均为纯函数/确定性服务，与 T04 生成线并行推进，在 T06 管线处汇合。
- **涉及文件/模块**：`app/modules/testgen/generate/reuse.py`、`generate/numbering.py`（分配器部分）、`app/modules/rag/embedding`（统一 embedding 通道复用）
- **完成标准**：预筛关键词命中/淘汰矩阵单测（测试对象明显不同 → 淘汰，C-Q2）；余弦 ≥0.90 → reused、[0.85,0.90) → suspected 且 suspected 不计入复用统计的单测（FR8.4.1/FR8.4.2、C-Q2）；阈值/边界带配置项生效断言（改配置行为即变，C-Q2）；历史库为空 → 全 new 且统计卡数据正常（C-Q2 Assumptions）；候选范围 = 历史库 + 本项目 ADOPTED 断言（C-Q2 Assumptions）；号段顺序分配/3 位零填充/999 进位/作废不回收（失败 run 后空洞）单测（FR8.3.2/C-Q4）；并发分配互斥断言（项目游标行锁）；纯函数性架构测试（reuse/numbering 模块 import 图无 LLM 依赖、判定阶段无在线 embedding 调用，A1/A5）
- **依赖**：T02
- **粒度**：1.5 天

### T06 生成管线编排：run 任务 → Celery 分阶段执行 → SSE + runs/结果 API（FR8.2.3、FR8.3.2、FR8.4.2、F4.5、A13）

- **目标**：Celery `testgen` 队列任务按 plan §1.2 编排：gather → gen_req → validate → gen_case → validate2 → reuse → numbering → persist（test_requirements/test_cases 落库 state=DRAFT、ai_generated=true；合法锚点写 object_source_link(src_type='test_requirement'|'test_case')；requirement_ids 冗余快照 + test_case_requirements 关联表双写，假设⑧；run 汇总 stats{new,reused,suspected,unmapped,invalid_dropped,req_total,case_total}；model/prompt/kb_version/输入清单入 generation_run）→ audit `testgen.run` + KPI `testgen.generate` → SSE SUCCESS。SSE 经 `GET /api/v1/tasks/{id}/events` 推送 `QUEUED→RUNNING(stage=gather|gen_req|validate|gen_case|validate2|reuse|numbering|persist, progress)→SUCCESS/FAILED`（specs/README 异步约定）；`POST /api/v1/tasks/{id}/cancel` 可取消（已终态 → `TESTGEN_RUN_NOT_CANCELABLE`，F4.5）。`GET /api/v1/test-gen/runs/{id}`（run 元数据 + stats 统计卡 + 结果列表 requirements/cases 含 reuse 标注与 evidence 摘要，FR8.4.2）；`GET /api/v1/test-requirements`、`GET /api/v1/test-cases`（?project_id=&state=&exec_status=&reuse_flag=&q= 分页 `{items,total,page}`）+ 详情端点。任务中途失败 → FAILED + 已预占号段作废不回收（C-Q4）。
- **涉及文件/模块**：`app/modules/testgen/generate/pipeline.py`、`app/worker/tasks/testgen_run.py`、`app/modules/testgen/api/runs.py`（详情）、`app/modules/testgen/api/objects.py`（requirements/cases 列表与详情）
- **完成标准**：fixtures 预置规格书+客户需求+企业标准（F1 解析桩）端到端 SUCCESS 且断言 SSE 事件序列 `QUEUED→RUNNING(gather→gen_req→validate→gen_case→validate2→reuse→numbering→persist)→SUCCESS`（specs/README 异步约定）；落库断言——DRAFT + ai_generated=true + 合法锚点写 object_source_link 且 /links 反查可读（FR8.2.2/A4）+ 关联表与 requirement_ids 快照一致（假设⑧）；stats 八字段齐备且 `testgen.run` 审计含 model/prompt 版本/kb_version/输入清单/输出数（FR8.4.2、FR10.3.1 字段完备性门槛）；OCR 比例/低置信度比例入 run.inputs（C-Q1）；任务取消：RUNNING 可取消、已终态 → `TESTGEN_RUN_NOT_CANCELABLE`；失败 run 后号段空洞不回收断言（C-Q4）；列表/详情分页信封与筛选参数契约测试（specs/README）；F4 testcase_gen 技能经同一 runs 端点入队断言（A13）
- **依赖**：T03、T04、T05
- **粒度**：1.5 天

### T07 逐条处置：采用/编辑后采用/忽略 + diff 留痕 + 查看依据（FR8.5.1–FR8.5.3、FR8.2.3、C-Q2/C-Q3、A7/A8）

- **目标**：`POST /api/v1/test-requirements/{id}/dispose`、`POST /api/v1/test-cases/{id}/dispose`（body `{action: adopt|ignore}`）——F10 通用 transition 的语义化包装，仅人工 API 可触发（FR10.2.2）；DRAFT→ADOPTED/IGNORED、IGNORED→ADOPTED 重采用允许（A7）；audit `testreq.adopted/ignored`、`case.adopted/ignored` + `*.adopted` KPI 埋点；本项目 ADOPTED 用例进入复用判定候选（C-Q2 Assumptions）。`PATCH /api/v1/test-requirements/{id}`、`PATCH /api/v1/test-cases/{id}`（七要素/七字段 + requirement_ids 挂接调整 linked_by='manual' + external_case_no）——**ADOPTED 后允许继续编辑**（不 OBJECT_LOCKED，假设②），逐字段写 testreq_diffs/case_diffs（old/new + edited_by/at，append-only）+ audit `*.edited`（引用 diff id 列表，FR8.5.2 diff 双用途：审计 + 修改率统计）；并发以后写为准（spec §6 排除协同编辑）。`POST /api/v1/test-requirements/batch-dispose`、`POST /api/v1/test-cases/batch-dispose`（body `{action, filters}` 按当前筛选条件批量，FR8.5.3；已终态对象跳过——部分成功语义，响应逐条结果）。`GET /api/v1/test-cases/{id}/evidence`（依据明细：片段/来源文档/page/bbox 定位/OCR 低置信度标红提示，= `/api/v1/links?src_type=test_case&src_id=` 语义化包装，FR8.5.1/C-Q1 Assumptions）；引用增删复用 F3 通用 `POST/DELETE /api/v1/links`。修改率口径固化：有 ≥1 条 diff 的 ADOPTED 对象 / ADOPTED 对象（FR8.5.2，A8）。
- **涉及文件/模块**：`app/modules/testgen/dispose/api.py`、`dispose/diff.py`、`dispose/batch.py`、`dispose/stats.py`（采纳率/修改率口径）、`app/modules/testgen/evidence/api.py`
- **完成标准**：dispose 三态流转矩阵单测（DRAFT→ADOPTED/IGNORED、IGNORED→ADOPTED 重采用、非法流转 → `INVALID_TRANSITION`，A7）；**AI 无直写 ADOPTED 通路断言**（transition 仅暴露人工端点，FR10.2.2）；PATCH 逐字段 diff 生成单测（old/new/edited_by/at 正确，FR8.5.2）+ `*.edited` 审计含 diff id 列表；ADOPTED 态编辑成功且留痕断言（假设②）；挂接人工调整写 linked_by='manual' 且关联表同步（假设⑧）；批量按筛选处置部分成功响应结构断言（已终态跳过逐条返回，FR8.5.3）；evidence 端点返回片段/定位 bbox/OCR 标红提示且与 /links 反查一致（FR8.5.1/C-Q1 Assumptions）；引用增删经 /api/v1/links 生效；采纳率/修改率按口径计算正确（编辑前后 diff 均计入，FR8.5.2/A8）；处置权限矩阵参数化断言（testgen.dispose，FR10.5）
- **依赖**：T06
- **粒度**：2 天

### T08 覆盖率统计（FR8.3.3、C-Q3、A9）

- **目标**：`GET /api/v1/projects/{id}/test-coverage`——确定性 SQL 统计（无 LLM，A1）：`覆盖率 = 有≥1条 ADOPTED 用例挂接的 ADOPTED 需求数 / ADOPTED 需求总数`，不加权（C-Q3）；挂接真值取 test_case_requirements 关联表 JOIN（A9/假设⑧，JSONB 快照不作统计依据）；返回 `{numerator, denominator, coverage, weights_applied, uncovered:[{requirement_id, test_item, ...}]}` 未覆盖需求明细下钻；读取配置 `testgen.coverage.weights`（默认全 1，加权仅改配置与计算不改数据模型，C-Q3 预留）；未映射用例（requirement_mapped=false）不入覆盖率口径（假设④，在 run 统计与用例列表单独可见）。
- **涉及文件/模块**：`app/modules/testgen/coverage/service.py`、`app/modules/testgen/api/coverage.py`
- **完成标准**：覆盖率公式集成测试——分母排除 DRAFT/IGNORED、分子要求 ADOPTED 用例挂接、与手工 SQL 对账一致（C-Q3）；uncovered 明细与库内未覆盖需求集合一致（下钻正确）；权重配置默认全 1 且 weights_applied 透出（C-Q3 预留）；unmapped 用例不入分子/分母断言（假设④）；IGNORED→ADOPTED 重采用后覆盖率正确回填（A7 联动）；空项目/零需求返回 `{0,0,…}` 不除零断言
- **依赖**：T06、T07
- **粒度**：0.5 天

### T09 用例库管理：执行状态流转 + Excel 批量导入（FR8.6.1、FR8.6.2、AC8.6.1、A11/假设①/假设⑥）

- **目标**：`PATCH /api/v1/test-cases/{id}/exec-status`（body `{exec_status, note?}`）——人工更新 未开始/进行中/通过/失败（FR8.6.1，独立列不入 F10 状态机，假设①）；非法值 → `TESTCASE_EXEC_STATUS_INVALID`；成功写 case_exec_history（old/new/changed_by/changed_at/source='manual'）+ audit `case.exec_status.changed`（spec §5）。`GET /api/v1/test-cases/{id}/exec-history`（历史可查，AC8.6.1）。Excel 批量导入——`GET .../exec-status-import/template` 模板下载（列：Case ID / 执行状态 / 备注可空）+ `POST /api/v1/test-cases/exec-status-import`（multipart xlsx）：解析经 F1 xlsx native 通道（禁绕过数据契约，A11）；列模板不符 → `TESTCASE_IMPORT_TEMPLATE_MISMATCH`；逐行校验：未知 Case ID → 行级警告可"忽略未知行"继续（FR8.6.2，语义对齐 F9.1.2）、状态值非法 → 行级错误；成功行更新 exec_status + 写 history（source='excel_import'）+ audit `case.exec_status.imported`；同步返回 `{imported, warnings[]}` 不排任务队列（≤5000 行上限 `testgen.import.row_limit`，假设⑥）。
- **涉及文件/模块**：`app/modules/testgen/library/api.py`（exec-status/exec-history/import/template）、`library/import_exec.py`
- **完成标准**：exec-status 更新 → **AC8.6.1 集成断言**——列表与详情同步可见新状态、exec-history 记录操作人与时间（FR8.6.1/AC8.6.1）；非法状态 → `TESTCASE_EXEC_STATUS_INVALID`；case_exec_history.source 区分 manual/excel_import（A11）；模板下载列结构与导入解析一致；模板不符 → `TESTCASE_IMPORT_TEMPLATE_MISMATCH`（A11）；导入混合场景：正常行入库 + 未知 Case ID 行级警告可忽略继续 + 非法状态行级错误（FR8.6.2）；导入后 audit `case.exec_status.imported` 且 history 落 source='excel_import'；超 5000 行拒绝断言（假设⑥）；xlsx 解析经 F1 通道的禁绕过断言（AC1.6.1 复用）
- **依赖**：T06
- **粒度**：1.5 天

### T10 归档入历史用例库 + 历史用例检索（FR8.6.3、FR8.1.3、C-Q2、A5/A10）

- **目标**：`POST /api/v1/projects/{id}/cases/archive`（body 可选 case_ids，缺省全量 ADOPTED）——非 ADOPTED → `TESTCASE_ARCHIVE_NOT_ADOPTED`（A10）；将 ADOPTED 用例（最终字段 + exec_summary {passed,failed,total}）复制入 historical_cases（来源项目/时间/源用例 id），同批计算 embedding 预计算存储（统一 bge-m3 通道，A5）；幂等：UNIQUE(source_case_id) + archived_case_id 回指防重复归档（A10）；项目结项钩子触发同一服务（FR8.6.3"项目结项（或手动操作）"）；audit `case.set.archived`。`GET /api/v1/historical-cases?q=&source_project=&page=`（F8.1.3 筛选选择，可见性：本部门+本人项目，假设⑤/FR10.5.3）。归档物供 F8.1.3 候选与 F8.4 复用判定，形成 归档→复用 闭环。采用（adopt）时点为本项目 ADOPTED 用例预计算 embedding（T05 候选集契约）。
- **涉及文件/模块**：`app/modules/testgen/library/archive.py`、`app/modules/testgen/api/historical.py`、`app/modules/testgen/dispose/api.py`（采用时点 embedding 预计算挂点）
- **完成标准**：归档后 historical_cases 字段完整断言（含 exec_summary 与来源项目/时间，spec §3）；embedding 已预计算且 embedding_model 记录（A5）；二次归档幂等（UNIQUE 冲突跳过、archived_case_id 回指，A10）；非 ADOPTED 归档 → `TESTCASE_ARCHIVE_NOT_ADOPTED`（FR8.6.3/A10）；归档后经 `GET /historical-cases` 可检索（FR8.1.3 闭环）；归档→再次发起生成 → 复用判定命中归档用例（AC8.4.1 全链路前置，C-Q2）；跨项目可见性受控断言（假设⑤/FR10.5.3）；audit `case.set.archived` 可查；结项钩子触发同一服务断言（FR8.6.3）
- **依赖**：T06、T07、T05
- **粒度**：1 天

### T11 前端：页面20 AI测试用例生成 + 处置交互（UI_GUIDE 页面20、FR8.1、FR8.2.3、FR8.4.2、FR8.5）

- **目标**：`pages/test/generate/`——生成配置页：四类资料分组勾选（规格书/客户需求/企业测试标准/历史用例，FR8.1.1）+ 每类多选跨类组合 + **已选清单常显**（FR8.1.3）+ 历史用例按项目/关键词筛选（FR8.1.3）+ 发起后 SSE 进度展示（stage=gather…persist）；结果页：统计卡 `新增 N / 复用 N`（仅计 reused，suspected 不计）+ 复用项可展开看历史来源链接+相似度分数+固定提示「复用为系统建议，请核对测试条件与判定标准是否适用于本项目」（FR8.4.2/C-Q2）；逐条处置卡片 `[采用][编辑后采用][查看依据]`（FR8.5.1）：编辑表单逐字段 + diff 提示、依据侧滑展示来源片段 + 跳原文定位 + OCR 低置信度标红提示（FR8.5.1/C-Q1 Assumptions）+ 引用增删（/api/v1/links）、批量采用/忽略（按筛选条件，FR8.5.3）、全部 DRAFT 产物带 [AI] 角标（specs/README AI 语义）；单 run 产出有界全量加载客户端筛选（A12）。
- **涉及文件/模块**：`apps/frontend/src/pages/test/generate/*`、`features/testgen/*`（处置卡片、依据侧滑、统计卡、[AI] 角标组件）
- **完成标准**：组件测试——四类资料分组勾选 + 已选清单常显 + 历史用例筛选（FR8.1.1–FR8.1.3）；SSE 各 stage 进度渲染（specs/README 异步约定）；统计卡数字与后端 stats 一致、suspected 不计入复用、复用项展开含来源链接+分数+固定提示（FR8.4.2/C-Q2）；处置卡片三动作流转 + [AI] 角标（FR8.5.1/FR8.2.3）；编辑表单 diff 提示；依据侧滑片段/跳原文/OCR 标红（FR8.5.1/C-Q1）；批量处置与部分成功反馈（FR8.5.3）；处置按钮按权限显隐、后端 require_perm 强制（F10 plan A7）
- **依赖**：T06、T07
- **粒度**：2 天

### T12 前端：页面19 测试管理首页 + 用例集管理 + 覆盖率卡（UI_GUIDE 页面19、FR8.3.3、FR8.6、C-Q3）

- **目标**：`pages/test/`——测试管理首页：需求/用例总览 + 覆盖率卡（分子/分母/覆盖率 + 未覆盖需求明细下钻，C-Q3）+ 生成入口；`pages/test/cases/`——项目用例集列表（TC 号/external_case_no 非空优先展示，C-Q4）+ 执行状态标签与筛选（未开始/进行中/通过/失败，FR8.6.1）+ 状态更新入口（权限显隐）+ 执行历史查看（AC8.6.1）+ Excel 批量导入向导（模板下载 → 上传 → 行级警告列表展示与"忽略未知行"确认，FR8.6.2）+ 归档按钮（确认对话框 + 幂等提示，FR8.6.3）+ reuse_flag/evidence_status/requirement_mapped 筛选（含"未映射需求"单独可见，假设④）。
- **涉及文件/模块**：`apps/frontend/src/pages/test/*`（首页/覆盖率卡）、`pages/test/cases/*`、`features/testgen/*`（执行状态标签、导入向导、执行历史抽屉）
- **完成标准**：组件测试——覆盖率卡分子/分母/覆盖率渲染 + 未覆盖下钻列表（C-Q3）；用例列表执行状态筛选与更新流转 + 执行历史展示（FR8.6.1/AC8.6.1 前端侧）；导入向导模板下载→上传→警告列表→忽略未知行确认→结果反馈（FR8.6.2）；归档确认与结果提示（FR8.6.3）；external_case_no 非空优先展示（C-Q4）；未映射用例筛选可见（FR8.3.3/假设④）；[AI] 角标与复用提示条透出（specs/README AI 语义）；操作入口按权限显隐（testgen.exec.update/testgen.import/testgen.archive，FR10.5）
- **依赖**：T07、T08、T09、T10
- **粒度**：1.5 天

### T13 评测：AC8.4.1 复用判定金标场景 + 生成质量走查集（AC8.4.1、C-Q1–C-Q3）

- **目标**：`evals/testgen_reuse/` 离线评测（测试资产不入线上库、不走状态机）——① **AC8.4.1 金标场景固化**（M4 硬门槛）：预置历史用例库 + 同类重复项目文档（含规格书+客户需求+企业测试标准混合输入，C-Q1），离线跑管线断言：统计卡新增/复用划分与预置答案一致、复用项来源链接正确、边界带样本标 suspected 不计复用（C-Q2）；② 需求/用例质量走查集：金标集（≥2 个项目样例）人工走查清单——七要素/七字段有效行率、量化阈值正确率（criteria 阈值与规格书参数一致比例）、挂接正确率抽样；③ 自动观测指标：invalid_dropped 率、unmapped 率、证据锚点有效率（合法锚点/输出锚点）、复用预筛淘汰率；④ prompt/模型版本变更触发金标回归（阈值校准以金标场景实测，C-Q2）；⑤ 报告版本化归档。
- **涉及文件/模块**：`evals/testgen_reuse/golden_set_v1.json`、`evals/testgen_reuse/run_eval.py`、`evals/testgen_reuse/report_v1.md`
- **完成标准**：金标场景可重复运行且 AC8.4.1 判定逻辑落地——新增/复用划分与预置答案一致、复用项来源链接正确、边界带样本 suspected 不计复用（**评测报告为准**，M4 硬门槛）；质量走查清单随报告出具（有效行率/量化阈值正确率/挂接正确率口径）；四项自动观测指标统计口径实现；prompt/模型版本回归触发机制可用（阈值 0.90 校准通道，C-Q2）；评测脚本与报告版本化归档；金标集 JSON schema 与 plan §4 评测口径一致
- **依赖**：T04、T05、T06
- **粒度**：1 天

### T14 端到端验收（覆盖 F8 全部 AC）

- **目标**：演示环境全链路验收：页面19 进入生成入口 → 页面20 四类资料勾选 + 已选清单常显 + 历史用例筛选（FR8.1.1–FR8.1.3）→ 发起生成 → SSE 各阶段进度（gather→gen_req→validate→gen_case→validate2→reuse→numbering→persist）→ 产物 DRAFT + [AI] 进入处置列表（FR8.2.3）→ 七要素/七字段齐备与证据锚点侧滑跳原文、OCR 标红核对（FR8.2.1/FR8.2.2/FR8.3.1/FR8.3.4、C-Q1）→ Case ID `TC-{项目代号}-{seq:03d}` 与号段空洞不重号核对（FR8.3.2/C-Q4）→ 未映射用例标注与统计（FR8.3.3/假设④）→ **AC8.4.1 金标评测报告核对（新增/复用划分正确、边界带 suspected 不计统计，C-Q2）** → 逐条 采用/编辑后采用（diff 留痕）/忽略 + 查看依据 + 批量处置（FR8.5.1–FR8.5.3）→ **AC8.6.1 走查（执行状态更新后列表与详情同步可见、历史可查）** → Excel 批量导入（未知 Case ID 警告可忽略、模板不符报错，FR8.6.2）→ 归档 → 归档物出现在历史用例候选并再次生成时命中复用（FR8.6.3 闭环、C-Q2）→ 覆盖率卡口径核对（分母/分子/uncovered 下钻，C-Q3）→ 审计事件全链导出核对（`testgen.run/testreq.edited/testreq.adopted/testreq.ignored/case.edited/case.adopted/case.ignored/case.exec_status.changed/case.exec_status.imported/case.set.archived`）→ KPI 视图 `testgen.generate` 耗时与 start→处置完成耗时出具（对照 F10.6.3 人工基线）→ 权限走查（发起/编辑/处置/执行状态/导入/归档 = 工程师+，AI 无直写 ADOPTED 通路）→ F4 testcase_gen 技能经同一入口复验（A13）→ 禁绕过断言（AC1.6.1 复用：禁直读原件/禁自解析/禁直连模型 SDK/禁直查 chunks 表）在 e2e 中复验。产出验收核对单逐项勾稽。
- **涉及文件/模块**：`apps/backend/tests/e2e/test_f8_acceptance.py`、F8 验收核对单（`specs/` 下 F8 验收记录）
- **完成标准**：以下 AC 全部通过——**AC8.4.1**（重复项目生成统计卡正确区分新增/复用，金标评测报告为准）、**AC8.6.1**（用例状态变更后列表与详情同步可见，历史可查）；并以用例覆盖 FR8.1.1–FR8.1.3、FR8.2.1–FR8.2.3、FR8.3.1–FR8.3.4、FR8.4.1/FR8.4.2、FR8.5.1–FR8.5.3、FR8.6.1–FR8.6.3；`testgen.generate` 与 start→处置完成耗时数据可出具（KPI 达标判定随 F10.6 基线联合进行）；覆盖率可统计（PHASE1_FEATURES F8 整体验收，C-Q3 口径）；新增模块行覆盖率 ≥80%（全局规则）；禁绕过断言（AC1.6.1 复用）复验通过
- **依赖**：T08、T09、T10、T11、T12、T13
- **粒度**：1 天

---

## 任务依赖图

```text
T01 → T02 ─┬→ T03（F8.1 发起线）──────────┐
           ├→ T04（两级生成+自检线）───────┤
           └→ T05（确定性判定线）──────────┤
                                           ├→ T06（管线编排汇合）─┬→ T07（处置线）─┬→ T08（覆盖率）
可并行：T04 与 T05 在 T02 后分线并行       │                     ├→ T09（执行状态/导入）│
（生成质量与复用/编号互不依赖，A1）；      │                     └→ T10（归档/历史库）─┤
T11/T12 前端仅需 API 契约即可 mock 启动    │                                           │
T13（依赖 T04/T05/T06）───────────────────┴───────────────────────────────────────────┤
T11（依赖 T06/T07）─┐                                                                 │
T12（依赖 T07/T08/T09/T10）──────────────────────────────────────────────────────────┤
                                                                                     └→ T14
```

并行建议：T04（两级 LLM 生成 + 自检）与 T05（复用判定 + 号段分配，纯确定性无 LLM，A1）在 T02 后即分线并行，两线在 T06 管线编排处汇合（stats/号段为接口契约）；T07/T09/T10 在 T06 管线打通后并行；T08 在 T07 处置产生 ADOPTED 数据后即可开发；T11/T12 前端仅需后端 API 契约即可启动 mock 开发；T13 金标场景构建可在 T05 判定引擎单测就绪后即开始，不依赖前端。

---

## Breakdown 决策与假设（Clarifications / Assumptions）

- **[D1] 集成测试不单列任务**：同 F5/F6/F7 [D1] 手法——生成管线 SSE 序列、PARSE_CONFIRMED 拦截、并发号段预占互斥、处置三态流转、部分成功语义、AC8.6.1 同步可见闭环、归档幂等与归档→复用全链路、覆盖率对账、导入行级警告、禁绕过（AC1.6.1 复用）、权限矩阵（5 角色 × 发起/编辑/处置/执行状态/导入/归档/覆盖率查看参数化）等集成/架构测试**分散进 T03–T10 各自的完成标准**；F8 的跨模块风险点（输入必经 F1 解析模型且 PARSE_CONFIRMED、LLM 仅两处且 schema 不含编号/复用/统计字段、复用标注永不自动生效、号段作废不回收、覆盖率仅认 ADOPTED + 关联表真值）都已绑定到对应实现任务的验收里。
- **[D2] 生成线与确定性线并行解耦**：T05（复用判定 + 号段分配，纯确定性无 LLM/无在线 embedding，A1/A5/A6）与 T04（两级 LLM 生成 + 自检）按 plan A1 分层天然解耦，在 T06 管线处汇合。理由：复用判定正确性（AC8.4.1）与生成质量（FR8.2.1/FR8.3.1）互不依赖，先夯实 T05 可持续回归并支撑 T13 评测集提前构建。
- **[D3] 依据引用不单列任务**：与 F7（检索挂引用需独立检索线）不同，F8 输入即所选文档，证据锚点由 LLM 输出 + 代码校验产生（plan A4）——锚点校验并入 T04 自检②、object_source_link 落库并入 T06 persist、evidence 查看端点并入 T07 处置线（查看依据是处置动作之一，FR8.5.1），不再单列证据任务。
- **[D4] LLM 以桩起步**：同 F3/F5/F6/F7 手法——两级 LLM（f8.test_requirements / f8.test_cases）经 LLMGateway 桩（确定性返回 + 可注入 schema 违例/要素空值/锚点伪造/unmapped）跑通全部逻辑与降级路径（A3）；真实模型接入属部署联调，纳入 T13 跑分与 T14 验收，不单列任务。
- **[D5] AC8.4.1 金标场景以评测集预置历史库**：线上历史用例库冷启动（plan §6 风险表）不阻塞验收——T13 金标场景预置历史用例库 + 重复项目文档离线验证（C-Q2 Assumptions 同款手法），T10 归档→复用集成测试提供全链路代码级保障，T14 双重复验。
- **[D6] KPI 耗时达标的基线依赖**：`testgen.generate` 与 start→处置完成耗时打点在 T01/T06 落地，但达标判定依赖 F10.6.3 人工基线测量（M1 交付项）——T14 仅核对耗时数据可出具，达标判定与 F10 联合进行，不作为 F8 单独阻塞项（同 F7 [D6]）。
- **[D7] 任务粒度校验**：拆解结果 14 条 ≤ 15 条上限，plan 粒度合格（无超 2 人日任务，T04 为 2 天已达上限），无需回改 plan；若实现期 T04（两级生成 + 自检）超期，优先按 gather/llm_requirements+llm_cases/validate 再拆分而非新增顶层任务；T07 同理按 dispose/diff+batch/evidence 拆分。
- **[D8] clarifications 与 plan 假设全文有效、逐条落位**：C-Q1（企业标准统一经 F1.6 + Fields 优先 + OCR 元数据入 run.inputs + 低置信度依据标红不阻断）→ T01/T02/T03/T04/T06/T07/T11；C-Q2（阈值 0.90 配置化 + 关键词预筛 + 边界带 suspected 不计统计 + 标注永不自动采用 + 固定核对提示 + 候选=历史库+本项目 ADOPTED + 空库全 new）→ T01/T05/T07/T10/T11/T13；C-Q3（覆盖率不加权口径 + 权重预留 + 处置即定版）→ T01/T02/T07/T08/T12；C-Q4（TC-{项目代号}-{seq:03d} + ×1.2 预占 + 作废不回收 + external_case_no 优先展示 + 代号变更不回溯）→ T01/T02/T03/T05/T06/T12；plan 假设①（exec_status 独立于状态机）→ T01/T02/T09、假设②（ADOPTED 可编辑不锁定）→ T01/T07、假设③（无手工新建入口，run_id 非空）→ T02/T04、假设④（unmapped 不入覆盖率、单独可见）→ T02/T06/T08/T12、假设⑤（历史库可见性=项目成员/本部门）→ T03/T10/T12、假设⑥（Excel 导入同步 + ≤5000 行）→ T01/T09、假设⑦（F2 标签三分类 + 缺标签不入候选带提示）→ T03/T11、假设⑧（M2N 关联表为统计真值 + JSONB 冗余快照 + 人工可调挂接）→ T02/T06/T07/T08。
