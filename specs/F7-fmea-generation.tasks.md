# F7 AI FMEA生成 — 任务清单（Tasks）

| | |
| ---- | ---- |
| Feature | F7-fmea-generation |
| 输入 | specs/F7-fmea-generation.md、specs/F7-fmea-generation.clarifications.md（C-Q1–Q3）、specs/F7-fmea-generation.plan.md（冲突时以后两者为准）、specs/README.md |
| 关联 | specs/F10-platform-governance.tasks.md（M1 骨架为前置：BaseEntity/workflow/audit/rbac/kpi/LLMGateway/prompt_registry/OBJECT_REGISTRY）、specs/F1-document-parsing.tasks.md（统一解析模型读服务为前置）、specs/F3-rag-retrieval.tasks.md（混合检索服务 + object_source_link 共用表 + F3.4 原文定位端点为前置）、specs/F4-ai-chat.tasks.md（fmea_gen 技能复用 `POST /fmeas/generate` 入口，plan A12）、specs/F9-test-report.tasks.md（F9.6 经 `POST /rows/batch` 转入，plan A12/假设⑦） |
| 阶段 | speckit-tasks |
| 粒度约定 | 每条任务 0.5–2 人日；超过 2 人日须继续拆分 |
| 前置 | F10 M1 骨架（BaseEntity/LLMGateway/prompt_registry/审计通道/require_perm/kpi_events/workflow 通用 transition/OBJECT_REGISTRY/KPI SQL 视图）、F1.6 统一解析模型读服务（sections/fields/tables 读取 + PARSE_CONFIRMED 状态判定）、F3 检索服务（进程内混合检索 + /api/v1/links 通用链接接口 + 原文定位端点） |

> 依赖列格式：依赖的任务号。编号即执行顺序（可并行：T03/T04/T05 生成核心线在 T02 后即分线并行；T07/T08/T09/T10 在 T06 管线打通后并行；T11/T12 前端可与后端并行；T13 评测集可在 T05 后即开始）。

---

## 任务清单

### T01 F7 接入点骨架：审计事件定义、状态机接线、权限点、KPI 埋点

- **目标**：一次性定义 F7 挂接 F10 的接入点——① 审计事件常量：`fmea.generated / fmea.submitted / fmea.approved / fmea.revised / fmea.exported / row.edited / row.adopted / row.ignored / sod.rubric.updated`（spec §5 + plan §4；`fmea.generated` 字段契约：实测 model/model_version、prompt_id/prompt_version、kb_version、引用清单、输出行数 + invalid_dropped/truncated；`row.edited` 引用 fmea_row_diff id 列表；`fmea.approved` 含 comment 与 diff 摘要，FR10.3.1）；② 状态机接线：注册 `fmea`（`DRAFT→IN_REVIEW→APPROVED`，DRAFT 直接 approve 映射为 `FMEA_INVALID_TRANSITION`）与 `sod_rubric`（`DRAFT→APPROVED`，C-Q1(a)）进 F10 workflow 配置——F7.5 是 F10.2 在生成类对象上的样板实现（spec §5）；③ 权限点清单 `fmea.create / fmea.edit / fmea.confirm / fmea.rubric.manage`（plan §3.2：生成/编辑/采纳/提交审核/导出=工程师+（项目成员可见性继承 FR10.5.3），定版 approve=研发主管 `fmea.confirm`，rubric 维护=系统/AI管理员、rubric 生效评审=研发/质量专家，C-Q1）；④ KPI 埋点契约：`fmea.generate`（任务耗时）+ `start(发起生成)→approve` 人工总耗时（fmeas.created_at→approved_at，验收 ↓≥60%）+ `row.adopted/row.ignored` 埋点（采纳率/修改率报表，FR10.6.2–FR10.6.4）注册进 F10 KPI SQL 视图。同时登记错误码（`FMEA_SOURCE_DOC_NOT_READY / FMEA_GENERATION_FAILED / FMEA_ROW_LIMIT_EXCEEDED / FMEA_NOT_DRAFT / OBJECT_LOCKED(复用) / FMEA_REVIEW_COMMENT_REQUIRED / FMEA_INVALID_TRANSITION / FMEA_EXPORT_UNSUPPORTED_FORMAT`，plan §3.2）、行数上限配置项（`fmea.generate.row_limit=50 / fmea.total.row_limit=200`，C-Q3）与 prompt 注册表条目骨架 `f7.five_dim_chain`（FR10.3.4，禁裸字符串）。
- **涉及文件/模块**：`apps/backend/app/modules/platform/audit/events.py`（F7 事件段追加）、`app/modules/fmea/constants.py`（权限点/错误码/配置项）、`app/modules/platform/workflow/configs.py`（fmea 与 sod_rubric 注册）、`app/modules/platform/kpi/views.sql`（KPI 视图段）、`app/modules/platform/prompts/registry.py`（f7.* 条目）、`app/modules/platform/objects/registry.py`（FMEA(+FmeaRow) 注册，FR10.1.1）
- **完成标准**：事件/权限/错误码/配置/prompt 常量表与 spec §5、plan §3.2/§4 逐条对应并有单元断言；workflow 注册后 `fmea` 可经 F10 通用 transition 走 `DRAFT→IN_REVIEW→APPROVED`（研发主管 + comment 必填断言；工程师 approve 403 断言，**AC7.5.1 权限侧**、FR7.5.2）；`sod_rubric` DRAFT→APPROVED 走同一 workflow（C-Q1(a)）；`fmea.generate` 与 start→approve 两个 KPI 事件写入 kpi_events 后可被 SQL 视图聚合（耗时查询冒烟）；审计命名全部符合 `<domain>.<verb>`（FR10.3.3）；AI 无直写 APPROVED 通路由 transition 仅暴露人工端点保证（FR10.2.2）
- **依赖**：无（复用 F10 M1 已有常量骨架）
- **粒度**：0.5 天

