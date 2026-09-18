# F4 AI Chat / AI助手 — 技术方案（Plan）

| | |
| ---- | ---- |
| Feature | F4-ai-chat |
| 输入 | specs/F4-ai-chat.md、specs/F4-ai-chat.clarifications.md（冲突时以其为准）、PHASE1_SPEC.md、PHASE1_FEATURES.md、specs/README.md |
| 关联 | specs/F10-platform-governance.plan.md（Task 对象/审计/KPI/RBAC/LLMGateway/Prompt 注册表）、specs/F3-rag-retrieval.plan.md（检索+生成服务复用、金标集机制先例、first_token SLO 同源）、specs/F1-document-parsing.plan.md（上传/解析任务/统一解析模型）、F5–F9 各 plan（「F4 技能复用同一入口」契约、任务卡后续动作目标页）、UI_GUIDE（页面01 + 右侧 Copilot + 页面30 上下文感知） |
| 阶段 | speckit-plan（仅设计，不写代码） |
| 里程碑 | M2 |

> 本 plan 中所有设计决策均标注溯源（FR/AC/Q 编号）。clarifications（Q1–Q3 决策）全文有效，本文引用处标注为「C-Qx」。

---

## 1. 架构与模块落点

### 1.1 总体架构

对齐既定技术栈：**后端 FastAPI 模块化单体 + Celery + PostgreSQL(pgvector) + MinIO；前端 React + TypeScript + Ant Design**。F4 是**编排层（orchestration）**，落在独立顶层模块 `modules/chat/`：它不实现任何技能业务逻辑，只负责 会话/消息持久化、意图识别与路由、参数收集、任务卡投影、进度订阅与项目上下文绑定；五个任务型技能经 `SkillInvoker` 注册表调用 F5–F9 各自的 service 发起入口（与其公开 API 同一函数），`knowledge_qa` 进程内复用 F3 检索+生成服务，`general_chat` 直连 F10 `LLMGateway`（FR4.2.5、spec 头表被依赖关系、F5/F6/F7/F8/F9 plan 的「F4 技能复用同一入口」决策）。

```text
apps/backend/
├── app/
│   ├── core/                        # F10 平台地基（F10 plan）
│   ├── modules/
│   │   ├── chat/                    # ← F4 本体（编排层）
│   │   │   ├── api/                 # sessions/messages/route/upload/config 路由
│   │   │   ├── sessions/            # F4.1/F4.3：会话与消息持久化、seq 分配、项目绑定、未读水位
│   │   │   ├── router/              # F4.2：意图分类编排、参数收集状态机、澄清/反问、重路由
│   │   │   ├── router/skills.py     # SkillInvoker 注册表：intent → {service 入口, param_schema, 动作按钮配置}
│   │   │   ├── tasks_projection/    # F4.4：Task→任务卡投影（status/risk_stats/后续动作）、批量刷新
│   │   │   ├── upload/              # F4.1.1/4.1.2：会话上传包装 F1、CAD 扩展名拦截、解析上下文注入回调
│   │   │   └── streaming/           # SSE 组流：meta/route/reply*/task_card/done/error（A2）
│   │   ├── documents/               # F1：上传与解析任务（chat/upload 的底层，type=parse 任务归 F1 队列）
│   │   ├── rag/                     # F3：knowledge_qa 复用其 retrieval+generation service（A1）
│   │   ├── specdiff/ bomdiff/ fmea/ testgen/ report/
│   │   │                            # F5–F9：技能执行本体与各自 Celery 队列（chat 不入其队列定义）
│   │   └── platform/                # F10：audit/rbac/kpi/prompts/objects/tasks（tasks 表在本 feature 落全字段，§2.3）
│   ├── worker/                      # Celery：chat 自身仅一个轻量 dispatcher（并发闸门，A7）；技能任务在各技能队列
│   └── main.py
└── alembic/
apps/frontend/
└── src/
    ├── pages/workbench/             # UI 页面01：首页独立大输入区（C-Q3 形态一）
    ├── features/copilot/            # 右侧常驻 Copilot（C-Q3 形态二，默认展开可收起）：会话列表、消息流、输入框
    ├── features/chat/               # 两形态共享引擎组件：
    │   ├── message-list/            #   消息流渲染（text/file/task_card/system_notice 四类，FR4.1.3）
    │   ├── task-card/               #   任务卡（状态/进度%/risk_stats/后续动作按钮区，FR4.4.1/4.4.2）
    │   ├── clarify-buttons/         #   澄清候选意图按钮 + 手动切换意图（FR4.2.2/4.2.3）
    │   ├── upload/                  #   文件上传 + CAD 拦截提示条（FR4.1.1/4.1.2）
    │   └── use-task-events.ts       #   SSE 订阅 hook：/tasks/{id}/events + 断线批量刷新（FR4.5.3，A5）
    └── features/project-picker/     # 项目选择器（新会话必选、Copilot 头部常显，FR4.3.1）
```

### 1.2 核心流程

