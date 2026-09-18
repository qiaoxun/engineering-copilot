# F10 工程确认与追溯机制（横切）— 技术方案（Plan）

| | |
| ---- | ---- |
| Feature | F10-platform-governance |
| 输入 | specs/F10-platform-governance.md、specs/F10-platform-governance.clarifications.md（冲突时以其为准）、PHASE1_SPEC.md、PHASE1_FEATURES.md、specs/README.md |
| 阶段 | speckit-plan（仅设计，不写代码） |
| 里程碑 | M1 交付骨架（F10.1/F10.2/F10.3 全量、F10.5、F10.4 API、F10.6 框架），F10.4 页面 M2、比对/生成类筛选 M3–M4（spec §3 落地映射表） |

> 本 plan 中所有设计决策均标注溯源（FR/AC/Q 编号）。clarifications（Q1–Q4 决策）全文有效，本文引用处标注为「C-Qx」。

---

## 1. 架构与模块落点

### 1.1 总体架构

对齐既定技术栈：**后端 FastAPI 模块化单体 + Celery + PostgreSQL(pgvector) + MinIO；前端 React + TypeScript + Ant Design**。F10 是横切地基，物理上落在一个独立顶层模块 `platform/`，其余业务模块（documents/kb/rag/chat/specdiff/bomdiff/fmea/testgen/report）通过**显式依赖注入 + 中间件**接入，禁止业务代码绕过（FR10.2.2、FR10.3.1）。

```text
apps/backend/
├── app/
│   ├── core/                    # 框架级：config、db、security(jwt)、errors(统一错误体)、uuidv7
│   ├── modules/
│   │   ├── platform/            # ← F10 本体（模块化单体中的横切模块）
│   │   │   ├── objects/         # F10.1 统一对象模型：BaseEntity 声明式基类 + 关系注册表
│   │   │   ├── workflow/        # F10.2 状态机：通用 StateMachine 组件 + 转换记录
│   │   │   ├── audit/           # F10.3 审计：audit 事件 API、写入口、append-only 仓储
│   │   │   ├── audit_query/     # F10.4 审计查询/导出（管理员 API）
│   │   │   ├── rbac/            # F10.5 权限：角色/权限点/项目成员 + FastAPI 依赖 require_perm
│   │   │   ├── kpi/             # F10.6 埋点：事件写入 + KPI 报表查询
│   │   │   └── prompts/         # FR10.3.4 Prompt 注册表（模型/prompt 版本管理）
│   │   └── identity/            # 用户/部门/认证（本地账号，IdentityProvider 抽象，C-Q3）
│   ├── middleware/audit_context.py   # 请求级审计上下文（user/project/request_id）
│   ├── worker/                  # Celery app + tasks（审计/埋点写入走独立队列）
│   └── main.py
└── alembic/                     # 迁移（audit 表权限收紧的 grant/deny 也入迁移）
apps/frontend/
└── src/
    ├── pages/admin/audits/      # F10.4 审计查询页（M2 上线，UI 页面28 最小版）
    ├── pages/admin/users|roles|projects/   # FR10.5.2 管理端 CRUD
    ├── features/workflow/       # 状态徽章、定版/转换操作组件（各业务页面复用）
    └── features/kpi/            # KPI 报表展示（M3 起）
```

### 1.2 关键架构决策