### T02 F7 数据模型 + 迁移

- **目标**：新表——`fmeas`（继承 BaseEntity：state DRAFT→IN_REVIEW→APPROVED、audit_ref，FR10.1.3；另含 product_id→products NULL、root_id（修订链根）、prev_revision_id→fmeas、revision DEFAULT 1、scope_note、source_document_ids JSONB 快照 `[{document_id,doc_version,parse_version}]`、generate_meta JSONB `{model,model_version,prompt_id,prompt_version,kb_version,output_rows,invalid_dropped,truncated,batches[]}`、risk_thresholds JSONB 快照 `{red_gte:100,orange_gte:50}`（C-Q2）、review_comment、approved_by/at、stats JSONB `{ai_rows,adopted_rows,modified_rows,no_hit_rows}`、deleted_at 软删（plan 假设④），索引 `(project_id,state)`/`(root_id,revision)`，plan §2.1）；`fmea_rows`（fmea_id、origin_row_id 血缘、seq（UNIQUE(fmea_id,seq)）、五维 function/failure_mode/effect/cause/control、s/o/d NULL、rpn、risk `RED|ORANGE|GREEN`、suggestion JSONB 打分建议快照含 rubric 版本与「依据未定版评分标准」标记（A5/A6）、ai_generated、cell_ai_flags JSONB 单元格级 `{function,failure_mode,effect,cause,control,s,o,d}→bool`（A9）、row_status `ai_pending|adopted|ignored|manual`、source `generation|manual|report_anomaly`、source_ref JSONB（F9.6，A12）、evidence_status `linked|no_hit`（A4），索引 `(fmea_id,seq) UNIQUE`/`(fmea_id,row_status)`/`(fmea_id,risk)`/`(origin_row_id)`，plan §2.1）；`fmea_row_diffs`（row_id/fmea_id/field/old_value/new_value/edited_by/edited_at，append-only 不 UPDATE/DELETE（plan 假设③），索引 `(row_id)`/`(fmea_id,edited_by,edited_at)`，plan §2.2）；`sod_rubrics`（dimension s|o|d、score 1–10、semantic_description、weight 预留不参与计算（plan 假设⑤）、version、state DRAFT|APPROVED、approved_by/at、remark，索引 `(dimension,score,version,state)`，plan §2.2）。引用清单不新建表（经 object_source_link src_type='fmea_row'，F3 plan A8）。Alembic 迁移。
- **涉及文件/模块**：`app/modules/fmea/models.py`、`alembic/versions/*`
- **完成标准**：迁移可上下执行；`fmeas` BaseEntity 公共列齐备且注册于 OBJECT_REGISTRY（FR10.1.1/FR10.1.3）；fmea_rows 四索引存在性迁移测试；`(fmea_id,seq)` 唯一约束断言（截断按 seq，C-Q3）；`fmea_row_diffs` append-only 语义以仓储层禁 update/delete 断言（plan 假设③）；cell_ai_flags JSONB 八字段结构校验（A9）；suggestion 快照结构含 rubric 版本字段（A6）；风险阈值快照默认值 `{red_gte:100,orange_gte:50}`（C-Q2）；不新建引用表、object_source_link src_type='fmea_row' 枚举已扩展（F3 plan A8）
- **依赖**：T01
- **粒度**：1.5 天

### T03 生成管线核心：输入收集 + LLM 五维链结构化生成 + 代码级自检（FR7.1.1、FR7.1.2、A1/A2/A3/A7）

- **目标**：`gather.py`——读取所选文档 F1 统一解析模型（sections/blocks/tables/fields，**禁自解析**，FR1.6.2），按 scope_note 相关性截断组装 LLM 输入，规格参数表（F1.4 fields）优先保留（A2）；`llm_chain.py`——经 LLMGateway 调 `f7.five_dim_chain` prompt（系统指令：五维链展开、覆盖 scope_note、**禁止编造引用/案例编号、禁止输出分值**，plan §4），强制 JSON Schema 结构化输出 `{"rows":[{function,failure_mode,effect,cause,control,seq}]}` ≤50 行——**schema 不含引用与分值字段**（构造性防幻觉，A1/A4）；schema 校验失败带错误反馈重试 1 次（A3）；`validate.py`——代码级自检：五维任一为空→剔除、规范化去重（功能+失效模式空白归一）、按 seq 截断至 `fmea.generate.row_limit`（确定性保留前 50 有效行，不调用 LLM 复核，C-Q3 Assumptions），invalid_dropped/truncated 计数返回供审计；重试后仍全空 → `FMEA_GENERATION_FAILED`。纯管线核心（LLM 经桩注入，D5），不涉 IO 编排。
- **涉及文件/模块**：`app/modules/fmea/generate/gather.py`、`generate/llm_chain.py`、`generate/validate.py`
- **完成标准**：自检矩阵单测——五维逐维空值剔除、归一化去重、截断 50 确定性（同输入同输出）与 truncated 计数正确（FR7.1.2、C-Q3）；schema 违例 → 带错误反馈重试 1 次后仍违例行被剔除、全空 → FAILED 断言（A3）；LLM 输出 schema 不含引用/分值字段的结构断言（A1/A4 构造性防幻觉）；gather 截断策略单测（参数表优先保留 + scope_note 相关性，A2）；**禁绕过测试：import-linter 断言 fmea 模块不直读 MinIO 原件、不自建文档解析（一律消费 F1 解析模型）、不直连模型 SDK（必须经 LLMGateway）**（AC1.6.1 复用、FR10.3.4）
- **依赖**：T02
- **粒度**：1.5 天