```text
发消息（POST /chat/sessions/{id}/messages，A2 单端点双形态）：
  权限：require_perm("chat.use") + 项目成员校验（FR4.3.3，A10）
  → 落 user 消息（chat_messages，seq 单调）→ emit 审计 chat.message
  → 意图分类（FR4.2.1）：f4.intent_classify（消息 + 会话上下文/已收集参数 + 页面上下文引用）
      超时降级（A9）：>2.5s → 关键词规则兜底，confidence 强制置 <0.6
  → 分支① confidence < 0.6（FR4.2.2）：system_notice 澄清消息（确定性模板文本 + candidates[≤3] 候选按钮），
      SSE 回显后结束；样本入 route_feedback_pool(source=clarify)（C-Q2）
  → 分支② 技能型意图（spec_diff/bom_diff/fmea_gen/testcase_gen/report_gen）：
      参数收集（A4）：消息附件 + session.context(collected_params/attached_documents/page_context)
      按 SkillInvoker.param_schema 校验缺失 → 缺失则 system_notice 引导补齐（FR4.2.4），SSE 结束
      → 并发闸门（A7）：该用户 RUNNING ≥ 上限 → 任务创建后置 QUEUED 排队 + 提示（FR4.5.4）
      → SkillInvoker 调技能 service 发起入口（传 origin='chat', session_id, 已收集参数）
          技能 service 经 platform/task 服务创建 Task 行（session_id 回填）→ 入各自 Celery 队列
      → system_notice「已为您启动【规格书对比】」+ task_card 消息（payload.task_id，FR4.2.3）
      → SSE：route → task_card → done（HTTP 流结束；后续进度走 GET /tasks/{id}/events，FR4.5.1）
  → 分支③ knowledge_qa（FR4.2.5）：进程内调 F3 retrieval+generation（轮次上下文取 chat_messages 最近 N 轮）
      → SSE：route → reply*(答案增量) → sources → done；审计 rag.query（F3 service emit）+ chat.message
  → 分支④ general_chat（FR4.2.5）：f4.general_chat 直答（闲聊/平台使用咨询，不产业务对象）
      → SSE：route → reply* → done
  → 首个内容增量时 emit KPI chat.first_token（spec §5）

任务执行与进度（FR4.5.1，技能模块拥有）：
  技能 Celery 任务执行 → platform/task 服务更新 status/progress/stage
  → SSE /tasks/{id}/events 推送 → 前端 use-task-events 更新任务卡（AC4.4.1）
  → SUCCESS 时技能 service 写 result_stats 快照（C-Q1 映射表）+ result_ref → 卡片渲染后续动作按钮
  → FAILED 时写 error_code + 失败原因 → 卡片显示「重试」（FR4.4.3）

离开与回归（FR4.5.3 / AC4.5.1）：
  浏览器关闭不影响 Celery 执行；回到会话 GET messages(after_seq) + GET /tasks?ids= 批量刷新任务卡
  → user_last_seen_seq 水位之前的任务终态变更计为「未读完成数」角标
```

### 1.3 关键架构决策

