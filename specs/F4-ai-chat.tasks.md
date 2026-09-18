# F4 AI Chat / AI助手 — 任务清单（Tasks）

| | |
| ---- | ---- |
| Feature | F4-ai-chat |
| 输入 | specs/F4-ai-chat.md、specs/F4-ai-chat.clarifications.md（C-Q1–Q3）、specs/F4-ai-chat.plan.md（冲突时以后两者为准）、specs/README.md |
| 关联 | specs/F10-platform-governance.tasks.md（M1 骨架 + platform/task 服务 + OBJECT_REGISTRY 为前置）、specs/F1-document-parsing.tasks.md（上传/解析任务/统一解析模型为前置）、specs/F3-rag-retrieval.tasks.md（retrieval+generation service 与金标集机制为前置）、specs/F5–F9 各 tasks.md（「F4 技能复用同一入口」service 发起函数为对端契约） |
| 阶段 | speckit-tasks |
| 粒度约定 | 每条任务 0.5–2 人日；超过 2 人日须继续拆分 |
| 前置 | F10 M1 骨架（LLMGateway/prompt_registry/审计通道/require_perm/kpi_events/KPI SQL 视图/OBJECT_REGISTRY）、F1 上传校验与 type=parse 任务链路、F3 retrieval+generation service 与 `rag.query` 审计、F5–F9 各技能 service 发起入口（未就绪期间以桩适配器注册，见 [D3]） |

> 依赖列格式：依赖的任务号。编号即执行顺序（可并行：T03/T04/T07/T08 相互独立；T10 与 T12 可并行；T13 与 T14 前半段可并行）。

---

## 任务清单

### T01 F4 接入点骨架：审计事件定义、状态机接线、权限点、KPI 埋点

- **目标**：一次性定义 F4 挂接 F10 的接入点——① 审计事件：`chat.message`（每条消息一条；载荷契约：路由结果 `route:{intent, confidence, candidates}` 与回流来源 source（spec §5「含路由结果与置信度」的落点）、AI 生成消息的 model/prompt_version/kb_version 运行时快照；回流信息随 meta 记录，**不新增事件名**——F4 不扩充 F10.3.3 事件清单，plan §2.5）；`task.created / task.canceled` 确认为 platform/task 服务 emit 挂点（本任务只登记字段契约，实现在 T08）；② 状态机接线：`chat_sessions.state` 保留默认值、**不注册** transition 配置（会话非 DRAFT→APPROVED 生成物，plan §2.5）；`task.status` 为任务生命周期态、与 F10 `state` 定版状态机正交的架构注释（F1 plan A8 手法）；③ 权限点：`chat.use`（创建会话/发消息/上传，项目成员内）、`chat.config.manage`（仅 AI管理员）；技能发起复用各模块权限点（specdiff.run / bomdiff.run / fmea.generate / testgen.run / report.import，spec §5）；④ KPI 埋点契约：`chat.first_token`（duration_ms，POST messages → 首个内容增量，P95 ≤ 5s）、`task.duration`（按 type，finished−started）、`route.accuracy`（双口径：金标回归离线产出 + 线上 candidate_click/manual_reroute 占比月度统计 meta）注册进 F10 KPI SQL 视图（FR10.6.1）。同时登记本 feature 错误码（`PROJECT_REQUIRED / PROJECT_FORBIDDEN / SESSION_NOT_FOUND / MESSAGE_EMPTY / MESSAGE_TOO_LONG / INTENT_INVALID / PARAMS_INCOMPLETE / TASK_NOT_FOUND / TASK_NOT_CANCELED / TASK_NOT_RETRYABLE / UPLOAD_TOO_LARGE / UPLOAD_TYPE_UNSUPPORTED / CHAT_CONFIG_FORBIDDEN`，plan §3.2）与 prompt 注册表条目骨架 `f4.intent_classify / f4.general_chat`（FR10.3.4，禁裸字符串）。
- **涉及文件/模块**：`apps/backend/app/modules/platform/audit/events.py`（F4 事件段追加）、`app/modules/chat/constants.py`（权限点/错误码）、`app/modules/platform/kpi/views.sql`（三个 KPI 视图段）、`app/modules/platform/prompts/registry.py`（f4.* 条目）、`app/modules/platform/workflow/configs.py`（F4 无注册项的显式注释）
- **完成标准**：事件/权限/错误码/prompt 常量表与 spec §5、plan §2.5/§3.2 逐条对应并有单元断言；三个 KPI 事件写入 kpi_events 后可被 SQL 视图聚合（`chat.first_token` 分位数查询冒烟）；状态机无 F4 注册项的架构测试（防误加定版流，plan §2.5）
- **依赖**：无（复用 F10 M1 已有 T01 常量骨架）
- **粒度**：0.5 天