### T04 检索挂引用 + 行引用 Evidence 端点（FR7.1.3、FR7.3.1、FR7.3.2、A4）

- **目标**：`retrieve.py`——逐行以「功能 + 失效模式 (+scope_note)」为查询**复用 F3 混合检索服务**（进程内调用，禁直查 chunks 表，F3 plan A8），top_k=3、阈值判定复用 F3 plan A5 口径（no_hit 阈值可调）；命中 chunk 写 `object_source_link(src_type='fmea_row')`，行 evidence_status='linked'；无命中行 evidence_status='no_hit' 标注"无历史依据"（FR7.1.3）；引用清单汇总供 `fmea.generated` 审计。`GET /api/v1/fmeas/{id}/rows/{rid}/evidence`——行引用明细（片段/来源文档/项目/时间/定位 bbox，= `GET /api/v1/links?src_type=fmea_row&src_id=` 的语义化包装，FR7.3.1）；引用增删复用 F3 通用链接接口 `POST/DELETE /api/v1/links`（FR7.3.2，不新建端点，F3 plan A8）。
- **涉及文件/模块**：`app/modules/fmea/generate/retrieve.py`、`app/modules/fmea/evidence/api.py`、`app/modules/rag/`（进程内检索服务与 links 接口复用）
- **完成标准**：检索桩驱动集成测试——命中行写 object_source_link 且可经 `/links` 与 evidence 端点反查（含 page/bbox 定位，FR7.3.1）；无命中行 evidence_status='no_hit' 断言（FR7.1.3）；**架构断言：fmea 模块仅经 rag 服务接口检索、不直查 chunks 表**（禁绕过，AC1.6.1 复用）；引用增删经 `/api/v1/links` 生效且审计 `rag.link.created/deleted`（FR7.3.2）；引用清单结构含 document_id/chunk_id/定位信息（供 fmea.generated 审计与抽样回查，FR10.3.1）
- **依赖**：T03
- **粒度**：1 天

### T05 S/O/D 打分规则引擎 + rubric 管理与初版数据（FR7.2.1–FR7.2.4、A5/A6、C-Q1/C-Q2）

- **目标**：纯函数规则引擎（**无 LLM**，A1/A5）——`rubric.py`：生效版本判定（有 APPROVED 用 APPROVED、无则回落最新 DRAFT，C-Q1 Assumptions）；S=失效影响文本语义匹配 rubric 分档（安全/法规→9–10…不可感知→1–2，C-Q1）；D=控制措施可探测性语义匹配分档（无探测→9–10…自动在线检测→1–2）；`history_stats.py`：检索命中历史案例中的既有打分统计分位数→O 分档（best-effort：无统计回落 rubric 中位档并在理由中说明，plan §6 风险缓解）；`rpn.py`：RPN=S×O×D 实时计算 + 色标三段阈值（按 fmeas.risk_thresholds 快照，默认红≥100/橙50–99/绿<50，C-Q2）；理由串模板化生成（如"S=9：失效影响涉及安全风险（rubric v2 DRAFT 分档）"），rubric 处于 DRAFT 时理由带「依据未定版评分标准」标记（C-Q1 Assumptions）；分值随行快照写入 fmea_rows.suggestion——rubric 变更仅影响新生成任务，已定版 FMEA 不重算（A6）。rubric 管理——`GET/POST/PUT /api/v1/fmeas/rubric`（整表版本化 CRUD，限 `fmea.rubric.manage`）+ `POST /api/v1/fmeas/rubric/{version}/transition`（DRAFT→APPROVED，研发/质量专家，audit `sod.rubric.updated`，C-Q1(a)）；**初版 rubric 数据起草**：S/O/D 三维 1–10 语义分档 seed 以 DRAFT 态导入（C-Q1，同 F6 [D3] 手法）。
- **涉及文件/模块**：`app/modules/fmea/scoring/rubric.py`、`scoring/history_stats.py`、`scoring/rpn.py`、`app/modules/fmea/api/rubric.py`、`evals/fmea_generation/sod_rubric_seed_v1.json`
- **完成标准**：rubric 分档匹配矩阵单测（S/D 五档边界穷举，FR7.2.2/C-Q1）；O 历史统计分位 + 无统计回落中位档且理由注明（A5 best-effort）；RPN 计算（S×O×D）与色标三段阈值边界单测（99/100、49/50，C-Q2）；rubric DRAFT 态理由带「依据未定版评分标准」、APPROVED 后不带（C-Q1 Assumptions）；生效版本判定单测（无 APPROVED 回落 DRAFT）；阈值快照语义单测（rubric/阈值变更后已生成行不变，A6）；打分理由一句模板生成断言（FR7.2.1）；rubric CRUD + transition 权限矩阵（工程师定版 403，C-Q1）；seed 数据三维 1–10 全分档齐备；纯函数性架构测试（scoring 模块 import 图无 LLM/无 IO 依赖，A1）
- **依赖**：T02、T01
- **粒度**：1.5 天