| # | 决策 | 溯源 |
| ---- | ---- | ---- |
| A1 | **F4 为编排层、零技能逻辑**：`SkillInvoker` 注册表把七意图映射到各技能模块的 service 发起函数（与公开 API 同一入口、同一权限点、同一参数校验）——spec_diff→`specdiff.run_service`、bom_diff→`bomdiff.run_service`、fmea_gen→`fmea.generate_service`、testcase_gen→`testgen.run_service`、report_gen→`report.draft_service`（F5–F9 plan 已分别确立「F4 复用同一入口」）；Task 行由技能 service 经 platform/task 服务创建（保持 F5–F9 plan 的任务归属），chat 仅以参数传入 `origin='chat'` + `session_id` 完成关联，**不重复创建任务行**；knowledge_qa 进程内复用 F3 retrieval+generation service 但**不经其 conversation 层**——轮次上下文从 chat_messages 取最近 N 轮传入 query 改写，不建 rag_conversation 行（避免会话双份真相）；F3 的 `rag.query` 审计与引用校验原样生效 | FR4.2.5、FR4.2.1；spec 头表被依赖关系；F5 plan §5 权限、F6 plan 假设⑥、F7 plan A12、F8 plan A13、F9 plan A13、F3 plan A4/A6 |
| A2 | **POST messages 单端点双形态响应（SSE 流）**：响应恒为 `text/event-stream`，事件序列 `meta → route → (reply* → sources → done │ task_card → done │ clarify → done)`。同步技能（knowledge_qa/general_chat）流内增量下发答案；异步技能流内只下发路由结果 + task_card 后即结束（后续进度走全局 `/tasks/{id}/events`）。与 specs/README「生成/比对/解析类异步 + task_id」一致：异步技能的 SSE 仅承载「路由确认 + 卡片创建」，不承载任务进度 | FR4.5.1、FR4.5.2；spec §4（"同步技能SSE返回；异步技能返回task_id"）；specs/README 异步约定 |
| A3 | **意图分类为 LLM 结构化输出、澄清为确定性模板**：`f4.intent_classify`（温度 0，经 LLMGateway）输出 schema `{intent, confidence, candidates:[{intent,confidence}]≤3, missing_params[]}`；confidence < 0.6 时澄清消息的**反问文本由模板槽位填充生成**（如"你是想做【规格书对比】还是【BOM比对】？"），候选按钮直接渲染 `candidates`——反问环节不调 LLM（省时延、保确定性）；意图分类失败/超时按 A9 兜底 | FR4.2.1、FR4.2.2；F10 plan §4 挂点 1–3 |
| A4 | **参数收集为会话级状态机，上下文累积在 session.context**：`collected_params`（按意图分桶）、`attached_documents[{document_id, doc_version, parse_task_id, parse_state}]`、`page_context{object_type, object_id}`（C-Q3 Assumptions：仅注入引用不做 DOM 理解）。每条消息先做附件/实体抽取（确定性规则：文件消息直接挂 attached_documents；页面上下文随会话创建写入），再由 SkillInvoker 的 `param_schema`（每意图声明必填参数，如 spec_diff 需两份文档、bom_diff 需两份 BOM、report_gen 需测试数据+用例集）判定 missing_params → 引导补齐文案由技能注册表提供（"请选择或上传两份规格书"/"请先绑定项目"）。用户补齐后**同一意图的参数继续累积**直至齐备自动发起；用户也可经 `POST /route` 显式指定意图跳过分类器 | FR4.1.1、FR4.2.4、FR4.3.2；C-Q3 Assumptions |
| A5 | **任务卡是 Task 的对话侧投影，不存快照**：task_card 消息 payload 仅存 `{task_id}`，状态/进度/risk_stats 每次渲染时从 task 读取——避免状态漂移与双写；`result_stats` 快照由技能 service 在 SUCCESS 时一次性写入 `task.result_stats`（C-Q1 统一 schema `[{key,label,value,level?}]`，只读镜像，不随源对象后续处置刷新，卡片「查看最新」跳对象页，C-Q1 Assumptions）。前端 `use-task-events` hook 订阅 `/tasks/{id}/events`；断线/回归时以 `GET /tasks?ids=` 批量拉取当前态，`user_last_seen_seq` 水位计算未读完成数 | FR4.4.1–FR4.4.3、FR4.5.3、AC4.4.1；C-Q1 及 Assumptions |
| A6 | **会话上传 = F1 上传的会话语义包装 + CAD 确定性拦截**：`POST /chat/upload`（multipart + session_id）转发 F1 上传校验与 `parse` 任务（type=parse 任务卡，无后续动作区、无风险统计——C-Q1）；parse 任务 SUCCESS 后 chat 回调把 `{document_id, doc_version}` 注入 `session.context.attached_documents`（FR4.1.1"解析后进入当前会话上下文"的落点），失败透传 F1 错误码不静默丢弃。CAD 扩展名（stp/step/dwg/dxf/ipt/sldprt）在入口即判：文件存档为项目文档（F2 分类"设计"，标记 archived_cad）+ system_notice 固定提示文案，**不建解析任务、不进参数收集** | FR4.1.1、FR4.1.2；F1 plan §3.1 上传契约；C-Q1 |
| A7 | **并发闸门在 dispatcher：每用户 RUNNING ≤ N（默认 3，配置 `chat.max_concurrent_tasks`）**：任务创建（QUEUED）不受限、即时反馈；由 chat 模块轻量 dispatcher（Celery beat 周期任务 + `SELECT ... FOR UPDATE` 用户级信号量行）在容量空出时按 FIFO 把 QUEUED→派发给技能队列实际执行，超限创建时即在 task_card 上提示"已排队（前方 N 个任务）"。技能任务本体仍在各自 Celery 队列，dispatcher 只控制**启动闸门**，不搬运执行。取消（FR4.4.3）对 QUEUED=直接置 CANCELED、对 RUNNING=Cooperative 取消信号（技能任务在 stage 边界检查） | FR4.5.4、FR4.4.3、AC4.5.1；specs/README 任务状态机 |
| A8 | **路由金标集 + 低置信回流池落地 C-Q2 机制**：`golden_set_route_v1`（七意图 × ≥20 条，≥140 条，双人标注+仲裁）复用 F1 `golden_sets` 表新增 `kind='route'`（F3 plan A9 先例）；`route_feedback_pool` 承接三类回流样本（澄清触发 / 候选按钮纠正 / 手动切换重路由），去重入池；AI管理员每月复审（与 F3 Q3 抽样审计共用月度例行动作，Phase 1 经审计导出+人工入池，不做自动标注工具——C-Q2 Assumptions）发布 `golden_set_route_vN`；每次意图分类 prompt 版本或模型变更必须全量回归，`route.accuracy` < 90% 不得发布 | AC4.2.1；C-Q2 及 Assumptions；FR10.3.4；F3 plan A9 同构 |
| A9 | **意图分类超时降级保首响 SLO**：分类调用挂 2.5s 超时（配置 `chat.classify_timeout_ms`），超时/失败时降级为关键词规则匹配（注册表内每意图的关键词特征表），且降级路径 confidence 强制置 <0.6 → 走澄清分支而非误路由——宁可多问一句不可路由错技能。knowledge_qa 的首 token 预算 = 分类(≤2.5s) + F3 召回/重排/生成首字，联合压测守 P95 ≤ 5s（spec §5，分段计时入 kpi meta） | FR4.5.2、AC4.2.1；spec §5（chat.first_token P95 ≤ 5s）；F3 plan §6 首 token 风险同源 |
| A10 | **项目绑定是会话硬约束**：创建会话必带 `project_id` 且校验 `project_members` 成员关系（无权限 403 `PROJECT_FORBIDDEN`，FR4.3.3）；会话创建后 project 不可变——**切换项目 = 新开会话**（前端项目选择器在会话进行中切换时弹确认新建，FR4.3.2）；技能发起时其自身模块权限点照常校验（spec §5"技能入口复用各功能模块的权限点"）；Copilot 头部与首页输入区常显当前项目（FR4.3.1），两形态共享同一会话引擎（C-Q3） | FR4.3.1–FR4.3.3；C-Q3；F10 plan A7（前端仅展示控制） |

---

## 2. 数据模型

> 全部主键 UUIDv7、时间戳 UTC（specs/README 约定）。`chat_sessions` 继承 F10 BaseEntity 公共列（FR10.1.3；ChatSession 在 FR10.1.1 实体清单内）；`chat_messages` 为会话从属明细表；`tasks` 是 F10.1 Task 对象的落地全字段（spec §3 定义，本 feature 建表并在 F10 对象模型登记）。

### 2.1 chat_sessions / chat_messages（spec §3）

