# F10 工程确认与追溯机制（横切）— 任务清单（Tasks）

| | |
| ---- | ---- |
| Feature | F10-platform-governance |
| 输入 | specs/F10-platform-governance.md、specs/F10-platform-governance.clarifications.md（C-Q1–Q4）、specs/F10-platform-governance.plan.md（冲突时以后两者为准）、specs/README.md |
| 阶段 | speckit-tasks |
| 粒度约定 | 每条任务 0.5–2 人日；超过 2 人日须继续拆分 |
| 里程碑对齐 | T01–T12 → M1 骨架（含 F10.4 API 与前端最小版）；T13/T14 → M1 Exit 验收；M2–M4 的逐模块接入（rag/chat 事件、比对对象、生成类筛选等）属各 feature 自身任务清单，不在本表内 |

> 依赖列格式：依赖的任务号。编号即执行顺序（尽量并行：T06/T08/T09 相互独立，可并行开发）。

---

## 任务清单

### T01 F10 接入点骨架：审计事件定义、状态机接线、权限点、KPI 埋点契约

- **目标**：一次性定义其余全部业务模块挂接 F10 的四个接入点契约——① 审计事件常量清单（`<domain>.<verb>` 全集，FR10.3.3）；② 通用状态机转换配置默认表（FR10.2.1 映射表 + required_perm/require_comment）；③ 权限点清单 `<module>.<action>`（FR10.5.1/FR10.5.2 矩阵推导）；④ KPI 事件常量与 schema（FR10.6.1/FR10.6.2）。同时落地统一错误码（`OBJECT_LOCKED/INVALID_TRANSITION/COMMENT_REQUIRED/FORBIDDEN/AUDIT_ACCESS_DENIED`）。
- **涉及文件/模块**：`apps/backend/app/modules/platform/audit/events.py`、`workflow/configs.py`、`rbac/permissions.py`、`kpi/events.py`、`app/core/errors.py`
- **完成标准**：事件/权限/转换/KPI 四张常量表覆盖 FR10.3.3 全清单、FR10.2.1 全部对象映射、FR10.5.2 矩阵全部权限点、FR10.6.2 全部事件；单元测试断言清单完备且与 spec 逐条对应（AC10.3.3 事件命名约定、AC10.5.1 的数据来源）
- **依赖**：无
- **粒度**：1 天

### T02 身份与 RBAC 数据模型 + 种子数据

- **目标**：建 `departments/users/roles/permissions/role_permissions/projects/project_members` 表及 Alembic 迁移；种子化 5 个系统角色、T01 权限点全集、角色-权限矩阵（C-Q1：FMEA 定版仅研发主管）、首个系统管理员账号（argon2）。角色-权限矩阵种子与权限矩阵测试同源（plan §5）。
- **涉及文件/模块**：`app/modules/identity/models.py`、`app/modules/platform/rbac/models.py`、`alembic/versions/*`、`app/modules/platform/rbac/seeds.py`
- **完成标准**：迁移可上下执行；种子后 `role_permissions` 与 FR10.5.2 矩阵逐格一致（含 C-Q1 决策）；迁移评审 checklist 通过（仅新增可空列/新表，FR10.1.4）
- **依赖**：T01
- **粒度**：1 天

### T03 统一对象模型 BaseEntity + 实体注册表

- **目标**：声明式 `BaseEntity`（id UUIDv7/project_id/created_by/created_at/updated_at/state/audit_ref/revision，plan §2.2）+ `OBJECT_REGISTRY`；落地 plan §2.2 实体清单全部表与关系（products/documents/document_projects/boms/bom_diff_runs/fmeas/fmea_rows/fmea_row_sources/test_case_sets/test_cases/test_requirements/test_reports/issues/risks/chat_sessions，含 issues 多态 origin）；空态迁移 + ER 集成测试。
- **涉及文件/模块**：`app/modules/platform/objects/base.py`、`registry.py`、各域 `models.py`、`alembic/versions/*`
- **完成标准**：跨模块外键集成测试通过（Document N—N Project、FmeaRow—source_link、Issue 多态来源可建可查可级联）；所有业务模型继承 BaseEntity 且注册入 OBJECT_REGISTRY（AC10.1.1、FR10.1.1–FR10.1.3）
- **依赖**：T02
- **粒度**：2 天

### T04 认证与身份 API（本地账号 + IdentityProvider 抽象）