### T06 生成管线编排：generate 端点 → Celery 任务 → 分阶段执行 → SSE + 列表/详情 API（FR7.1.1、FR7.1.4、C-Q3、A2/A7）

- **目标**：`POST /api/v1/fmeas/generate`（body `{project_id, document_ids[], product_id?, scope_note?, fmea_id?}`）同步校验——权限 `fmea.create`、文档属当前项目 + F1 解析成功且 **PARSE_CONFIRMED**（否则 `FMEA_SOURCE_DOC_NOT_READY`，detail 列出不合格文档，A2）、fmea_id 追加批次时须 DRAFT 态（否则 `FMEA_NOT_DRAFT`）+ 200 行配额预检（`fmea.total.row_limit`，C-Q3）→ 创建 fmea 记录（fmea_id 缺省新建 revision=1；source_document_ids 快照）→ 投递 Celery `fmea` 队列返回 `{fmea_id, task_id}`；Celery 任务按 plan §1.2 编排：gather→generate→validate→retrieve→score→persist（fmea_rows 落库 ai_generated=true、row_status='ai_pending'、cell_ai_flags 全 true、suggestion 快照；generate_meta 落 fmeas）→ audit `fmea.generated` + KPI `fmea.generate` → SSE SUCCESS；失败 → FAILED + `FMEA_GENERATION_FAILED`。SSE 经 `GET /api/v1/tasks/{id}/events` 推送 `QUEUED→RUNNING(stage=gather|generate|validate|retrieve|score, progress)→SUCCESS/FAILED`（specs/README 异步约定）；`POST /api/v1/tasks/{id}/cancel` 可取消（F4.5）；任务事件提示截断（>50 行时"已达单次生成上限 50 行，可缩小范围或分区域多次生成"，C-Q3）。`GET /api/v1/fmeas`（?project_id=&state= 分页 `{items,total,page}`）、`GET /api/v1/fmeas/{id}`（表头 + 全量行 ≤200 + 每行引用摘要，FR7.1.4）。
- **涉及文件/模块**：`app/modules/fmea/api/fmeas.py`（generate/list/detail）、`app/modules/fmea/generate/pipeline.py`、`app/worker/tasks/fmea_generate.py`
- **完成标准**：未 PARSE_CONFIRMED 文档返回 `FMEA_SOURCE_DOC_NOT_READY` 且无任务入队（A2，同步 4xx）；追加批次非 DRAFT → `FMEA_NOT_DRAFT`、超配额 → `FMEA_ROW_LIMIT_EXCEEDED` 预检（C-Q3/A7）；fixtures 预置规格书（F1 解析桩 + F3 检索桩）端到端 SUCCESS 且断言 SSE 事件序列 `QUEUED→RUNNING(gather/generate/validate/retrieve/score)→SUCCESS`（specs/README 异步约定）；行落库 ai_generated/row_status/cell_ai_flags/suggestion 快照断言（plan §1.2 persist）；generate_meta 六要素（model/prompt/kb_version/输出行数/invalid_dropped/truncated）齐备且 `fmea.generated` 审计可查（spec §5、FR10.3.1）；>50 行截断提示出现在任务完成事件（C-Q3）；管线中途失败 → FAILED + 任务可取消；F4 fmea_gen 技能经同一端点入队断言（A12）
- **依赖**：T03、T04、T05
- **粒度**：1.5 天

### T07 行内编辑：逐字段 diff + 单元格角标消除 + RPN 服务端重算（FR7.2.4、FR7.4.2、A9）

- **目标**：`PATCH /api/v1/fmeas/{id}/rows/{rid}`（body `{patch:{field:value,...}}`，五维/S/O/D）——APPROVED 态返回 `OBJECT_LOCKED`（AC7.5.1，复用 F10 锁定谓词）；逐字段写 `fmea_row_diffs`（old/new + edited_by/at，append-only）+ cell_ai_flags 仅被改字段置 false（FR7.4.2"人工修改后角标消失"的单元格级精确语义，A9）+ audit `row.edited`（引用 diff id 列表）；S/O/D 人工改动覆盖 AI 建议并保留 suggestion 快照对照（FR7.2.4）；S/O/D 变更后服务端重算 rpn/risk（FR7.2.3）；DRAFT 态校验（IN_REVIEW 返回 `FMEA_NOT_DRAFT`，plan §3.2）；并发以后写为准（spec §6 非目标排除协同编辑）。
- **涉及文件/模块**：`app/modules/fmea/editing/api.py`、`editing/diff.py`、`editing/locks.py`（锁定谓词，供编辑/批量/采纳共用，同 F6 [D ] 手法单一实现）
- **完成标准**：PATCH 逐字段 diff 生成单测（old/new 值与 edited_by/at 正确，FR7.4.2）；cell_ai_flags 单字段消角标、未改字段角标保留断言（A9 精确语义）；S/O/D 修改后 rpn/risk 按阈值快照重算（FR7.2.3/C-Q2）；suggestion 快照保留原 AI 建议供对照（FR7.2.4）；`row.edited` 审计含 diff id 列表；IN_REVIEW 态编辑返回 `FMEA_NOT_DRAFT`、APPROVED 态返回 `OBJECT_LOCKED`（**AC7.5.1 锁定侧断言**）；锁定谓词单一实现多处共用（防绕过）
- **依赖**：T06
- **粒度**：1 天

### T08 批量操作 + 采纳率/修改率统计 + F9.6 转入入口（FR7.4.1、FR7.4.3、AC7.4.1、A7/A12）