```text
chat_sessions(                            # BaseEntity：id/project_id/created_by/created_at/updated_at/state/audit_ref
  user_id→users,                          # 会话归属人（一人一会话流，FR4.3）
  title VARCHAR NULL,                     # 首条消息确定性截取生成（非 LLM）
  context JSONB DEFAULT '{}',             # A4：attached_documents[] / collected_params{} / page_context{}
  last_message_seq BIGINT DEFAULT 0,      # seq 分配游标（行锁递增）
  user_last_seen_seq BIGINT DEFAULT 0,    # 未读完成数水位（FR4.5.3，A5）
  last_message_at TIMESTAMPTZ
)
chat_messages(
  id UUIDv7 PK,
  session_id→chat_sessions, seq BIGINT,   # UNIQUE(session_id, seq)，会话内单调
  role VARCHAR,                           # user | assistant | system（FR4.1.3）
  type VARCHAR,                           # text | file | task_card | system_notice（FR4.1.3）
  content TEXT NULL,                      # 正文（task_card 类可空）
  payload JSONB NULL,                     # 按 type：
                                          #   text:      {route?:{intent,confidence}}
                                          #   file:      {document_id, filename, parse_task_id?, archived_cad?}
                                          #   task_card: {task_id}                      （A5：引用非快照）
                                          #   system_notice: {notice_kind, route?, missing_params?, text?}
                                          #     notice_kind ∈ route_started|clarify|param_missing|
                                          #                cad_archive|task_failed_retryable|queued_notice
  model VARCHAR NULL, prompt_id VARCHAR NULL, prompt_version VARCHAR NULL,
  kb_version INT NULL,                    # AI 生成消息（qa 答案/general_chat）的运行时快照（审计冗余，FR10.3.1）
  created_at TIMESTAMPTZ
)
```

### 2.2 route_feedback_pool（C-Q2 回流机制，A8）

```text
route_feedback_pool(
  id UUIDv7 PK,
  session_id→chat_sessions, message_id→chat_messages,
  utterance TEXT,                         # 触发分类的原始表述
  predicted_intent VARCHAR NULL, confidence NUMERIC NULL, candidates JSONB NULL,
  resolved_intent VARCHAR NULL,           # 用户点选/切换的意图（三回流来源之一时非空）
  source VARCHAR,                         # clarify | candidate_click | manual_reroute（C-Q2 三类）
  status VARCHAR DEFAULT 'pending',       # pending | imported（月度人工复审入金标集后置位，C-Q2 Assumptions）
  golden_set_id UUID NULL,                # 入库后回链 golden_sets 行
  created_at TIMESTAMPTZ
)
-- UNIQUE(message_id, source) 防重复入池；utterance 归一化摘要去重（同文重复表述只留首条）
```

### 2.3 tasks（F10.1 Task 对象落地，spec §3 + C-Q1 扩展）

```text
tasks(
  id UUIDv7 PK,
  project_id→projects NOT NULL,           # FR4.3.2：会话期间产生的任务自动挂项目
  session_id→chat_sessions NULL,          # 经 chat 发起时回填（A1：由技能 service 经 platform/task 创建）
  origin VARCHAR DEFAULT 'chat',          # chat | workbench（工作台直发同表，session_id 为空）
  type VARCHAR,                           # spec_diff | bom_diff | fmea_gen | testcase_gen | report_gen | parse
                                          #   （6 技能 + parse，spec §3；knowledge_qa/general_chat 不产生 task）
  status VARCHAR,                         # QUEUED | RUNNING | SUCCESS | FAILED | CANCELED（specs/README 状态机）
  progress SMALLINT DEFAULT 0,            # 0–100（页级/阶段级粗粒度，语义由各技能定义）
  stage VARCHAR NULL,                     # 各技能自报阶段名（align/mapping/gather/gen_req…，F5–F9 plan）
  result_ref UUID NULL,                   # 结果对象 id（spec_diff_run/bom_diff_run/fmea/test_case_set/test_report/
                                          #   document）——后续动作按钮的跳转目标（FR4.4.2）
  result_stats JSONB NULL,                # C-Q1：SUCCESS 时技能 service 一次性写入的只读快照
                                          #   [{key,label,value,level?}]；各技能映射见 C-Q1 决策
  error_code VARCHAR NULL, error_message TEXT NULL,   # FR4.4.3 失败原因码（沿用各技能模块错误码命名）
  retry_of_task_id UUID NULL,             # 「重试」产生的新任务回链（FR4.4.3）
  created_by→users, created_at, started_at NULL, finished_at NULL
)
-- 索引：(created_by, status)（并发闸门计数，A7）、(session_id, created_at)（会话内卡片列表）、
--       (project_id, type, status)（项目任务视图）；状态变更事件由 platform/task 服务 emit（task.created/canceled）
```

### 2.4 金标集扩展（C-Q2，A8）

```text
golden_sets + 新增行 kind='route'         # 复用 F1 golden_sets（F10.1.4 只增不改；F3 plan A9 先例）
route 金标行 expected JSONB：{intent}     # 七意图 × ≥20 条，双人标注+仲裁，版本化 golden_set_route_v1
```

### 2.5 横切接入（F10）