- **目标**：`POST /api/v1/auth/login`（argon2 校验 → JWT，失败锁定 + `auth.denied` 审计）、`GET /api/v1/me/permissions`；`IdentityProvider` 抽象接口（本地 Provider 为默认实现，C-Q3）。审计事件 `auth.login/auth.denied`。
- **涉及文件/模块**：`app/modules/identity/service.py`、`provider.py`、`app/core/security.py`、`app/modules/platform/audit/`（事件 emit）、路由注册
- **完成标准**：登录成功/失败均产生正确审计事件（FR10.3.3）；`/me/permissions` 返回当前用户权限点集合（A7 前端消费契约）；错误响应符合统一错误体（specs/README）
- **依赖**：T02、T06（审计写入通道；若并行开发可先以 emit 接口桩对接）
- **粒度**：1 天

### T05 通用状态机引擎 + transition API

- **目标**：通用 `StateMachine` 组件（配置表可覆盖默认常量）；`POST /api/v1/{objects}/{id}/transition`、`GET /api/v1/{objects}/{id}/transitions`；转换记录（actor/时间/前置状态/意见/diff 摘要，FR10.2.3）；定版 comment 必填校验；`APPROVED` 锁定（编辑 service 统一检查 → `OBJECT_LOCKED`，修订走 revision+1 新行）；A2 禁令：actor 只取认证态，Celery/LLM 通路禁止 import transition service（import-linter 架构测试）。
- **涉及文件/模块**：`app/modules/platform/workflow/engine.py`、`service.py`、`models.py`（object_state_configs/state_transitions）、`alembic/versions/*`、`pyproject.toml`（import-linter 配置）
- **完成标准**：单元测试覆盖非法转换（INVALID_TRANSITION）、缺意见（COMMENT_REQUIRED）、锁定（OBJECT_LOCKED）、revision 链；架构测试断言 worker/llm 层不可达 transition service（FR10.2.1–FR10.2.4、FR10.2.2）
- **依赖**：T03、T04
- **粒度**：2 天

### T06 审计存储与写入通道（分区表 + append-only + 归档骨架）

- **目标**：`ai_audit_logs` 按月分区表（C-Q2）+ FR10.3.1 全字段 + 索引（plan §6 风险表）；应用 DB 角色 REVOKE UPDATE/DELETE（仅 INSERT/SELECT）；append-only 仓储只暴露 `append()/query()`；`audit_context` 中间件采集 user/project/request_id；`audit.emit()` 异步写入（Celery 独立队列）；`audit_archives` 冷备登记 + 归档任务骨架 + `audit_stats` 容量观测（C-Q2 M1 范围）。
- **涉及文件/模块**：`app/modules/platform/audit/models.py`、`repository.py`、`emitter.py`、`archiver.py`、`app/middleware/audit_context.py`、`app/worker/*`、`alembic/versions/*`
- **完成标准**：以应用 DB 角色连接执行 UPDATE/DELETE `ai_audit_logs` 断言被数据库拒绝（AC10.3.2）；emit 一条 FMEA 生成事件后全字段可查（FR10.3.1）；迁移测试确认无 UPDATE/DELETE 授权（FR10.3.2、FR10.4.4 ≥1 年分区）
- **依赖**：T01、T02、T03
- **粒度**：2 天

### T07 Prompt 注册表 + LLMGateway + human_modifications 采集

- **目标**：`prompt_registry` 表 + `render_prompt(prompt_id, version, vars)` 唯一入口（FR10.3.4）；`LLMGateway` 统一包装（模型/版本读配置、渲染、调用、采集 citations/kb_version、强制 `audit.emit`、结构化输出信封 `{schema_version, items[], citations[]}`，plan §4）；BaseWorkflowService 的 before/after JSON diff 采集 `human_modifications`；禁裸字符串 prompt 的 lint 规则。
- **涉及文件/模块**：`app/modules/platform/prompts/models.py`、`render.py`、`app/modules/platform/llm/gateway.py`、`app/modules/platform/workflow/diff.py`、lint 配置
- **完成标准**：经 Gateway 的调用审计记录含 model/model_version/prompt_id/prompt_version/kb_version/citations 运行时实际值（FR10.3.1、FR10.3.4）；lint 规则可拦截字面量 prompt；变量 schema 校验单测通过
- **依赖**：T06
- **粒度**：2 天

### T08 KPI 埋点与报表