- **目标**：`POST /api/v1/fmeas/{id}/rows/batch`——① `action=adopt|ignore`（row_ids 或 filters）：row_status 变更 + audit `row.adopted/row.ignored` + KPI 埋点；② `action=add`（rows[]，source=manual|report_anomaly）：计入 200 行配额、删行释放配额（C-Q3 Assumptions），超限行报 `FMEA_ROW_LIMIT_EXCEEDED`——**部分成功语义**：响应逐条成功/失败（plan §3.2）；report_anomaly 行携带 source_ref `{report_id,anomaly_id}`、为人工发起对象不计采纳率分母（A12/假设⑦，F9.6 契约入口）；③ `action=delete`（row_ids）。统计口径固化（plan §3.2）：采纳率 = adopted 行数 / ai_generated=true 全集行数；修改率 = 存在 ≥1 条 diff 的采纳行 / adopted 行数；分母仅计 source=generation；fmeas.stats 预聚合 + F10.6 KPI 埋点双写（FR7.4.3、AC7.4.1）。增行（含人工增行五维+S/O/D）与删行同样受 DRAFT/锁定态约束（复用 T07 锁定谓词）。
- **涉及文件/模块**：`app/modules/fmea/editing/batch.py`、`editing/stats.py`、`app/modules/fmea/editing/api.py`（batch 端点）
- **完成标准**：批量采纳/忽略 → row_status + 审计 + KPI 埋点断言（FR7.4.3）；**AC7.4.1 集成断言**——采纳/忽略/行内编辑混合操作后 fmeas.stats 预聚合数字正确（ai_rows/adopted_rows/modified_rows）且可被 KPI SQL 视图聚合出采纳率/修改率；统计口径分母排除 manual/report_anomaly 行的单测（A12）；部分成功响应结构断言（超限行 `FMEA_ROW_LIMIT_EXCEEDED`、其余成功，C-Q3）；增行计入配额、删行释放配额单测（C-Q3 Assumptions）；report_anomaly 行 source_ref 落库且不计入分母（A12/假设⑦）；APPROVED 态批量操作返回 `OBJECT_LOCKED`（AC7.5.1 复用锁定谓词）
- **依赖**：T07
- **粒度**：1.5 天

### T09 人工审核流 + 修订版本链 + 版本对照（FR7.5.1–FR7.5.3、AC7.5.1、A8）

- **目标**：F10.2 workflow 语义化包装端点——`POST /api/v1/fmeas/{id}/submit-review`（DRAFT→IN_REVIEW，权限 `fmea.edit`）；`POST /api/v1/fmeas/{id}/approve`（IN_REVIEW→APPROVED，权限 `fmea.confirm` 仅研发主管、body comment 必填否则 `FMEA_REVIEW_COMMENT_REQUIRED`；成功后 audit `fmea.approved` + KPI start→approve 打点、APPROVED 后表格锁定——编辑/批量/采纳统一 `OBJECT_LOCKED`，AC7.5.1）；DRAFT 直接 approve → `FMEA_INVALID_TRANSITION`（FR10.2.1 映射 IN_REVIEW 必经）；**AI 无任何直写 APPROVED 通路**（spec §5、FR10.2.2）；`POST /api/v1/fmeas/{id}/revise`（仅 APPROVED：复制 fmea 与全部行为新记录 revision+1、prev_revision_id 链接、行保留 origin_row_id 血缘，旧版本保持 APPROVED 只读留存，并发 revise 串行化取 max(revision)+1，A8/假设⑧）→ audit `fmea.revised`；`GET /api/v1/fmeas/{id}/revisions`（root_id 查同链版本列表）；`GET /api/v1/fmeas/compare?base=&target=`（origin_row_id 血缘对齐的行级 diff changed/added/removed，FR7.5.3，不做列级 schema 对照，假设⑧）。
- **涉及文件/模块**：`app/modules/fmea/review/api.py`、`review/revise.py`、`review/compare.py`
- **完成标准**：**AC7.5.1 集成闭环**——工程师角色无定版权限（403）、研发主管定版成功（comment 必填）、定版后编辑/批量/采纳接口全部 `OBJECT_LOCKED`、DRAFT 直接 approve → `FMEA_INVALID_TRANSITION`；缺 comment → `FMEA_REVIEW_COMMENT_REQUIRED`（FR7.5.2）；revise → revision+1、旧行 origin_row_id 血缘完整、旧版本只读留存且新版本可编辑（FR7.5.3）；revisions 列表按链返回；compare 按血缘输出行级三类 diff（FR7.5.3）；`fmea.approved/fmea.submitted/fmea.revised` 审计含 who/when/comment；start→approve KPI 事件打点断言（spec §5）；全链路审计重建冒烟（who/when/input/model/prompt/kb_version/output/human diff/final，AC10.3.1 的 F7 侧断言）
- **依赖**：T06、T07
- **粒度**：1.5 天

### T10 导出：Excel/Word 异步生成 + 草稿水印（FR7.6.1、FR7.6.2、A10）