### T02 数据模型 + 迁移：chat_sessions / chat_messages / route_feedback_pool / tasks（F4.1.3、F10.1、C-Q1/C-Q2）

- **目标**：`chat_sessions`（继承 F10 BaseEntity：user_id、title（首条消息确定性截取）、context JSONB（A4：attached_documents[]/collected_params{}/page_context{}）、last_message_seq 游标、user_last_seen_seq 水位（FR4.5.3）、last_message_at，plan §2.1）；`chat_messages`（UNIQUE(session_id, seq)、role/type 枚举、payload JSONB 四类按 type 约定（task_card 仅存 {task_id}，A5 投影非快照）、model/prompt_id/prompt_version/kb_version 审计冗余列，plan §2.1）；`route_feedback_pool`（utterance/predicted_intent/candidates/resolved_intent/source ∈ clarify|candidate_click|manual_reroute、status pending|imported、golden_set_id 回链、UNIQUE(message_id, source)、utterance 归一化去重，plan §2.2）；`tasks` 全字段落地（project_id NOT NULL、session_id、origin chat|workbench、type 6 技能+parse、status 状态机五态、progress、stage、result_ref、result_stats JSONB（C-Q1 快照）、error_code/error_message、retry_of_task_id、时间列；索引 (created_by, status)/(session_id, created_at)/(project_id, type, status)，plan §2.3）并在 F10 OBJECT_REGISTRY 登记；`golden_sets` 新增行 kind='route'（expected JSONB `{intent}`，复用 F1 表只增不改，F3 plan A9 先例，plan §2.4）。Alembic 迁移。
- **涉及文件/模块**：`app/modules/chat/models.py`、`app/modules/platform/tasks/models.py`、`app/modules/platform/objects/registry.py`（Task 登记）、`app/modules/evals/models_ext.py`（golden_sets kind='route'）、`alembic/versions/*`
- **完成标准**：迁移可上下执行且 golden_sets 仅新增带默认列（FR10.1.4 只增不改 checklist）；UNIQUE(session_id, seq) 与 UNIQUE(message_id, source) 生效断言；三个查询索引存在性迁移测试；chat_sessions BaseEntity 公共列齐备且无 transition 注册（FR10.1.3）；tasks 状态列 CHECK 约束覆盖五态（specs/README 状态机）
- **依赖**：T01
- **粒度**：1.5 天

### T03 会话与消息服务：项目绑定、seq 分配、游标分页、未读水位（F4.1.3、F4.3）

- **目标**：`POST /api/v1/chat/sessions`（必带 project_id + 校验 project_members 成员关系，缺→`PROJECT_REQUIRED`、非成员→403 `PROJECT_FORBIDDEN`（FR4.3.3，A10）；page_context 随会话写入 context）；`GET /sessions`（仅本人会话，?project_id 分页 `{items,total,page}`）；`GET /sessions/{id}`（context/项目/未读数 + 消息 `after_seq` 游标分页，plan §3.2 例外口径）；seq 行锁单调分配（last_message_seq 游标）与 title 首条消息确定性截取；`POST /sessions/{id}/seen` 回写 user_last_seen_seq 水位（幂等，未读数清零，FR4.5.3）；未读完成数计算（水位之前的任务终态变更数，A5）。项目绑定不可变约束：会话创建后 project 不可变（切项目=新会话，FR4.3.2，服务层无改项目通道）。
- **涉及文件/模块**：`app/modules/chat/sessions/service.py`、`app/modules/chat/api/sessions.py`、`app/modules/chat/schemas.py`
- **完成标准**：无 project_id 建会话返回 `PROJECT_REQUIRED`、非项目成员 403 `PROJECT_FORBIDDEN` 统一错误体（FR4.3.3）；seq 并发分配单调不重（UNIQUE 冲突重试测试）；after_seq 游标分页正确处理增量追加；seen 幂等且未读完成数随水位递减（FR4.5.3）；会话无任何修改 project_id 的接口（架构断言，FR4.3.2）；消息 history 持久化可回溯（FR4.1.3）
- **依赖**：T02
- **粒度**：1.5 天