- **对象模型**：`chat_sessions` 继承 BaseEntity 并已在 FR10.1.1 清单（ChatSession）；`tasks` 注册 OBJECT_REGISTRY；`chat_messages`/`route_feedback_pool` 为从属明细表不占 state。`chat_sessions.state` 保留默认值——会话不是 DRAFT→APPROVED 生成物，不注册 transition 配置（同 F3 plan 对会话的处理）。
- **审计**（`<domain>.<verb>`，FR10.3.3）：`chat.message`（每条消息一条；system_notice 携带路由结果 `route:{intent, confidence, candidates}` 与回流来源——即"含路由结果与置信度"的落点，spec §5；AI 生成消息携带 model/prompt 版本/kb_version）、`task.created` / `task.canceled`（platform/task 服务 emit；各技能执行审计由其自身模块 emit，spec §5）。回流入池信息随 chat.message 的 meta 记录，不新增事件名（保持 F10.3.3 清单最小扩展：本 feature 不新增事件，仅充实 chat.message 载荷——F10 plan A6"审计保真"原则）。
- **状态机（F10.2）**：F4 自身无 AI 生成物定版流——技能产物（对比结论/FMEA/用例/报告）的 DRAFT→APPROVED 状态机在各技能模块，任务卡动作跳转工作台操作，F4 不代理 transition（A1 编排层定位）。`task.status` 为任务生命周期状态，与 F10 `state`（定版状态机）正交（F1 plan A8 手法）。
- **KPI**（kpi_events，FR10.6.1）：`chat.first_token`（duration_ms，POST messages → 首个内容增量事件，P95 ≤ 5s）、`task.duration`（按 type，finished-started，支撑"task.duration（按类型）"KPI）、`route.accuracy` 双口径——金标回归离线产出（A8，发布门槛）+ 线上纠正率（route_feedback_pool 中 candidate_click/manual_reroute 占比月度统计 meta）；三者进 F10 plan §2.5 KPI SQL 视图。
- **权限**：新权限点 `chat.use`（创建会话/发消息/上传，项目成员内）、`chat.config.manage`（并发上限/分类超时等配置，仅 AI管理员）；技能发起复用各模块权限点（specdiff.run、bomdiff.run、fmea.generate、testgen.run、report.import 等，spec §5）；拒绝一律 403 + 统一错误体（FR10.5.4）。
- **Prompt**：`f4.intent_classify`、`f4.general_chat` 入 prompt_registry（FR10.3.4，禁止裸字符串），经 LLMGateway 调用与强制审计。

---

## 3. API 设计（遵循 specs/README：REST /api/v1、统一错误体、异步任务 SSE）

### 3.1 端点清单

```text
POST /api/v1/chat/sessions                # 创建会话。body: {project_id, page_context?{object_type,object_id}}
                                          #   → 201；校验项目成员（FR4.3.3，A10）；切换项目=新会话（FR4.3.2）
GET  /api/v1/chat/sessions                # 会话列表 ?project_id&page&page_size → {items,total,page}（仅本人会话）
GET  /api/v1/chat/sessions/{id}           # 会话详情（context/项目/未读数）+ 消息分页 ?after_seq=&limit=
POST /api/v1/chat/sessions/{id}/messages  # 核心端点。body: {content?, file_refs?[]}（FR4.1.1：文本+文件可同发）
                                          #   响应恒为 SSE（A2），事件序列：
                                          #   meta       {session_id, user_message_id, seq}
                                          #   route      {intent, confidence, source: llm|rule_fallback}
                                          #   clarify    {text, candidates:[{intent,label}]}        —— FR4.2.2
                                          #   param_missing {text, missing_params}                  —— FR4.2.4
                                          #   task_card  {task_id, message_id, task:{name,type,status,
                                          #              progress,risk_stats?}}                     —— FR4.2.3/4.4
                                          #   reply      {delta}                                    —— 同步技能增量
                                          #   sources    {sources:[F3 结构]}                         —— knowledge_qa
                                          #   done       {message_id, no_hit?}
                                          #   error      统一错误体（流中断语义）
POST /api/v1/chat/sessions/{id}/route     # 显式意图（FR4.2.2 候选按钮 / FR4.2.3 手动切换重路由）
                                          #   body: {intent, params?} → 异步技能 202 {task_id, task_card message_id}；
                                          #   knowledge_qa → SSE（同 messages 分支③）；样本入 route_feedback_pool（A8）
POST /api/v1/chat/upload                  # multipart(file, session_id)（FR4.1.1/4.1.2，A6）
                                          #   → {document_id, task_id}（触发 F1 解析，type=parse 任务卡）
                                          #   │ {document_id, archived_cad: true, notice}（CAD 存档，无解析任务）
POST /api/v1/tasks/{id}/cancel            # FR4.4.3/FR4.5.1（QUEUED 直接取消；RUNNING 协作式，A7）
POST /api/v1/tasks/{id}/retry             # FR4.4.3 失败重试 → 新 task（retry_of_task_id 回链）+ 新任务卡
GET  /api/v1/tasks?ids=                   # 批量任务当前态（回到会话刷新任务卡，FR4.5.3，A5；≤50 个/次）
GET  /api/v1/tasks/{id}/events            # SSE 进度（全局既有端点）：status/progress/stage/result_stats 变更
POST /api/v1/chat/sessions/{id}/seen      # 回写 user_last_seen_seq（未读数清零，FR4.5.3）
GET  /api/v1/chat/config                  # max_concurrent_tasks / classify_timeout_ms（前端排队提示用，A7/A9）
PUT  /api/v1/chat/config                  # AI管理员调整 → 审计（chat.message 携带 config 变更记录，同 F3 /rag/config 手法）
```

### 3.2 语义与错误