- **目标**：`POST /api/v1/fmeas/{id}/export`（`{format: excel|word}`，白名单外 `FMEA_EXPORT_UNSUPPORTED_FORMAT` → task_id，Celery `fmea` 队列，SSE stage=export，specs/README 异步约定）——Excel（openpyxl，标准 FMEA 表格排版，表头含 S/O/D/RPN 列，FR7.6.1）、Word（python-docx）；**水印以定版时点为准**：state≠APPROVED（DRAFT/IN_REVIEW）注入"草稿"水印（FR7.6.1 + plan 假设①）；内容含行明细、审核意见、版本号、定版人与时间（FR7.6.2）；产物写 MinIO 返回预签名 URL；`GET /api/v1/fmeas/{id}/exports` 导出历史（format/file_url/created_at）→ audit `fmea.exported`。
- **涉及文件/模块**：`app/modules/fmea/export/excel.py`、`export/word.py`、`app/modules/fmea/api/export.py`、`app/worker/tasks/fmea_export.py`
- **完成标准**：Excel 表头含 S/O/D/RPN 列 + 行明细与库内数据一致性集成测试（FR7.6.1）；内容四要素（行明细/审核意见/版本号/定版人与时间）齐备断言（FR7.6.2）；DRAFT/IN_REVIEW 导出水印存在、APPROVED 导出无水印（A10 假设①）；Word 同口径；异步任务 SSE 可见 export stage、预签名 URL 可下载（specs/README 异步约定）；非白名单格式返回 `FMEA_EXPORT_UNSUPPORTED_FORMAT`；导出历史接口返回结构契约测试
- **依赖**：T06
- **粒度**：1 天

### T11 前端：FMEA 工作台表格 + 生成入口 + 历史案例侧滑（UI_GUIDE 页面16、FR7.1、FR7.2、FR7.3、FR7.4）

- **目标**：`pages/fmea/GenerateDialog.tsx`——[AI生成FMEA] 对话框：项目关联文档多选（来自 F2，未 PARSE_CONFIRMED 文档禁选并提示引导校对，A2）+ scope_note 可选输入 + 追加批次（向既有 DRAFT fmea 分区域生成，C-Q3）+ 发起后 SSE 进度展示（stage=gather…score）；`pages/fmea/FmeaTable.tsx`——类电子表格（≤200 行全量加载 + 客户端排序/筛选，plan 假设②）：行内编辑、增行/删行、按列排序、按风险等级筛选（FR7.4.1）、S/O/D 步进器 + RPN 色标单元格（红/橙/绿，FR7.2.3/C-Q2）、AI 单元格 [AI] 角标随人工编辑消失（FR7.4.2）、行级 [采纳][忽略] 批量操作与统计数字（采纳率/修改率）实时刷新（FR7.4.3/AC7.4.1）、行数配额提示（50/200 上限，C-Q3）；`pages/fmea/EvidenceDrawer.tsx`——"查看历史案例"侧滑：引用片段/来源文档/项目/时间、跳转原文定位（复用 F3.4 端点，FR7.3.1）、引用增删（FR7.3.2）、no_hit 行"无历史依据"标注（FR7.1.3）。
- **涉及文件/模块**：`apps/frontend/src/pages/fmea/GenerateDialog.tsx`、`pages/fmea/FmeaTable.tsx`、`pages/fmea/EvidenceDrawer.tsx`、`features/fmea-table/*`（可编辑单元格、[AI] 角标、S/O/D 步进器、RPN 色标组件）
- **完成标准**：组件测试——生成对话框文档多选 + 未确认文档拦截 + scope_note + 追加批次入口 + SSE 进度（FR7.1.1/FR7.1.4、A2/C-Q3）；类电子表格行内编辑/增删行/排序/风险筛选（FR7.4.1）；[AI] 角标随编辑消失（FR7.4.2）；批量采纳/忽略与统计数字刷新（AC7.4.1 前端侧）；S/O/D 步进器 + RPN 色标三段渲染（FR7.2.3）；历史案例侧滑四要素 + 原文跳转（FR7.3.1）+ 引用增删（FR7.3.2）+ no_hit 标注（FR7.1.3）；全部 AI 输出带 AI 标识（specs/README AI 语义）
- **依赖**：T06、T08
- **粒度**：2 天

### T12 前端：审核流操作 + 版本对照 + rubric 管理（UI_GUIDE 页面16、FR7.2.2、FR7.5）

- **目标**：`pages/fmea/ReviewActions.tsx`——提交审核/定版/修订/导出操作区：定版按钮仅研发主管可见（前端展示控制 + 后端强制校验，FR10.5.4）、定版 comment 必填弹窗（FR7.5.2）、定版后锁定提示（`OBJECT_LOCKED`）、DRAFT 直接定版提示 `FMEA_INVALID_TRANSITION`、导出格式选择与水印说明；`pages/fmea/RevisionCompare.tsx`——版本列表（revisions）+ 版本对照视图（行级 changed/added/removed 三色 diff，FR7.5.3）；rubric 管理页——评分标准表查看/维护（限系统/AI管理员）+ 版本列表 + DRAFT→APPROVED 定版操作（研发/质量专家，C-Q1(a)）、DRAFT 态打分理由「依据未定版评分标准」标识透出（C-Q1 Assumptions）。
- **涉及文件/模块**：`apps/frontend/src/pages/fmea/ReviewActions.tsx`、`pages/fmea/RevisionCompare.tsx`、`pages/fmea/rubric/*`
- **完成标准**：组件测试——定版按钮按角色显隐（无权限隐藏，FR7.5.2/FR10.5.4）；comment 必填弹窗拦截；定版后操作区锁定态渲染（AC7.5.1 前端侧）；版本列表加载 + 对照视图三类行级 diff 渲染（FR7.5.3）；rubric 管理页按权限显隐维护/定版入口（C-Q1）；DRAFT 依据标识透出（C-Q1 Assumptions）；导出入口 + 水印说明（FR7.6.1）
- **依赖**：T09、T10
- **粒度**：1 天