### T04 SkillInvoker 注册表 + 参数收集状态机（A1、A4）

- **目标**：`SkillInvoker` 注册表：七意图 → {service 发起函数, param_schema, 缺参引导文案, 关键词特征表（A9 兜底用）, 后续动作按钮配置（FR4.4.2 映射表）}——spec_diff→`specdiff.run_service`、bom_diff→`bomdiff.run_service`、fmea_gen→`fmea.generate_service`、testcase_gen→`testgen.run_service`、report_gen→`report.draft_service`（A1：与公开 API 同一入口、同一权限点、同一参数校验；knowledge_qa/general_chat 为进程内处理器）；参数收集状态机（A4）：每条消息先做附件/实体抽取（文件消息挂 attached_documents、page_context 随会话创建写入）→ 按 param_schema 判定 missing_params → 缺参引导文案（"请选择或上传两份规格书"等，确定性模板）→ 用户补齐后同意图参数继续累积直至齐备；`collected_params` 按意图分桶持久化进 session.context。
- **涉及文件/模块**：`app/modules/chat/router/skills.py`（注册表）、`app/modules/chat/router/params.py`（状态机）、`app/modules/chat/router/context.py`（附件/实体抽取）
- **完成标准**：注册表完整性单测——七意图全覆盖、每意图 param_schema 与对应技能 service 发起函数签名一致（schema 漂移即测试失败，plan §6 风险缓解）；missing_params 判定（spec_diff 缺两份文档 / bom_diff 缺两份 BOM / report_gen 缺测试数据+用例集分支）；参数跨轮累积后自动判定齐备（FR4.2.4）；附件抽取挂载 attached_documents（FR4.1.1）；注册表内无任何技能业务逻辑（编排层零技能逻辑的架构断言，A1）
- **依赖**：T01、T02
- **粒度**：2 天

### T05 意图分类服务：LLM 结构化输出 + 超时降级 + 澄清模板 + 回流入池（A3、A8、A9；FR4.2.1/4.2.2）

- **目标**：`f4.intent_classify` 经 LLMGateway（温度 0，独立模型配置 `chat.classify_model`）：输入当前消息 + 最近 N=3 轮摘要 + 已收集参数 + 页面上下文引用 → 结构化输出 `{intent, confidence, candidates≤3, missing_params[], schema_version}`，代码层 JSON Schema 校验 + 七意图枚举白名单，校验失败视为分类失败；超时降级（A9）：挂 2.5s 超时（`chat.classify_timeout_ms`），超时/失败切关键词规则兜底（T04 注册表特征表），confidence 强制 <0.6 → 走澄清分支，route.source=rule_fallback 标记；澄清消息为确定性模板槽位填充（"你是想做【规格书对比】还是【BOM比对】？"）+ candidates 候选按钮，反问环节零 LLM 调用（A3）；三类回流样本入 route_feedback_pool（source=clarify/candidate_click/manual_reroute，UNIQUE(message_id, source) + utterance 归一化去重，A8/C-Q2）；分类结果与置信度全量随 chat.message 审计（T06 接线，本任务产出结构）。
- **涉及文件/模块**：`app/modules/chat/router/classifier.py`、`app/modules/chat/router/fallback_rules.py`、`app/modules/chat/router/clarify.py`、`app/modules/chat/router/feedback_pool.py`
- **完成标准**：schema 校验单测（枚举白名单/confidence 边界/candidates 截断/非法输出判失败，A3）；降级路径单测——LLM 超时注入 → 规则兜底命中且 confidence<0.6 且 source=rule_fallback（A9）；澄清文本模板生成与候选按钮渲染数据（FR4.2.2）且路径 LLM 调用数为分类 1 次（A3 断言）；三类样本入池 + 去重断言（C-Q2）；分段计时（classify 段）可入 kpi meta（A9）
- **依赖**：T04
- **粒度**：2 天

### T06 核心编排端点：POST messages SSE + POST /route 显式重路由（A2；FR4.2.2/4.2.3/4.5.1/4.5.2）