| # | 决策 | 溯源 |
| ---- | ---- | ---- |
| A1 | 横切以「平台模块 + FastAPI 依赖注入」实现，而非独立服务：Phase 1 单体足够，审计写入经 Celery 异步解耦但不跨进程 | spec §5 非目标（不做工作流引擎/微服务化）；FR10.3.1 |
| A2 | **AI 直写 APPROVED 的架构禁止**：定版/状态转换仅暴露人工操作端点 `POST .../transition`，请求体必须携带操作人上下文（来自认证态，不接受客户端声明身份）；Celery 任务与 LLM 输出通路在代码层不 import 该端点的 service 函数（以模块依赖方向约束 + 代码评审检查项 + 集成测试断言） | FR10.2.2；specs/README「任何 API 都不允许 AI 输出直接写 APPROVED」 |
| A3 | 状态机为**通用组件 + 每对象类型一张转换配置表**（硬编码默认 + 配置表可覆盖），不做可配置工作流引擎 | FR10.2.1；spec §5 非目标 |
| A4 | 审计 append-only 三层保证：① 表级 REVOKE UPDATE/DELETE（迁移中 GRANT 仅 INSERT/SELECT）；② 仓储层只提供 `append()`/`query()`；③ 应用层无删除路由 | FR10.3.2、AC10.3.2；C-Q2（归档走导出+冷备，不用 DELETE） |
| A5 | 认证 M1 用本地账号（argon2 哈希 + JWT），认证入口收敛到 `IdentityProvider` 抽象接口（本地实现为默认），SSO/LDAP 后续以新 Provider 增量接入 | C-Q3；FR10.5.1；spec §5 |
| A6 | 审计日志与 KPI 埋点**分表分管道**：`ai_audit_logs`（append-only、保真、重）与 `kpi_events`（可聚合、轻）独立写入，共用同一中间件采集上下文 | FR10.6.1（「与审计日志分离」） |
| A7 | 前端权限仅做展示控制（路由守卫/按钮隐藏），强制校验全部在后端依赖 `require_perm("module.action")`；前端不维护权限逻辑副本，仅消费 `/api/v1/me/permissions` | FR10.5.4 |
| A8 | F10.1 采用「声明式 BaseEntity + 对象注册表」：每个业务模型的 SQLAlchemy 基类自动携带 `id/project_id/created_by/created_at/updated_at/state/audit_ref`，并注册到 OBJECT_REGISTRY 供审计/状态机/权限复用 | FR10.1.3、FR10.1.4 |

### 1.3 模块间接入契约（各里程碑业务模块如何挂接）

| 业务接入点 | 平台侧提供的接口 | 溯源 |
| ---- | ---- | ---- |
| F1/F2 文档定版（M2） | `workflow.transition(obj, action, comment, actor)` | FR10.2.1 映射表 |
| F3/F4 RAG/Chat | `audit.emit("rag.query"/"chat.message", citations=[...], kb_version=...)` | FR10.3.3、FR10.6.2 |
| F5/F6 比对 | 转换记录 + `bomdiff.item.disposed` 等事件；差异处置复用状态机 | FR10.2.1、FR10.3.3、F6.5 |
| F7–F9 生成物 | 创建即 DRAFT（BaseEntity 默认态）；采纳/编辑/定版事件；human_modifications diff 采集 | FR10.2.1、FR10.3.1、FR10.6.2 |
| 全部模块 | `require_perm()`、`Pagination`、统一错误体、UUIDv7、SSE 任务事件 | FR10.5.4、specs/README API 约定 |

---

## 2. 数据模型

> 全部主键 UUIDv7、时间戳 UTC（specs/README 约定）。所有业务对象表继承统一接口字段（FR10.1.3）。

### 2.1 identity（F10.5 / C-Q3）

```text
departments(id, name, parent_id→departments)                    # 部门树
users(id, username UNIQUE, password_hash, display_name, email,
      department_id→departments, is_active, created_at, updated_at)
roles(id, code UNIQUE, name, is_system)                          # 预置 5 角色 is_system=true
permissions(id, code UNIQUE)          # code = '<module>.<action>'，FR10.5.1
role_permissions(role_id, permission_id)                          # 可配置调整（C-Q1）
projects(id, name, code, owner_id→users, ...)
project_members(project_id, user_id, role_in_project, UNIQUE(project_id,user_id))  # 四级模型第4级
```

### 2.2 统一对象模型（F10.1）

- 声明式基类 `BaseEntity` 公共列（落到每张业务表，避免多态 JOIN，保证外键可建与集成测试可覆盖 AC10.1.1）：