### T13 评测：五维链金标集 + AC7.1.1 判定（AC7.1.1、C-Q1(b)）

- **目标**：`evals/fmea_generation/` 离线评测（测试资产不入线上库、不走状态机，C-Q1(b)）——① **金标集构建**：3 个项目（电池包级 1 + 子系统级 2；不足降级 2+1 公开行业案例，clarifications Assumptions）× 每项目 ≥10 行金标行（按五维链 Schema 我方标注、预留客户 FMEA 工程师确认通道）；② **离线评测脚本**：mock/桩化 F1 输入 + 真实生成管线跑分，断言 AC7.1.1——行数 ≥10、五维无一为空（维度语义正确性人工走查清单随报告出具，M4 硬门槛）；③ **自动观测指标**：有效行率（自检通过/LLM 原始行）、单调用行数分布、引用命中率（有引用行/总行）、引用抽样正确率流程（人工标注通道）；④ prompt/模型版本变更触发金标回归（C-Q1(b) 用途）；⑤ `sod_rubric_seed_v1.json` 随评测资产归档（T05 产物复用）；⑥ 报告版本化归档。
- **涉及文件/模块**：`evals/fmea_generation/golden_set_v1.json`、`evals/fmea_generation/run_eval.py`、`evals/fmea_generation/report_v1.md`、`evals/fmea_generation/sod_rubric_seed_v1.json`
- **完成标准**：金标集可重复运行且 AC7.1.1 判定逻辑落地（≥10 行有效五维链 + 无空维度断言，**评测报告为准**）；维度语义人工走查清单随报告出具（M4 硬门槛执行通道）；有效行率/引用命中率/引用抽样正确率观测指标统计口径实现；prompt/模型版本回归触发机制可用；评测脚本与报告版本化归档；金标集 JSON schema 与 plan §4 评测口径一致
- **依赖**：T03、T04、T05
- **粒度**：1 天

### T14 端到端验收（覆盖 F7 全部 AC）

- **目标**：演示环境全链路验收：生成入口选择已 PARSE_CONFIRMED 规格书（多选）+ scope_note → 发起生成 → SSE 各阶段进度（gather/generate/validate/retrieve/score）→ 初稿 DRAFT 进入工作台（FR7.1.4）→ **AC7.1.1 金标评测报告核对（≥10 行有效五维链、维度语义走查通过）** → 逐行查看历史案例侧滑与原文跳转（FR7.3.1）/no_hit 行"无历史依据"标注（FR7.1.3）/引用增删（FR7.3.2）→ S/O/D 建议理由与「依据未定版评分标准」标识核对（FR7.2.1、C-Q1）→ RPN 与色标核对（FR7.2.3/C-Q2）→ 行内编辑角标消失 + diff 留痕（FR7.4.2）→ 批量采纳/忽略 → **AC7.4.1 KPI 报表数字核对（采纳率/修改率正确出现）** → 追加批次（分区域生成，C-Q3）与行数配额（50/200）验证 → 提交审核 → **AC7.5.1 权限走查（工程师 403、研发主管定版 comment 必填、定版后编辑 `OBJECT_LOCKED`、DRAFT 直接 approve `FMEA_INVALID_TRANSITION`）** → 修订 revision+1 + 旧版本只读 + 版本对照（FR7.5.3）→ DRAFT 导出 Excel/Word 带草稿水印、APPROVED 后无水印、内容四要素（FR7.6.1/7.6.2）→ 审计事件全链导出核对（`fmea.generated/submitted/approved/revised/exported/row.edited/row.adopted/row.ignored/sod.rubric.updated`）→ KPI 视图 `fmea.generate` 耗时与 start→approve 耗时出具（对照人工基线验 ↓≥60%，spec §5）→ rubric DRAFT seed 导入→专家 APPROVED→新生成生效、已定版 FMEA 不重算（A6/C-Q1）→ F4 fmea_gen 技能经同一入口复验 + F9.6 异常转风险条目经 rows/batch 复验（A12/假设⑦）→ 禁绕过断言（AC1.6.1 复用：禁直读原件/禁自解析/禁直连模型 SDK/禁直查 chunks 表）在 e2e 中复验。产出验收核对单逐项勾稽。
- **涉及文件/模块**：`apps/backend/tests/e2e/test_f7_acceptance.py`、F7 验收核对单（`specs/` 下 F7 验收记录）
- **完成标准**：以下 AC 全部通过——**AC7.1.1**（金标 ≥10 行有效五维链 + 维度语义走查，评测报告为准）、**AC7.4.1**（采纳/忽略/行内编辑后 KPI 报表数字正确出现）、**AC7.5.1**（工程师无定版接口 403、定版后编辑接口返回锁定错误）；并以用例覆盖 FR7.1.1–7.1.4、FR7.2.1–7.2.4、FR7.3.1/7.3.2、FR7.4.1–7.4.3、FR7.5.1–7.5.3、FR7.6.1/7.6.2；`fmea.generate` 与 start→approve 耗时数据可出具（KPI ↓≥60% 随 F10.6 基线联合判定）；新增模块行覆盖率 ≥80%（全局规则）；禁绕过断言（AC1.6.1 复用）复验通过
- **依赖**：T09、T10、T11、T12、T13
- **粒度**：1 天

---

## 任务依赖图