- **目标**：`POST /api/v1/chat/sessions/{id}/messages`（`chat.use` + 项目成员校验）：落 user 消息 + emit 审计 `chat.message` → T05 意图分类 → SSE 响应（恒为 text/event-stream，A2）：`meta → route → …`；分支① confidence<0.6 → `clarify` 事件（模板 + candidates）→ done，样本入回流池（FR4.2.2）；分支② 技能型意图 → T04 参数收集：缺参 → `param_missing` 引导（FR4.2.4）→ done；齐备 → 并发闸门检查（T08，超限 task_card 附"已排队（前方 N 个）"提示，FR4.5.4）→ SkillInvoker 发起（传 origin='chat' + session_id + collected_params，A1）→ system_notice「已为您启动【X】」（FR4.2.3）→ `task_card` 事件 → done（异步进度走 /tasks/{id}/events，A2）；首个内容增量 emit KPI `chat.first_token`；异常以 `error` 事件 + 统一错误体。`POST /sessions/{id}/route`（FR4.2.2 候选点选 / FR4.2.3 手动切换重路由）：显式 intent（未注册→`INTENT_INVALID`）→ 异步技能 202 {task_id, task_card message_id} / knowledge_qa → SSE；两类样本入池（candidate_click/manual_reroute，A8）。流结束后 HTTP 连接即释放（异步技能不占长连接）。
- **涉及文件/模块**：`app/modules/chat/api/messages.py`、`app/modules/chat/api/route.py`、`app/modules/chat/streaming/`（事件组流与契约）、`app/modules/chat/router/orchestrator.py`
- **完成标准**：SSE 事件序列契约测试——三分支各自合法事件序（clarify 分支 meta→route→clarify→done；技能分支 meta→route→task_card→done；param_missing 分支，A2）；消息文本+文件可同发（FR4.1.1）；`chat.message` 审计字段完备性 schema 校验（route 结果/置信度/回流来源/AI 消息 model-prompt-kb_version，spec §5）；system_notice「已为您启动【X】」+ 手动切换重路由入池（FR4.2.3）；缺参引导而非报错（`PARAMS_INCOMPLETE` detail 列缺失项，FR4.2.4）；/route 202 与 SSE 双形态（FR4.2.2/4.2.3）；first_token 埋点在首个内容增量触发（spec §5）
- **依赖**：T03、T05、T08（task 创建与闸门契约）
- **粒度**：2 天

### T07 会话上传：F1 包装 + CAD 确定性拦截 + 解析上下文注入（A6；FR4.1.1/4.1.2）

- **目标**：`POST /api/v1/chat/upload`（multipart file + session_id，`chat.use`）：转发 F1 上传校验（错误码 `UPLOAD_TOO_LARGE/UPLOAD_TYPE_UNSUPPORTED` 透传不静默）→ 触发 F1 `parse` 任务（type=parse 任务卡，无后续动作区、无风险统计，C-Q1）→ file 消息落流（payload: document_id/filename/parse_task_id）；parse SUCCESS 回调把 `{document_id, doc_version, parse_state}` 注入 `session.context.attached_documents`（FR4.1.1「解析后进入当前会话上下文」落点），失败透传 F1 错误码；CAD 扩展名（stp/step/dwg/dxf/ipt/sldprt）入口即判：文件存档为项目文档（F2 分类"设计"，标记 archived_cad）+ system_notice 固定提示文案「Phase 1 暂不支持 CAD 文件解析，文件已保存到项目文档（存档）」（FR4.1.2），**不建解析任务、不进参数收集**（A6）。
- **涉及文件/模块**：`app/modules/chat/upload/api.py`、`app/modules/chat/upload/service.py`、`app/modules/chat/upload/cad_guard.py`、`app/worker/tasks/chat_parse_callback.py`
- **完成标准**：会话上传 → F1 校验透传 + parse 任务卡返回 {document_id, task_id}（FR4.1.1）；SUCCESS 后 attached_documents 注入断言 + 后续「对比这两个文件」参数收集可命中两份文档（端到端桩测，FR4.1.1）；解析失败错误码透传不静默（F1 契约）；CAD 上传 → 201 + archived_cad:true + 固定提示、无解析任务、不进参数收集（FR4.1.2、A6）；parse 卡片无动作区无风险统计（C-Q1）
- **依赖**：T03、T08（parse 任务创建契约）；外部前置 F1 上传/解析链路
- **粒度**：1 天

### T08 tasks 服务 + 并发闸门 dispatcher + cancel/retry/批量刷新（A5、A7；FR4.4.3/4.5.1/4.5.3/4.5.4）