```text
id UUIDv7 PK / project_id→projects / created_by→users /
created_at / updated_at / state VARCHAR(状态枚举, 默认 DRAFT) /
audit_ref UUID NULL   # 指向定版时点的审计记录（FR10.1.3）
```

- **实体清单与关系**（FR10.1.1、FR10.1.2）：

```text
products(id, ...)                                   # Product 1—N Document/FMEA
documents(id, product_id NULL, parse_schema_version, ...)    # F1.6 契约入口
document_projects(document_id, project_id)          # Document N—N Project
boms(id, ...) / bom_diff_runs(id, base_bom_id, target_bom_id, ...)   # BOM(+BomDiffRun)
fmeas(id, product_id NULL, ...) / fmea_rows(id, fmea_id, ...)
fmea_row_sources(fmea_row_id, citation_type, citation_id)    # FmeaRow N—N source_link
test_case_sets(id, ...) / test_cases(id, set_id, state: DRAFT→ADOPTED|IGNORED)  # F8
test_requirements(id, ...) / test_reports(id, ...) / issues(id, origin_type, origin_id)
risks(id, ...) / chat_sessions(id, project_id, ...)
issues.origin: 多态引用（origin_type∈{bom_diff_item, report_anomaly}，FR10.1.2 的 F6.5/F9.6 来源）
```

- 向后兼容约定（FR10.1.4）：所有演进只允许**新增可空列 / 新增表**，Alembic 迁移评审 checklist 检查；不 drop、不改类型。

### 2.3 状态机（F10.2）

```text
object_state_configs(id, object_type, from_state, action, to_state,
                     required_perm, require_comment, is_default)
state_transitions(id, object_type, object_id, actor_id→users,
                  from_state, to_state, action, comment,   # 定版 comment 必填（FR10.2.3）
                  diff_summary JSONB, created_at)
```

- 转换配置以 Python 常量表为默认（`is_default=true` 种子化），覆盖 FR10.2.1 的映射表：FMEA `DRAFT→IN_REVIEW→APPROVED`（定版权限=研发主管，C-Q1）、测试用例 `DRAFT→ADOPTED/IGNORED`、报告 `DRAFT→IN_REVIEW→APPROVED`（结论节已确认才允许 APPROVED，校验逻辑在 transition service 钩子）等。
- `APPROVED` 锁定不依赖约定：transition 配置中不存在 `APPROVED→` 编辑路径，业务编辑 service 统一检查 `state==APPROVED → raise OBJECT_LOCKED`（错误码），修订走 `revision` 列 +1 新行（FR10.2.4）。可定版对象基类附加列 `revision INT DEFAULT 1`。

### 2.4 审计（F10.3 / F10.4）

```text
ai_audit_logs(                       # 按月分区（PARTITION BY RANGE created_at），C-Q2
  audit_id UUIDv7 PK,
  user_id→users, user_name,          # 冗余 user_name 便于导出后独立可读
  occurred_at TIMESTAMPTZ,
  project_id UUID NULL, object_type, object_id UUID NULL,
  action VARCHAR,                    # '<domain>.<verb>'，FR10.3.3 统一清单
  input_summary TEXT,                # 确定性摘要（模板化截取，非 LLM 生成）
  model VARCHAR, model_version VARCHAR,
  prompt_id VARCHAR, prompt_version VARCHAR,   # 外键逻辑引用 prompt_registry（FR10.3.4）
  kb_version VARCHAR NULL,
  citations JSONB,                   # [{doc_id, project, time, snippet, locator...}]
  ai_output_id UUID NULL,            # 指向生成物/输出对象
  human_modifications JSONB,         # JSON Patch 风格 diff + 摘要
  final_result JSONB NULL, status VARCHAR,   # SUCCESS/FAILED/CORRECTED
  request_id UUID)                   # 关联 trace
prompt_registry(id, prompt_id, version, template, variables schema, model, is_active,
                created_by, created_at)       # FR10.3.4：代码仅持 prompt_id+version
audit_archives(id, period, object_key→MinIO, checksum, created_at)   # C-Q2 冷备登记
```