- **目标**：`kpi_events` 表（FR10.6.1 schema，与审计分表分管道，A6）+ `kpi.emit()`；`kpi_baselines` 表（C-Q4 双签版本化，≥5 样本/项）；6 项 KPI SQL 视图（比对↓80%/BOM↓70%/FMEA↓60%/报告↓70%/采纳率·修改率/RAG no_hit 率）；`GET /api/v1/kpi/reports/{kpi_name}` 返回 当前值/基线/样本数。
- **涉及文件/模块**：`app/modules/platform/kpi/models.py`、`emitter.py`、`reports.py`（SQL 视图）、路由、`alembic/versions/*`、基线种子模板
- **完成标准**：种子基线数据 + 一轮模拟事件后 6 个报表端点均可出数（当前值 vs 基线）（FR10.6.1–FR10.6.4、AC10.6.1 的可测前提）；基线留档模板含双方签署字段（C-Q4）
- **依赖**：T01、T03、T06（共用中间件上下文）
- **粒度**：1.5 天

### T09 require_perm 权限依赖 + 权限矩阵测试

- **目标**：FastAPI 依赖 `require_perm("module.action")`（后端强制校验，FR10.5.4）；拒绝返回 403 + 统一错误体并 emit 权限拒绝审计；项目级权限（project_members role_in_project）与部门可见性继承的最小实现（FR10.5.3）；5 角色 × 关键权限点参数化矩阵测试（数据与 T02 种子同源）。
- **涉及文件/模块**：`app/modules/platform/rbac/dependencies.py`、`visibility.py`、`tests/test_permission_matrix.py`
- **完成标准**：AC10.5.1 矩阵测试全绿（矩阵含 C-Q1：FMEA 定版仅研发主管）；无权限调用任意受保护端点返回 403 统一错误体并留审计（FR10.5.4、FR10.3.3）
- **依赖**：T02、T04
- **粒度**：1.5 天

### T10 管理端 CRUD API

- **目标**：`/api/v1/admin/users|roles|projects|departments` CRUD + `POST /api/v1/admin/roles/{id}/permissions`（产生 `role.changed` 审计事件）；全部端点挂 require_perm（用户/角色管理=系统管理员；项目/成员管理按矩阵）；分页遵循 `{items,total,page}`。
- **涉及文件/模块**：`app/modules/platform/rbac/api_admin.py`、`app/modules/identity/api.py`、路由注册
- **完成标准**：CRUD 契约测试（统一错误体/分页信封/UUIDv7）；角色-权限变更产生 `role.changed` 事件且矩阵测试回归仍绿（FR10.5.2、AC10.5.1）；非管理员访问返回 403（FR10.5.4）
- **依赖**：T02、T04、T09
- **粒度**：1 天

### T11 审计查询 / 导出 / 统计 API

- **目标**：`GET /api/v1/audits`（筛选 user/project/时间范围/object_type/action，分页）、`GET /api/v1/audits/{audit_id}`（明细含 citations 与 diff）、`GET /api/v1/audits/export`（异步任务 → task_id + SSE，specs/README 异步约定）、`GET /api/v1/audits/stats`（C-Q2 容量观测）；仅 系统管理员/AI管理员 可访问（FR10.4.3，AUDIT_ACCESS_DENIED）。
- **涉及文件/模块**：`app/modules/platform/audit_query/api.py`、`export.py`、`app/worker/tasks/export.py`、SSE 端点复用
- **完成标准**：筛选组合与分页契约测试；导出任务 SSE 事件序列 QUEUED→RUNNING→SUCCESS 契约测试；非管理员角色 403（FR10.4.1–FR10.4.3）；分区裁剪生效（查询带时间范围时执行计划命中分区，plan §6 性能缓解）
- **依赖**：T06、T09
- **粒度**：1.5 天

### T12 前端最小版（登录、状态组件、审计查询页、权限展示控制）

- **目标**：登录页 + JWT 会话；`features/workflow` 状态徽章与定版对话框（意见必填校验）；`pages/admin/audits` 审计查询页（UI 页面28 最小版：筛选/分页/明细展开含引用与 diff/CSV 导出）；基于 `/api/v1/me/permissions` 的路由守卫与按钮隐藏（A7：仅展示控制，不复制权限逻辑）。
- **涉及文件/模块**：`apps/frontend/src/pages/admin/audits/*`、`pages/login/*`、`features/workflow/*`、`features/auth/*`（权限 hook）
- **完成标准**：组件测试：定版对话框意见必填、审计页筛选与导出触发、无权限按钮不渲染（FR10.2.3、FR10.4.1–FR10.4.2、FR10.5.4）
- **依赖**：T04、T05、T09、T11
- **粒度**：2 天

### T13 样板闭环集成测试（FMEA 样板）