- **目标**：platform/task 服务：任务创建（技能 service 经此创建 Task 行并回填 session_id，emit `task.created`）、状态/progress/stage 更新、SUCCESS 写 result_stats 快照（C-Q1 schema `[{key,label,value,level?}]`，只读镜像）、FAILED 写 error_code/error_message、emit `task.canceled`；`GET /api/v1/tasks/{id}/events` SSE（status/progress/stage/result_stats 变更推送，FR4.5.1）；`GET /tasks?ids=` 批量当前态（≤50/次，回到会话刷新，A5）；`POST /tasks/{id}/cancel`（QUEUED 直接置 CANCELED、RUNNING 协作式取消信号、终态→`TASK_NOT_CANCELED`，FR4.4.3）；`POST /tasks/{id}/retry`（仅 FAILED→`TASK_NOT_RETRYABLE`，新任务 retry_of_task_id 回链 + 新任务卡，FR4.4.3）；并发闸门 dispatcher（A7）：chat 轻量 Celery beat 任务 + `SELECT ... FOR UPDATE` 用户级信号量行，每用户 RUNNING ≤ `chat.max_concurrent_tasks`（默认 3），容量空出按 FIFO 将 QUEUED 派发至各技能队列（只控启动闸门不搬执行），计数对账兜底任务；`GET/PUT /api/v1/chat/config`（AI管理员 `chat.config.manage` 调 max_concurrent_tasks/classify_timeout_ms，`CHAT_CONFIG_FORBIDDEN`，审计随 chat.message 携带变更记录，plan §3.1）。
- **涉及文件/模块**：`app/modules/platform/tasks/service.py`、`app/modules/platform/tasks/api.py`（cancel/retry/batch/events）、`app/worker/tasks/chat_dispatcher.py`、`app/modules/chat/api/config.py`、`app/modules/chat/config.py`
- **完成标准**：/tasks/{id}/events 推送 status/progress/stage 变更契约测试（FR4.5.1）；批量端点 ≤50 上限与部分不存在语义（FR4.5.3）；cancel 幂等（重复取消返回当前态）与 QUEUED 即时生效/RUNNING 协作取消分支（FR4.4.3）；retry 产生新任务且 retry_of_task_id 回链（FR4.4.3）；并发闸门——第 4 个任务 QUEUED 排队、完成一个后 FIFO 自动出队、并发创建计数无漂移（FOR UPDATE 串行化测试，FR4.5.4、A7）；对账任务修正人为计数偏差；PUT /chat/config 权限矩阵（AI管理员可写、工程师 403）+ 审计（plan §3.1）；task.created/canceled 事件入审计导出（spec §5）
- **依赖**：T02
- **粒度**：2 天

### T09 knowledge_qa 复用 F3 + general_chat 直答（A1；FR4.2.5）

- **目标**：分支③ knowledge_qa：进程内调 F3 retrieval+generation service（不经其 conversation 层、不建 rag_conversation 行——chat_messages 最近 N=3 轮作为上下文传入 query 改写，A1），SSE 流内 `reply*` 增量 → `sources`（F3 结构）→ done；F3 侧 `rag.query` 审计与引用校验原样生效、chat 侧另 emit `chat.message`（同轮双事件各司其职，spec §5）；no_hit/灰区语义沿 F3 契约透传（done.no_hit）。分支④ general_chat：`f4.general_chat` prompt 直答（FR4.2.5），prompt 负面约束（禁编造业务数据、禁承诺平台外操作），**不创建任何 Task/业务对象**（代码层无此通路）；AI 生成消息落 model/prompt_version 快照（FR10.3.1）。
- **涉及文件/模块**：`app/modules/chat/router/qa.py`、`app/modules/chat/router/general.py`、`app/modules/chat/api/messages.py`（分支接线）
- **完成标准**：knowledge_qa 直通 F3——检索 stub 断言调用参数与传入上下文轮数（≤3 轮）、不建 rag_conversation 行（A1 断言）；答案流式增量 + sources 事件下发（FR4.2.5、FR4.5.2 同步路径）；同轮 `rag.query` + `chat.message` 双事件落审计且 kb_version 一致（spec §5）；general_chat 流式直答且零 Task/业务对象创建断言（FR4.2.5，plan §6 滥用防护测试）；AI 消息 model/prompt_version 快照列非空（FR10.3.1）
- **依赖**：T06；外部前置 F3 retrieval+generation service
- **粒度**：1.5 天