- 权限：应用 DB 角色对该表仅 `INSERT/SELECT`（迁移执行 REVOKE UPDATE, DELETE），AC10.3.2 用例直接以该 DB 角色尝试 UPDATE/DELETE 断言失败。
- 容量观测：提供 `audit_stats` 视图（记录数/字节量按月），M1 交付；精确容量承诺 M3 修订（C-Q2）。

### 2.5 KPI（F10.6）

```text
kpi_events(id UUIDv7, event VARCHAR, user_id, project_id, object_type, object_id,
           ts TIMESTAMPTZ, duration_ms INT NULL, meta JSONB)   # FR10.6.1 schema
kpi_baselines(id, kpi_name, process, sample_no, manual_minutes, measured_by,
              witnessed_by, baseline_doc_version, signed_at)    # FR10.6.3 人工基线（≥5样本/项）
```

- KPI 报表（FR10.6.4）以 SQL 视图实现 6 项（比对↓80%/BOM↓70%/FMEA↓60%/报告↓70%/采纳率·修改率/RAG no_hit 率），`kpi_baselines` 为分母来源（C-Q4 双方签署版本化）。

---

## 3. API 设计（遵循 specs/README：REST /api/v1、统一错误体、异步任务 SSE）

### 3.1 端点清单

```text
# 认证与身份（C-Q3）
POST /api/v1/auth/login            # 用户名/密码 → JWT；失败事件 auth.denied
GET  /api/v1/me/permissions        # 当前用户权限点集合（前端展示控制用，A7）

# 通用状态转换（FR10.2.1–FR10.2.4，spec §4）
POST /api/v1/{objects}/{id}/transition   # body: {action, comment}；actor 取认证态
GET  /api/v1/{objects}/{id}/transitions  # 转换历史（含 diff 摘要、意见）

# 审计（FR10.4.1–FR10.4.3）
GET  /api/v1/audits                # 筛选 user/project/时间范围/object_type/action；分页 {items,total,page}
GET  /api/v1/audits/{audit_id}     # 明细（含 citations 与 diff）
GET  /api/v1/audits/export         # CSV 导出（异步任务 → task_id + SSE）
GET  /api/v1/audits/stats          # 容量观测（C-Q2）

# KPI（FR10.6.4、spec §4）
GET  /api/v1/kpi/reports/{kpi_name}   # kpi_name ∈ spec §5 六项；返回 当前值/基线/样本数

# 管理端（FR10.5.2）
CRUD /api/v1/admin/users /api/v1/admin/roles /api/v1/admin/projects /api/v1/admin/departments
POST /api/v1/admin/roles/{id}/permissions      # role.changed 事件（FR10.3.3）
# 任务 SSE（全局约定）
GET  /api/v1/tasks/{id}/events     # QUEUED/RUNNING/SUCCESS/FAILED/CANCELED
```

### 3.2 语义与错误

- 统一错误体 `{"code","message","detail"}`；本 feature 新增错误码：`OBJECT_LOCKED`（FR10.2.4）、`INVALID_TRANSITION`、`COMMENT_REQUIRED`（定版必填意见，FR10.2.3）、`FORBIDDEN`(403, FR10.5.4)、`AUDIT_ACCESS_DENIED`。
- 拒绝一律 403 + 统一错误体，并 emit `auth.denied`/权限拒绝审计（FR10.5.4、FR10.3.3）。
- transition 为同步操作（无 LLM、无重计算），不走 task/SSE；审计 CSV 导出数据量大，走异步任务 + SSE（specs/README 异步约定）。
- 分页、复数资源名、UUIDv7、UTC ISO-8601 全局约定适用于全部端点。

---

## 4. AI/LLM 使用点