- 统一错误体 `{"code","message","detail"}`；本 feature 新增错误码：`PROJECT_REQUIRED`（未带 project_id）、`PROJECT_FORBIDDEN`（非项目成员，FR4.3.3，403）、`SESSION_NOT_FOUND`、`MESSAGE_EMPTY`（文本与文件均缺）、`MESSAGE_TOO_LONG`（输入校验）、`INTENT_INVALID`（/route 传入未注册意图）、`PARAMS_INCOMPLETE`（/route 显式发起但必填参数仍缺，detail 列缺失项——引导补齐而非报错放弃，FR4.2.4）、`TASK_NOT_FOUND`、`TASK_NOT_CANCELED`（终态任务不可取消）、`TASK_NOT_RETRYABLE`（非 FAILED 任务重试）、`UPLOAD_TOO_LARGE`/`UPLOAD_TYPE_UNSUPPORTED`（沿用 F1 校验码透传）、`CHAT_CONFIG_FORBIDDEN`（非 AI管理员，403）。
- **CAD 上传不是错误**：HTTP 201 + `archived_cad:true` + 固定提示文案（FR4.1.2），前端渲染提示条——与 F1 的格式拦截（真错误）区分。
- **异步边界**：五个技能型意图与 parse 走各技能 Celery 队列 + `/tasks/{id}/events`（specs/README 异步约定）；knowledge_qa/general_chat/澄清/参数引导为同步 SSE 流（A2/A4）；并发闸门只作用于任务型（A7，FR4.5.4），同步问答以速率限制约束（同 F3 plan §6 滥用防护）。
- 分页 `{items,total,page}`、复数资源名、UUIDv7、UTC ISO-8601 全局约定适用于全部端点；消息分页例外采用 `after_seq` 游标（会话流式追加场景优于页码，detail 见 §7 假设）。

---

## 4. AI/LLM 使用点

| 项 | 设计 | 溯源 |
| ---- | ---- | ---- |
| 模型清单 | ① **意图分类模型**（轻量指令模型，温度 0，结构化输出）——独立于生成模型配置（`chat.classify_model`），可用小模型压低分类时延；② **生成式 LLM**（general_chat 直答 + 复用 F3 的知识问答生成）。均私有化部署、经 F10 `LLMGateway`，审计记录运行时实测 model/model_version | FR4.2.1、FR4.2.5；FR10.3.1；F10 plan §4 挂点 2 |
| Prompt 策略 | Prompt 注册表（FR10.3.4）：`f4.intent_classify`（结构：① 七意图定义与边界说明——含"general_chat 仅闲聊/平台使用咨询、不产出业务对象"的负面约束与知识问答 vs 闲聊的判别规则；② 意图参数要求摘要（来自 SkillInvoker.param_schema 的静态渲染）；③ 当前消息 + 最近 N 轮对话摘要 + 页面上下文引用；④ 输出 schema 指令）、`f4.general_chat`（闲聊/平台使用咨询，明确禁止编造业务数据、禁止承诺执行平台外的操作） | FR4.2.1、FR4.2.5；FR10.3.4 |
| 结构化输出 schema | 意图分类（唯一 F4 自有 LLM 结构化输出）：`{intent: enum(七类), confidence: number[0,1], candidates: [{intent, confidence}]≤3, missing_params: string[], schema_version: "1.0"}`——代码层 JSON Schema 校验 + 枚举白名单，校验失败视为分类失败走 A9 兜底；confidence 与 candidates 全量入 chat.message 审计（spec §5）。general_chat 输出为流式纯文本（无结构化需求） | FR4.2.1、FR4.2.2；F10 plan §4 挂点 3 |
| 超时降级 | A9：`classify_timeout_ms`（默认 2500）超时或 schema 校验失败 → 关键词规则兜底（注册表特征表），confidence 强制 <0.6 走澄清；规则兜底命中在 route.source=rule_fallback 标记，回流池单独统计其占比（监控降级频率） | FR4.5.2；AC4.2.1 风险缓解 |
| 澄清与引导不调 LLM | 澄清反问文本、参数补齐引导、CAD 拦截提示、排队提示全部为**确定性模板**（槽位填充），杜绝在交互路径上叠加额外 LLM 调用 | FR4.2.2、FR4.2.4、FR4.1.2、FR4.5.4 |
| 审计接入 | 每条消息 emit `chat.message`（含 route 结果与置信度、回流来源、AI 消息的 model/prompt/kb_version）；knowledge_qa 时 F3 service 另 emit `rag.query`（citations/kb_version 全字段）——同一轮双事件各司其职（chat 记路由、rag 记检索引用） | spec §5；FR10.3.1、FR10.3.3 |
| 评测方式 | ① **golden_set_route_v1 全量回归**（A8/C-Q2）：≥140 条、七意图分项准确率 + 总体 ≥90%（AC4.2.1，M2 Exit 硬门槛）；prompt 版本/模型变更必回归，不达标禁发布；② 上线前时延评测：分类 P95 时延 + knowledge_qa 端到端首 token P95 ≤ 5s（spec §5）；③ 线上回流：三类样本（澄清/点选/切换）入 route_feedback_pool，月度复审扩金标（C-Q2）；④ general_chat 抽样审计（月度与 F3 C-Q3 例行合并）：确认未编造业务数据、未越权承诺 | AC4.2.1；C-Q2 及 Assumptions；spec §5 |

---

## 5. 测试策略