### T10 前端共享会话引擎 + 两形态入口（C-Q3；FR4.1.1/4.1.2/4.2.2/4.2.3/4.3.1）

- **目标**：`features/chat/` 共享引擎组件：message-list（text/file/task_card/system_notice 四类渲染，FR4.1.3）、clarify-buttons（候选意图按钮 + 手动切换意图，FR4.2.2/4.2.3）、upload（文件上传 + CAD 提示条 + 解析任务卡进度，FR4.1.1/4.1.2）、param-missing 引导条（FR4.2.4）；`features/project-picker/`（新会话必选项目、Copilot 头部常显当前项目，会话中切换弹确认新建，FR4.3.1/4.3.2）；两形态入口：`pages/workbench/` 首页独立大输入区 + `features/copilot/` 右侧常驻（默认展开可收起、继承当前页面项目与 page_context、会话列表/消息流/输入框）——仅入口布局差异，共享同一会话引擎（C-Q3）；[AI] 标识（知识问答/闲聊答案，specs/README）；`GET /chat/config` 读取排队提示所需配置（A7）。
- **涉及文件/模块**：`apps/frontend/src/features/chat/*`、`features/copilot/*`、`features/project-picker/*`、`pages/workbench/*`
- **完成标准**：组件测试——四类消息渲染（FR4.1.3）；澄清候选按钮点击走 /route 且切意图按钮重路由（FR4.2.2/4.2.3）；CAD 上传渲染提示条且无解析卡（FR4.1.2）；缺参引导条展示 missing_params（FR4.2.4）；项目选择器新会话必选、头部常显、切换确认新建（FR4.3.1/4.3.2）；两形态一致性断言——同一会话流在大输入区与 Copilot 渲染/交互行为一致（C-Q3）；Copilot 继承页面所在项目创建会话（FR4.3.1，前端集成测试）；[AI] 标识
- **依赖**：T03、T06、T07
- **粒度**：2 天

### T11 前端任务卡 + 实时进度订阅 + 断线恢复（A5；FR4.4.1–4.4.3、FR4.5.3、AC4.4.1）

- **目标**：`features/chat/task-card/`：渲染任务名/类型/状态（排队中/执行中(进度%)/成功/失败/已取消）/risk_stats（result_stats 快照，C-Q1 schema；parse 卡无统计无动作区）/后续动作按钮区——按 FR4.4.2 映射表逐技能配置（查看对比报告、查看差异明细/生成FMEA/创建整改任务、查看/编辑 FMEA、查看用例集、查看报告/创建问题单），点击跳转对应工作台并预填上下文；FAILED 卡显示失败原因码 + 「重试」（FR4.4.3）；「查看最新」跳结果对象页（C-Q1 Assumptions 只读快照口径）；`features/chat/use-task-events.ts`：订阅 `/tasks/{id}/events` 实时更新卡片（AC4.4.1）、断线/回归时 `GET /tasks?ids=` 批量刷新、`user_last_seen_seq` 水位计算未读完成数角标 + `/seen` 回写（FR4.5.3）；排队提示「已排队（前方 N 个）」（FR4.5.4）；取消/重试按钮调用对应端点。
- **涉及文件/模块**：`apps/frontend/src/features/chat/task-card/*`、`features/chat/use-task-events.ts`
- **完成标准**：组件测试——卡片字段完备渲染与五态展示（FR4.4.1）；mock SSE 下卡片实时进度更新至完成、动作按钮可用（AC4.4.1）；FR4.4.2 五技能后续动作路由逐条断言（跳转+预填）；FAILED 卡原因码 + 重试调用且新卡出现（FR4.4.3）；断线重连后批量刷新恢复当前态、未读完成数角标正确、seen 回写清零（FR4.5.3，AC4.5.1 配套）；排队提示展示（FR4.5.4）；risk_stats 按 C-Q1 schema 渲染、parse 卡无动作区（C-Q1）
- **依赖**：T08、T10
- **粒度**：2 天

### T12 金标集与路由评测：golden_set_route_v1（A8、C-Q2；AC4.2.1）