| 项 | 设计 | 溯源 |
| ---- | ---- | ---- |
| F10 本体的 LLM 使用 | **无**。F10 为治理机制，本身不调用模型；`input_summary` 用确定性模板截取生成（保证审计保真，不被 LLM 失败污染）。AI 调用发生在 F3/F4/F5/F6/F7/F8/F9，F10 提供强制挂点 | FR10.3.1（记录者而非执行者） |
| 挂点 1：Prompt 注册表 | `prompt_registry` 表 + `render_prompt(prompt_id, version, vars)` 唯一入口；业务代码只允许 `prompt_id+version` 引用，裸字符串 prompt 以 lint 规则（禁止 `Prompt(` 字面量模板调用）+ 代码评审拦截 | FR10.3.4 |
| 挂点 2：调用包装器 `LLMGateway` | 统一封装：模型名/版本读取配置 → 渲染 prompt → 调用 → 采集 citations/kb_version → 强制 `audit.emit(...)` → 返回结构化输出。业务模块禁止直连模型 SDK（依赖方向约束） | FR10.3.1 全字段、FR10.3.3 |
| 挂点 3：结构化输出约定 | 各业务 LLM 调用必须声明 JSON Schema 并以 `schema_version` 记入审计 `final_result`；F10 定义通用信封 `{schema_version, items[], citations[]}`，各 feature 的具体 schema 在其自身 plan 定义 | specs/README [AI] 草稿语义、FR10.3.1 |
| 挂点 4：human_modifications 采集 | BaseWorkflowService 在编辑/采纳动作上做 before/after JSON diff 写审计（AI 输出 → 人工修改 diff），供采纳率/修改率 KPI | FR10.3.1、FR10.6.2 |
| 模型策略 | 模型与版本走配置（私有化可替换，数据不出企业域，PRD §53）；审计记录 `model/model_version` 为运行时实际值而非配置期望值 | C-Q3 精神、FR10.3.1 |
| kb_version | 每次含 RAG 的调用从 F2 ingestion 版本服务读取当前 kb_version 随审计落库 | specs/README 数据契约、FR10.3.1 |
| 评测方式 | ① 集成测试：FMEA 生成→编辑→定版后断言审计记录可完整重建全过程（AC10.3.1）；② 审计字段完备性 schema 校验测试（逐字段断言非空规则）；③ RAG 引用准确率抽样审计走 F10.4 查询页（specs/README KPI「可抽样审计」） | AC10.3.1、AC10.3.2 |

---

## 5. 测试策略

| 层级 | 内容 | 溯源 |
| ---- | ---- | ---- |
| 单元 | 状态机转换表合法性（非法转换/缺意见/OBJECT_LOCKED）；权限点判定函数；diff_summary 与 human_modifications 生成；prompt 渲染变量校验 | FR10.2.1–10.2.4、FR10.3.4 |
| 集成（后端） | **样板闭环**（AC10.2.1、AC10.3.1）：建 FMEA（DRAFT）→ 工程师调 transition(APPROVED) 期望 403 → 研发主管定版成功且 comment 必填生效 → 定版后编辑返回 OBJECT_LOCKED → revision+1 修订链完整 → 审计记录逐步断言 who/when/input/model/prompt/kb_version/output/human diff/final | AC10.2.1、AC10.3.1、FR10.2.1 |
| 集成（DB 权限） | 以应用 DB 角色连接执行 UPDATE/DELETE `ai_audit_logs` 断言被拒绝 | AC10.3.2 |
| 权限矩阵 | 参数化测试：5 角色 × 关键权限点（view/create/edit/各定版/用户管理/审计查询/知识库配置）全组合断言，矩阵数据即 FR10.5.2 表 + C-Q1 决策；矩阵同时作为 `role_permissions` 种子数据，测试与种子同源避免漂移 | FR10.5.2、AC10.5.1、C-Q1 |
| 对象关系 | 跨模块外键集成测试：Document N—N Project、FmeaRow—source_link、Issue 多态来源（bom_diff_item/report_anomaly）可建可查可级联 | FR10.1.2、AC10.1.1 |
| API 契约 | 统一错误体/分页信封/SSE 事件序列（QUEUED→RUNNING→SUCCESS）契约测试；transition 请求体不信任客户端身份的伪造测试 | specs/README、FR10.2.2、FR10.5.4 |
| 前端 | 组件测试：状态徽章/定版对话框（意见必填）；审计查询页筛选与 CSV 导出；权限按钮展示控制（mock 权限点） | FR10.4.1–10.4.2、FR10.5.4 |
| KPI | 演示环境跑一轮全流程（parse→rag→chat→比对→fmea→报告）后断言 6 个 KPI 报表端点均可出数（种子基线数据） | AC10.6.1 |
| 迁移/兼容 | 迁移测试：新增列可空、旧数据可读（FR10.1.4）；分区滚动与归档任务 dry-run | FR10.1.4、C-Q2 |