| 层级 | 内容 | 溯源 |
| ---- | ---- | ---- |
| 单元 | 意图分类输出 schema 校验（枚举白名单/confidence 边界/candidates 截断）与降级路径（超时/校验失败 → 规则兜底 + confidence<0.6）；参数收集状态机（附件挂载/参数累积/missing_params 判定/补齐后自动发起）；SkillInvoker 注册表完整性（七意图全覆盖、param_schema 与技能 service 签名一致——schema 漂移即测试失败）；CAD 扩展名判定与提示文案模板；并发闸门计数器（RUNNING 计数、FIFO 出队、取消释放容量）；seq 分配与未读水位计算；任务卡投影组装（status/risk_stats/动作按钮映射表 FR4.4.2） | FR4.2.1/4.2.2/4.2.4、FR4.4.1/4.4.2、FR4.5.4；A3/A4/A7/A9 |
| 集成（会话与项目绑定） | 无 project_id 建会话 4xx；非项目成员 403 PROJECT_FORBIDDEN（FR4.3.3）；会话内所有任务落该项目（FR4.3.2）；切项目新开会话、原会话上下文不串项目；Copilot 继承页面所在项目创建会话（FR4.3.1，前端集成测试） | FR4.3.1–FR4.3.3；A10 |
| 集成（路由与澄清） | 高置信消息直达技能（SSE route→task_card）；低置信 → clarify 事件 + 候选按钮 + 入回流池(source=clarify)（FR4.2.2）；点选候选经 /route 重路由入池(candidate_click)（FR4.2.2/4.2.3）；路由成功后 system_notice「已为您启动【X】」+ 用户手动切换意图重路由（FR4.2.3，manual_reroute 入池）；缺参数引导文案与补齐后自动发起（FR4.2.4，spec_diff 缺文件/bom_diff 缺 BOM 两分支桩测）；knowledge_qa 直通 F3（检索 stub 断言调用与上下文传入轮数）；general_chat 不创建任何业务对象/任务（FR4.2.5） | FR4.2.1–FR4.2.5；C-Q2；A8 |
| 集成（任务生命周期与卡片） | 发起 BOM 比对：卡片即时出现在对话流（QUEUED）→ /tasks/{id}/events 推 RUNNING(progress%) → SUCCESS 后 result_stats 快照渲染 + 动作按钮可用（AC4.4.1）；F4 复用同一入口断言（五技能逐一，参数透传 origin/session_id，A1）；失败卡 error_code + 重试按钮 → retry 新任务回链（FR4.4.3）；QUEUED 取消即时生效、RUNNING 协作取消（FR4.4.3）；并发上限：第 4 个任务排队提示、完成一个后自动出队（FR4.5.4，A7）；离开页面任务继续执行、回归批量刷新 + 未读完成数（AC4.5.1：stub 时钟模拟 5 分钟后完成） | AC4.4.1、AC4.5.1；FR4.4.1–4.4.3、FR4.5.1/4.5.3/4.5.4；C-Q1 |
| 集成（上传与上下文注入） | 会话上传 → F1 上传校验透传 + parse 任务卡（无动作区/无风险统计，C-Q1）；SUCCESS 后 document 注入 attached_documents，后续"对比这两个文件"可直接收集参数（FR4.1.1 端到端桩测）；解析失败错误透传不静默（F1 契约）；CAD 上传 → 存档 + 提示、无解析任务、不进参数收集（FR4.1.2，A6） | FR4.1.1、FR4.1.2；C-Q1；A6 |
| 金标评测 | golden_set_route_v1 回归脚本：总体 ≥90% 且七意图分项报表（AC4.2.1 硬门槛，M2 Exit）；规则兜底路径单独评测（降级时澄清率 100%、误路由 0）；prompt/模型变更模拟回归流程演练；回流池 → 金标入库 → vN 版本发布流程 dry-run（C-Q2） | AC4.2.1；C-Q2；A8 |
| API 契约 | SSE 事件序列契约（三分支各自的合法事件序）；messages 双形态（SSE）与 /route 双形态（202/SSE）；统一错误体/分页信封；/tasks?ids= 批量上限与部分不存在语义；cancel/retry 幂等（重复取消/重试返回当前态）；seen 水位幂等 | FR4.2.2/4.2.3、FR4.4.3、FR4.5.3；specs/README |
| 前端 | 两形态一致性（C-Q3）：首页大输入区与右侧 Copilot 对同一会话流的渲染/交互断言一致（澄清按钮/任务卡/上传）；任务卡实时更新（mock SSE）与断线重连批量刷新；未读完成数角标；CAD 提示条；排队提示；后续动作跳转对应工作台并预填上下文（FR4.4.2 逐技能路由断言）；项目选择器与切换确认（FR4.3.2）；[AI] 标识（知识问答答案，specs/README） | FR4.1.2/4.1.3、FR4.3.1/4.3.2、FR4.4.2、FR4.5.3；C-Q3 |
| 性能 | knowledge_qa 首 token P95 ≤ 5s 压测（分类 ≤2.5s 预算 + F3 链路，分段计时入 kpi meta 定位超标段，A9）；SSE 长连接并发与断线重连风暴；并发闸门下 100 任务/用户队列吞吐；dispatcher beat 周期与出队延迟上限验证 | FR4.5.2、FR4.5.4；spec §5 KPI |

覆盖率目标遵循全局规则（新增模块 ≥80%）。

---

## 6. 风险与非目标

### 风险