- **目标**：plan §5 集成样板闭环：建 FMEA（DRAFT）→ 工程师 transition(APPROVED) 期望 403 → 研发主管定版（缺 comment 期望 COMMENT_REQUIRED）→ 定版成功 → 编辑返回 OBJECT_LOCKED → revision+1 修订链完整 → 逐字段断言审计记录可完整重建 who/when/input/model/prompt/kb_version/output/human diff/final。
- **涉及文件/模块**：`apps/backend/tests/integration/test_fmea_governance_loop.py`（F10 范围内用最小 FMEA 测试域对象 + OBJECT_REGISTRY 注册，完整 FMEA 模块属 F7/M4，见 Assumptions）
- **完成标准**：闭环全流程断言通过：AC10.2.1（工程师 403/定版后编辑被拒/修订链完整）+ AC10.3.1（审计完整重建全过程）；字段完备性 schema 校验测试通过（plan §4 评测方式②）
- **依赖**：T05、T06、T07、T09
- **粒度**：1 天

### T14 端到端验收（覆盖 F10 全部 AC）

- **目标**：演示环境全链路验收：登录 → 管理端建用户/项目/角色 → 权限矩阵回归 → KPI 埋点全流程跑数（parse→rag→chat→比对→fmea→报告模拟事件）→ 审计查询/明细/CSV 导出/SSE → T13 闭环 → DB 权限用例 → 架构禁令检查（AI 直写 APPROVED 通路不存在）。产出验收核对单并逐项勾稽。
- **涉及文件/模块**：`apps/backend/tests/e2e/test_f10_acceptance.py`、验收核对单（本文件附录或 `specs/` 下 F10 验收记录）
- **完成标准**：以下 AC 全部通过——AC10.1.1（ER/外键集成测试）、AC10.2.1（FMEA 样板闭环）、AC10.3.1（审计重建）、AC10.3.2（DB 拒绝 UPDATE/DELETE）、AC10.4.1–10.4.2（筛选/明细/导出，FR10.4.3/10.4.4 随用例覆盖）、AC10.5.1（矩阵测试）、AC10.6.1（6 项 KPI 报表出数）；新增模块行覆盖率 ≥80%（全局规则）
- **依赖**：T08、T10、T12、T13
- **粒度**：1 天

---

## 任务依赖图

```text
T01 ─┬→ T02 ─┬→ T03 ─┬→ T05 ─┐
     │       │       ├→ T06 ─┼→ T07 ─┐
     │       │       │      ├→ T11 ─┤
     │       ├→ T04 ─┼→ T09 ─┼→ T10  ├→ T13 ─┐
     │       │       │      └→ T08 ─┼───────┤
     │       │       │              └→ T12 ─┴→ T14
     └───────┴───────┴─（T01 常量表为 T02/T06/T08 种子来源）
```

并行建议：T06 / T08 / T09 互不依赖可并行；T04 与 T06 可并行（emit 接口桩先行）。

---

## Breakdown 决策与假设（Clarifications / Assumptions）

- **[D1] T13 样板对象范围**：spec/plan 要求「以 FMEA 为样板」（AC10.2.1、AC10.3.1），但完整 FMEA 模块属 F7（M4）。决策：F10 任务内在 OBJECT_REGISTRY 注册一个最小 FMEA 测试域对象（含 DRAFT→IN_REVIEW→APPROVED 配置与研发主管定版权限点）承担样板闭环；F7 落地时复用同一状态机/审计通路并以真实 FMEA 回归 AC10.2.1/AC10.3.1。采用理由：不阻塞 M1 Exit，且不改变验收语义（spec §3 落地映射：F10.2 状态机 M1 交通用组件、FMEA 完整闭环在 M4）。
- **[D2] 前端范围（T12）**：spec §3 落地映射将 F10.4 审计查询「页面」划在 M2 上线，但 F10.4 API 属 M1。决策：T12 在 M1 交付审计页最小可用版（筛选/明细/导出）以支撑 AC10.4.x 的端到端验收，M2 仅做比对类筛选增强。理由：AC 验收需要可视通路，且 plan §1.1 已将 `pages/admin/audits` 列入骨架。
- **[D3] 人工基线测量（C-Q4）**：属客户方联合活动而非纯开发任务，不单列任务号；其交付物（双签基线文件）作为 T08 `kpi_baselines` 种子输入与 M3 Exit 前置检查项（plan §6 风险表：M1 启动即发起）。
- **[D4] 任务粒度校验**：拆解结果 14 条 ≤ 15 条上限，plan 粒度合格，无需回改 plan。