覆盖率目标遵循全局规则（新增模块 ≥80%）。

---

## 6. 风险与非目标

### 风险

| 风险 | 影响 | 缓解 |
| ---- | ---- | ---- |
| 「AI 直写 APPROVED 禁令」靠约定维护，新模块可能绕过（A2） | 合规硬伤（FR10.2.2） | 模块依赖方向 lint + 架构测试（import-linter 禁止 worker/llm 层 import transition service）+ 每模块验收含此检查项 |
| 审计字段被业务模块漏填（citations/kb_version） | 审计不可重建（AC10.3.1） | LLMGateway 强制挂点而非各模块自写；字段完备性 schema 测试作为 M2–M4 每模块验收门槛 |
| 审计量与查询性能（月分区、大 JSONB） | F10.4 查询慢 | 分区裁剪 + (user_id, occurred_at)/(project_id, occurred_at)/(action, occurred_at) 索引；导出走异步 |
| 权限矩阵客户方后续调整（C-Q1 配置化） | 行为漂移 | 矩阵测试与种子数据同源，调整后回归 AC10.5.1 即可 |
| 人工基线测量依赖客户配合（C-Q4） | M3/M4 KPI 无法验收 | M1 启动即发起联合测量，双签版本化留档为 M3 Exit 前置检查项 |
| 本地账号安全基线（C-Q3 无 SSO） | 私有化安全隐患 | argon2 + 密码策略 + 登录失败锁定 + auth.denied 审计；IdentityProvider 抽象保留 SSO 增量位 |

### 非目标（Phase 1）

- 工作流引擎级可配置流程、字段级细粒度权限、SSO/LDAP 对接（仅留抽象）、跨系统统一身份（spec §5；SSO/LDAP 详见 C-Q3）
- PLM/ERP 身份集成、审批多级会签（状态机单步定版）
- 审计的实时告警/SIEM 对接、KPI 的 BI 平台对接（SQL 视图 + API 即可）
- 归档冷备的自动化恢复演练（M1 只交归档骨架 + 容量观测，精确策略 M3 修订，C-Q2）

---

## 7. 决策与假设记录（承接 clarifications）

- C-Q1：FMEA 定版仅研发主管；权限矩阵配置表化，客户上线前可调（不改代码）。→ §2.1、§3.1、§5
- C-Q2：审计在线 1 年按月分区 + 超期导出 MinIO 冷备 ≥3 年，禁 UPDATE/DELETE；M1 交分区+归档骨架+容量观测。→ §2.4、§3.1
- C-Q3：M1 本地账号，IdentityProvider 抽象预留 SSO/LDAP；不阻塞 M1。→ §1.2-A5、§2.1、§3.1
- C-Q4：人工基线由双方联合测量、客户质量部见证背书、双签版本化。→ §2.5、§5 风险表
- 假设：FR10.4.4「归档策略见 Q3」为笔误按 Q2 执行（clarifications 已记录）；`state` 对 F8 用例映射为 `ADOPTED/IGNORED` 终态词汇但同属通用状态机配置（FR10.2.1 映射表）。