- **目标**：`golden_sets`（kind='route'）装载 `golden_set_route_v1`：七意图 × ≥20 条（共 ≥140 条，双人标注+仲裁流程）；离线评测脚本——总体准确率 + 七意图分项报表（AC4.2.1 ≥90% 为 M2 Exit 硬门槛）、规则兜底路径单独评测（降级时澄清率 100%、误路由 0，A9）、分类时延 P95 报表（A9 预算核对）；prompt 版本/模型变更全量回归门禁流程（不达标禁发布，C-Q2）；回流池 → 月度人工复审 → 入金标 → `golden_set_route_vN` 发版流程 dry-run（C-Q2 Assumptions：Phase 1 经审计导出+人工入池，不做自动标注工具）；`route.accuracy` 线上口径（candidate_click/manual_reroute 占比月度统计）报表。
- **涉及文件/模块**：`app/modules/chat/evals/`、`evals/chat/golden_set_route_v1.json`、`eval/run_route_eval.py`、评测报告（specs/ 下 F4 评测记录）
- **完成标准**：评测脚本对金标集可重复运行并输出总体+分项报表；≥90% 判定逻辑落地且 <90% 时门禁 FAIL（AC4.2.1，M2 正式验收目标）；规则兜底路径澄清率 100%/误路由 0 断言（A9）；发版流程 dry-run 走通（入池→标注→版本化→回归，C-Q2）；内部自建金标先跑通管线，标注资源延迟不阻塞（[D3] 同 F3 模式）
- **依赖**：T05
- **粒度**：1.5 天

### T13 性能与稳定性：首 token SLO 压测 + 闸门吞吐（spec §5、plan §6）

- **目标**：knowledge_qa 端到端首 token P95 ≤ 5s 压测（`chat.first_token` KPI，分段计时 classify/recall/first_reply 入 kpi meta 定位超标段，A9）；分类 ≤2.5s 预算验证与降级频率监控（rule_fallback 占比）；SSE 长连接并发与断线重连风暴测试（双 SSE 端点并存场景，A2）；并发闸门下 100 任务/用户队列吞吐 + dispatcher beat 周期出队延迟 ≤30s 验证（plan Assumptions）；每用户同步问答速率限制（同 F3 plan §6 滥用防护）。
- **涉及文件/模块**：`evals/chat/bench_first_token.py`、`evals/chat/bench_dispatcher.py`、`app/modules/chat/config.py`（限流/超时参数）、压测报告
- **完成标准**：压测报告显示 chat.first_token P95 ≤ 5s（或附超标段定位与缓解记录，spec §5）；分类段 ≤2.5s 预算达标或降级路径生效记录（A9）；SSE 重连风暴下无状态错乱（A5 批量刷新兜底验证）；闸门下队列吞吐达标且出队延迟 ≤30s（FR4.5.4、plan Assumptions）；限流超限返回统一错误体
- **依赖**：T06、T08、T09
- **粒度**：1 天

### T14 端到端验收（覆盖 F4 全部 AC）

- **目标**：演示环境全链路验收：选择项目创建会话（FR4.3.1，非成员 403 FR4.3.3）→ 会话上传规格书两份（parse 任务卡进度 → 文件进上下文，FR4.1.1）→ CAD 文件上传即时存档提示（FR4.1.2）→ 输入「帮我对比这两份规格书」高置信直达（route → 「已为您启动【规格书对比】」+ 任务卡，FR4.2.3）→ 低置信表述触发澄清候选按钮、点选重路由（FR4.2.2，样本入池）→ 手动切换意图重路由（FR4.2.3）→ 缺参数场景引导补齐后自动发起（FR4.2.4）→ 发起 BOM 比对：卡片在对话流出现并实时更新进度直至完成、动作按钮可用（**AC4.4.1**）→ 第 4 个任务排队提示、完成后自动出队（FR4.5.4）→ 失败任务原因码 + 重试回链（FR4.4.3）→ QUEUED 取消即时生效（FR4.4.3）→ 发起 FMEA 生成后关闭浏览器、5 分钟后回归任务已完成卡片状态正确 + 未读完成数（**AC4.5.1**）→ 知识问答流式答案带来源、首 token 响应（FR4.2.5/4.5.2）→ 闲聊不产出业务对象（FR4.2.5）→ 审计导出核对（chat.message 路由置信度/AI 快照、task.created/canceled；回流池三类样本在册，C-Q2）→ KPI 视图聚合（chat.first_token/task.duration/route.accuracy）→ 金标集全量评测报告 ≥90%（**AC4.2.1**，标注金标版本，[D3]）→ 私有化核对（分类模型/生成 LLM 经 LLMGateway 本地化，外呼=空项 F4 范围核对）。产出验收核对单逐项勾稽。
- **涉及文件/模块**：`apps/backend/tests/e2e/test_f4_acceptance.py`、F4 验收核对单（`specs/` 下 F4 验收记录）
- **完成标准**：以下 AC 全部通过——**AC4.2.1**（金标路由准确率 ≥ 90%，七意图分项报表齐备）、**AC4.4.1**（BOM 比对卡片实时更新至完成、动作按钮可用）、**AC4.5.1**（关闭浏览器 5 分钟后回归任务已完成且卡片状态正确）；并以用例覆盖 FR4.1.1–4.1.3、FR4.2.1–4.2.5、FR4.3.1–4.3.3、FR4.4.1–4.4.3、FR4.5.1–4.5.4；新增模块行覆盖率 ≥80%（全局规则）
- **依赖**：T09、T11、T12、T13
- **粒度**：1 天