| 风险 | 影响 | 缓解 |
| ---- | ---- | ---- |
| 意图路由准确率 < 90%（表述多样性、中文工程口语） | AC4.2.1 失守、用户被路由到错误技能 | A3 确定性澄清兜底（低置信宁可反问）；A8 金标回归为发布硬门槛 + 三类回流样本持续扩充金标；A9 降级路径宁澄清不误路由；误路由后手动切换成本低（FR4.2.3 一键重路由） |
| 意图分类时延挤占首 token 预算 | chat.first_token P95 ≤ 5s 失守（spec §5） | 分类独立轻量模型 + 温度 0 短输出；2.5s 超时降级（A9）；分段计时（classify/recall/first_reply）入 kpi meta；首轮无需改写时 F3 侧跳过改写（F3 plan A7 联动） |
| 跨模块 service 契约漂移（技能模块演进参数/返回结构，SkillInvoker 未同步） | chat 发起失败或任务卡缺数据 | param_schema 与 service 签名一致性单测（注册表测试，§5 单元）；技能模块 plan 已锁定「F4 复用同一入口」为其验收项（F6/F7/F8 plan 测试行）；契约测试五技能逐一回归 |
| SSE 断线/多端在线导致任务卡状态不一致 | 卡片状态过期、进度停滞错觉 | A5 投影模式（渲染时读 task 态）+ use-task-events 断线批量刷新（/tasks?ids=）；终态事件幂等；user_last_seen 水位兜底未读数 |
| 并发闸门竞态（同用户并发创建任务计数漂移） | 超 3 个 RUNNING（FR4.5.4 失守） | 用户级信号量行 SELECT ... FOR UPDATE 串行化计数与出队（A7）；dispatcher 单点派发（beat 周期）避免多实例竞争；计数对账任务兜底 |
| result_stats 快照与源对象脱节（用户后续处置后卡片数字过时） | 误导（如差异已处置仍显示高风险数） | C-Q1 Assumptions 已明确"只读快照 + 查看最新跳对象页"为产品口径；卡片渲染时对 FAILED/已定版对象加态标记；不在 F4 侧重算（复杂度非目标） |
| general_chat 被当业务入口滥用（用户在闲聊中要求执行业务操作） | 越权预期、产出不可追溯 | f4.general_chat prompt 负面约束 + 回复内引导走技能意图；general_chat 不创建任务/业务对象（代码层无此通路，测试断言）；抽样审计（§4 评测④） |
| 长会话历史加载与上下文膨胀 | 消息流卡顿、分类 prompt 超长 | 消息游标分页（after_seq）；分类仅取最近 N 轮摘要（N=3，配置）；附件/参数存 context 引用不存正文 |
| 两形态（首页区/常驻侧栏）行为漂移 | C-Q3 决策失效、体验割裂 | 共享 features/chat 组件引擎（§1.1），仅入口布局差异；前端两形态一致性测试行（§5 前端） |

### 非目标（Phase 1）

- 多模态输入（语音/图片理解）、CAD 解析（仅存档提示）、会话分享、跨系统自主执行（spec §6）
- 多意图复合任务编排与自动规划（单轮单意图；"对比后生成 FMEA"等链式动作 = 用户点任务卡按钮逐步发起，FR4.4.2 动作区；Agent 化属第四阶段，PHASE1_SPEC §4）
- 页面整页 DOM 上下文理解（仅注入 project + object_type/object_id 引用，C-Q3 Assumptions）
- 回流样本自动标注/自动入金标集工具（月度人工复审，C-Q2 Assumptions）
- 任务卡内嵌完整业务编辑器（后续动作 = 跳转工作台并预填上下文，FR4.4.2 明确"跳转"）
- knowledge_qa 的会话在 F3 独立页面可见/互导（chat 与 rag 会话存储独立，A1；Phase 2 再议互通）
- 消息级富文本编辑、消息撤回、群聊/多人会话（单人单会话流）

---

## 7. 决策与假设记录（承接 clarifications）

- C-Q1：任务卡风险统计统一 schema `risk_stats:[{key,label,value,level?}]`，SUCCESS 时技能侧一次性快照写入 `task.result_stats`；五技能映射表与只读口径按 clarification 原文执行；parse 任务卡无统计无动作区。→ §2.3、A5/A6、§5
- C-Q2：AC4.2.1 ≥90% 为 M2 正式验收目标；golden_set_route_v1（≥140 条，双人标注+仲裁）+ 三类低置信样本回流 + 月度复审发版 + prompt/模型变更全量回归门禁。→ A8、§2.2/§2.4、§4 评测、§5 金标评测
- C-Q3：首页独立大输入区 + 右侧常驻 Copilot 两形态共享同一会话引擎；Copilot 默认展开可收起、继承项目与页面上下文（仅 object_type/object_id 引用）。→ §1.1 前端结构、A10、§5 前端
- 新增决策（无对应 Q，依 FR 推定）：**A1 编排层零技能逻辑**（五技能复用各模块 service 发起入口，任务行由技能侧创建、chat 传 origin/session_id 关联——与 F5–F9 plan 已有决策对齐，避免双写任务）；**A2 messages 单端点 SSE 双形态**（spec §4 原文即此语义；异步任务进度仍走全局 /tasks/{id}/events，两个 SSE 各司其职）；**A5 任务卡为投影非快照**（payload 存 task_id，渲染时读态，防漂移）；**A6 CAD 拦截为确定性入口判定**（不建解析任务、不入参数收集）；**A7 并发闸门在 dispatcher 启动侧**（QUEUED 不受限、RUNNING 受限，与 spec"超出排队并提示"字面一致）；**A9 分类超时降级**（宁可澄清不可误路由 + 守首响 SLO）；**knowledge_qa 不建 rag_conversation**（chat_messages 即上下文真相，F3 会话层仅服务其独立页面）；**会话无定版状态机**（ChatSession 非生成物，state 保留默认）；**chat 不新增审计事件名**（路由置信度/回流来源充实 chat.message 载荷，保持 F10.3.3 清单稳定）。
- 假设：意图分类模型可用独立小模型配置（`chat.classify_model`），不可用时与生成模型同配（时延风险升级到 §6 表）；消息 `after_seq` 游标分页为 chat 场景特例（会话为 append-only 流，页码分页在增量场景失效），其余列表仍按全局 `{items,total,page}`；`chat.max_concurrent_tasks=3`、`classify_timeout_ms=2500`、上下文轮数 N=3 均为默认配置值（经 /chat/config 可调）；dispatch 出队延迟目标 ≤30s（beat 周期），用户可感知为排队提示的"N 值"近似值；route_feedback_pool 的月度复审由 AI管理员在 F10.4 审计导出基础上人工执行（Phase 1 不建专用界面，C-Q2 Assumptions 同源）。