```text
T01 → T02 ─┬→ T03 → T04 ─┐
           └→ T05 ───────┼→ T06 ─┬→ T07 → T08 ─┐
                         │       ├→ T09 ───────┤
                         │       └→ T10 ───────┤
可并行：T03/T04（生成+检索线）            │
与 T05（打分引擎线）在 T02 后并行        T11（依赖 T06/T08）──┐
                                         T12（依赖 T09/T10）──┤
T13（依赖 T03/T04/T05）─────────────────────────────────────┤
                                         └──────────────────┴→ T14
```

并行建议：T03/T04（生成管线核心 + 检索挂引用）与 T05（确定性打分引擎）在 T02 后即分线并行——打分引擎纯函数无 LLM/IO 可先行单测（A1），两线在 T06 管线处汇合；T07/T08/T09/T10 在 T06 管线打通后并行；T11/T12 前端仅需后端 API 契约即可启动 mock 开发；T13 金标集构建可在 T03 单测就绪后即开始，不依赖前端与审核流。

---

## Breakdown 决策与假设（Clarifications / Assumptions）

- **[D1] 集成测试不单列任务**：同 F5/F6 [D1] 手法——生成管线 SSE 序列、PARSE_CONFIRMED 拦截、AC7.4.1 统计闭环、AC7.5.1 权限/锁定闭环、修订血缘与版本对照、导出水印、部分成功语义、配额语义、禁绕过（AC1.6.1 复用）、权限矩阵（5 角色 × 生成/编辑/采纳/提交审核/定版/修订/导出/rubric 维护/rubric 定版参数化）等集成/架构测试**分散进 T03–T10 各自的完成标准**；F7 的跨模块风险点（输入必经 F1 解析模型、引用必经 F3 真实检索、LLM 单点且不碰分值/引用、锁定谓词单一实现、rubric 分值快照固化）都已绑定到对应实现任务的验收里。
- **[D2] 生成核心线与打分引擎线并行解耦**：T05（S/O/D 规则引擎，纯函数无 LLM/IO，A1/A5）与 T03/T04（生成 + 检索线）按 plan A1 分层天然解耦，在 T06 管线编排处汇合（suggestion 快照与 evidence_status 为接口契约）。理由：打分可解释性（FR7.2.1）与五维链质量（AC7.1.1）互不依赖，先夯实 T05 可持续回归。
- **[D3] Evidence 端点并入 T04 而非单列**：`GET /rows/{rid}/evidence` 是 `/api/v1/links` 的语义化包装（F3 plan A8），引用增删直接复用 F3 通用链接接口不新建端点（plan §3.1），工作量为检索线的自然延伸，并入 T04 避免碎片化。
- **[D4] 初版 rubric 数据起草并入 T05**：C-Q1(a) 决策由我方起草 S/O/D 三维 1–10 语义分档，作为 seed 数据随 rubric CRUD 交付（`evals/fmea_generation/sod_rubric_seed_v1.json`），不单列内容任务；客户研发/质量专家 APPROVED 评审节奏属业务流程，M4 Exit 前置检查推动（plan §6 风险表），不阻塞 T05 交付（无 APPROVED 时回落 DRAFT 打分 + 「依据未定版评分标准」标识已在 T05 验收）。
- **[D5] LLM 以桩起步**：同 F3/F5/F6 手法——五维链生成单一 LLM 点经 LLMGateway 桩（确定性返回 + 可注入 schema 违例/空维度/超 50 行）跑通全部逻辑与降级路径（A3）；真实模型接入属部署联调，纳入 T13 跑分与 T14 验收，不单列任务。
- **[D6] KPI ↓≥60% 的基线依赖**：`fmea.generate` 与 start→approve 耗时打点在 T01/T06/T09 落地，但 ↓≥60% 达标判定依赖 F10.6.3 人工基线测量（M1 交付项，plan §6 风险表）——T14 仅核对耗时数据可出具，达标判定与 F10 联合进行，不作为 F7 单独阻塞项。
- **[D7] 任务粒度校验**：拆解结果 14 条 ≤ 15 条上限，plan 粒度合格（无超 2 人日任务），无需回改 plan；若实现期 T03（生成管线核心）或 T06（管线编排）超期，优先在 T03 内按 gather/llm_chain/validate 再拆分而非新增顶层任务。
- **[D8] clarifications 全文有效**：C-Q1（rubric 我方起草 DRAFT 初版 + 专家 APPROVED 生效 + 未定版回落 DRAFT + 「依据未定版评分标准」标识 + 分值随行快照固化 + 评测集 3 项目金标不入线上库）已落位 T05、T13；C-Q2（AIAG 经典 RPN 体系 + 红≥100/橙50–99/绿<50 阈值 + 阈值配置化快照 + VDA-SSR/AP 列 Phase 2）已落位 T02、T05、T11；C-Q3（单次 ≤50 行确定性截断 + 事件提示、单版本 ≤200 行配额、配置项、分区域追加批次、增行计入/删行释放、截断不调 LLM 复核）已落位 T01、T03、T06、T08、T11 的目标与完成标准；plan §7 假设①（水印以 state≠APPROVED 为准）→ T10、假设②（客户端排序筛选）→ T11、假设③（diff append-only）→ T02、假设④（DRAFT 软删）→ T02、假设⑤（weight 预留）→ T02、假设⑦（F9.6 经 rows/batch）→ T08、假设⑧（root_id+revision 链 + origin_row_id 血缘）→ T02/T09 分别落位。