---

## 任务依赖图

```text
T01 → T02 ─┬→ T03 ─────────────┐
           ├→ T04 → T05 ─┬→ T06 ┼→ T09 ─┐
           └→ T08 ───────┤      ├→ T07 ─┤
                         │      │       ├→ T14
              T10（依赖 T03/T06/T07）─┴→ T11 ┤
              T12（依赖 T05）───────────────┤
              T13（依赖 T06/T08/T09）───────┘
可并行：T03 / T04 / T07（闸门契约后）/ T08（仅依赖 T02）；T10 与 T12 可并行
```

并行建议：T08（tasks 服务与闸门）与 T03/T04 并行（T06 依赖其契约，接口先行定义）；T07 在 T03/T08 后即可插入；T10 前端引擎在 T03/T06/T07 契约冻结后与 T12 金标评测并行；T11 依赖 T08/T10；T13 与 T14 前半段（功能链路勾稽）可并行，压测通过为 T14 收口前置。

---

## Breakdown 决策与假设（Clarifications / Assumptions）

- **[D1] 集成测试不单列任务**：与 F3 [D1] 同构——SSE 事件序列契约、项目权限 403、参数收集状态机、闸门并发、审计 schema 校验等集成测试全部**绑定进 T03–T09 各自的完成标准**，不设独立测试任务；跨 feature 对端契约（F1 上传/parse、F3 检索+生成、F5–F9 service 入口）分别在 T07/T09/T04 内覆盖。
- **[D2] T06 与 T08 接口先行**：T06（编排端点）依赖 T08 的任务创建与闸门契约，但不依赖其实现——两者先冻结 service 接口签名（create_task / acquire_slot / task_card 组装），T06 以桩驱动开发，与 F3 [D2] 的「契约先行、夹具驱动」手法一致。
- **[D3] F5–F9 service 入口以桩适配器起步**：F4 属 M2，五个技能模块（M3/M4）的 service 发起函数未实现——SkillInvoker 注册表按 plan §1.3 A1 锁定的入口签名注册桩适配器（确定性返回 + 可注入延迟/失败），跑通全部编排/闸门/任务卡链路；真实技能接入随 F5–F9 落地做契约回归（各技能 plan 已把「F4 复用同一入口」列为其验收项）。AC4.4.1/AC4.5.1 在 T14 以 bom_diff/fmea_gen 桩（真实任务状态机语义）验证，正式达标核对在对应技能 feature 验收时复核并标注。
- **[D4] LLM 以 LLMGateway 桩起步**：意图分类与 general_chat 的模型均为私有化部署外部服务（plan §4），开发期以网关桩（确定性结构化输出 + 可注入超时/非法 schema）跑通逻辑与测试；真实模型接入属部署联调，纳入 T13 压测与 T14 验收，不单列任务（F3 [D4] 同模式）。
- **[D5] 金标集数据就绪节奏（T12）**：≥140 条双人标注依赖业务方资源（C-Q2），T12 先以内部自建金标集跑通评测管线与 ≥90% 门禁判定脚本；正式金标就绪后复测作为 M2 Exit 前置检查项，AC4.2.1 正式达标判定在 T14 核对单中标注「金标版本」（F3 [D3] 同模式）。
- **[D6] 配置端点归入 T08**：`GET/PUT /chat/config` 服务于并发上限（A7）与分类超时（A9）两类运行时配置，随闸门实现落地（T08），不单独成任务；T10 前端经 GET 读取排队提示配置。
- **[D7] 任务粒度校验**：拆解结果 14 条 ≤ 15 条上限，plan 粒度合格，无需回改 plan。
