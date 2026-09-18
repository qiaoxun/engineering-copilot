# F10 工程确认与追溯机制（横切）— Feature Spec

| | |
| ---- | ---- |
| 编号 | F10 |
| 来源 | PRD §43、§44、§42、§40、§5；UI 页面28（最小版）；PHASE1_FEATURES F10.1–F10.6 |
| 依赖 | 无（平台地基，最优先开发） |
| 被依赖 | 全部功能模块 |
| 里程碑 | M1 交付骨架；随 M2–M4 逐模块接入（见落地映射表） |

## 1. 概述

满足 PRD §43/§44/§42 的强制性平台要求，Phase 1 必须落地的最小闭环：**人工确认流程、AI 审计日志、RBAC 基础权限**，外加统一对象模型与 KPI 埋点。规格明确"不可后补"——每个业务功能接入本机制是其自身验收的前置条件。

## 2. Feature Units

### F10.1 统一对象模型（Phase 1 子集）

- **FR10.1.1** 实体清单：`Project / Product / Document / BOM(+BomDiffRun) / FMEA(+FmeaRow) / TestCaseSet(+TestCase) / TestRequirement / TestReport / Issue / Risk / Task / ChatSession`。
- **FR10.1.2** 核心关系：Project 1—N 全部业务对象；Product 1—N Document/FMEA；Document N—N Project；FmeaRow N—N source_link（依据引用）；Issue 可由 BOM 差异（F6.5）与报告异常（F9.6）产生。
- **FR10.1.3** 所有对象实现统一接口：`id(UUIDv7) / project_id / created_by / created_at / updated_at / state（可定版对象）/ audit_ref`。
- **FR10.1.4** 模型变更须向后兼容（新增字段可空），为第二阶段扩展预留。
- **AC10.1.1** 对象关系图（ER）评审通过并作为各模块建表依据；跨模块外键关系有集成测试覆盖。

### F10.2 人工确认流程（状态机）

- **FR10.2.1** 通用状态机：`DRAFT → IN_REVIEW → APPROVED →（ARCHIVED）`；各对象类型映射（可裁剪 IN_REVIEW）：

| 对象 | 状态流 | 定版动作 | 定版权限 |
| ---- | ---- | ---- | ---- |
| 规格书对比结论 (F5) | DRAFT→APPROVED | 完成确认 | 工程师+ |
| BOM比对运行 (F6) | DRAFT→APPROVED | 完成确认（全部差异处置后） | 工程师+ |
| FMEA (F7) | DRAFT→IN_REVIEW→APPROVED | 定版 | 研发主管 |
| 测试需求/用例 (F8) | DRAFT→ADOPTED/IGNORED | 采用 | 工程师+ |
| 测试报告 (F9) | DRAFT→IN_REVIEW→APPROVED | 结论确认 | 工程师+（结论节须已确认） |
| 映射库条目 (F5.6) | 人工确认即生效 | — | 工程师+ |

- **FR10.2.2** AI 生成物创建即 `DRAFT`；**系统不提供任何 AI 输出直写 APPROVED 的代码通路**（架构约束：定版接口仅由人工操作 API 触发，定版请求体必须含操作人上下文）。
- **FR10.2.3** 每次状态转换记录：actor、时间、前置状态、意见（定版必填）、diff 摘要。
- **FR10.2.4** `APPROVED` 对象锁定：编辑接口返回 `OBJECT_LOCKED`；修改走新修订版本（revision +1）。
- **AC10.2.1** 以 FMEA 为样板：工程师无法定版（403）、定版后编辑被拒、修订版本链完整。

### F10.3 AI 审计日志

- **FR10.3.1** 每次 AI 操作一条记录，必录字段（PRD §44）：`audit_id, user, time, project_id, object_type/object_id, action, input_summary, model(+版本), prompt_id(+prompt_version), kb_version, citations[](引用数据), ai_output_id, human_modifications(diff), final_result, status`。
- **FR10.3.2** 审计表 **append-only**：数据库账号无 UPDATE/DELETE 权限；应用层无删除接口。
- **FR10.3.3** 事件命名 `<domain>.<verb>`（统一清单：`parse.completed/failed/corrected, document.uploaded/version.created/deleted, rag.query, chat.message, task.created/canceled, specdiff.run/mapping.confirmed/run.confirmed, bomdiff.run/item.disposed/run.confirmed, fmea.generated/row.edited/row.adopted/row.ignored/approved, testgen.run/case.adopted/case.edited, report.imported/body.generated/approved/exported, auth.login/denied, role.changed`）。
- **FR10.3.4** Prompt 必须来自 Prompt 注册表（prompt_id + version），代码中禁止裸字符串 prompt —— 保证"Prompt版本"字段真实可溯。
- **AC10.3.1** 完成一轮 FMEA 生成→编辑→定版后，审计记录能完整重建该过程（who/when/input/model/prompt/kb_version/output/human diff/final）。
- **AC10.3.2** 对审计表尝试 UPDATE/DELETE 被数据库拒绝（权限验证用例）。

### F10.4 审计查询页（最小版，UI 页面28）

- **FR10.4.1** 筛选：用户 / 项目 / 时间范围 / 对象类型 / action；分页列表。
- **FR10.4.2** 明细展开显示全部字段（含引用列表与 diff 摘要）；支持导出 CSV。
- **FR10.4.3** 仅"系统管理员 / AI管理员"角色可访问。
- **FR10.4.4** 保留期默认 ≥1 年（归档策略见 Q3）。

### F10.5 RBAC 基础版

- **FR10.5.1** 四级模型：用户 → 角色 / 部门 / 项目成员；权限点 = `<module>.<action>`（view/create/edit/confirm/export/admin）。
- **FR10.5.2** 预置 5 角色权限矩阵（PRD §5，初版如下，可配置调整）：

| 权限点 | 工程师 | 项目经理 | 研发主管 | 系统管理员 | AI管理员 |
| ---- | ---- | ---- | ---- | ---- | ---- |
| 各业务模块 view/create/edit | ✅ | ✅ | ✅ | — | — |
| 对比结论定版 | ✅ | ✅ | ✅ | — | — |
| FMEA 定版 | — | — | ✅ | — | — |
| 项目/成员管理 | — | ✅ | ✅ | ✅ | — |
| 用户/角色管理 | — | — | — | ✅ | — |
| 审计查询 / 模型与Prompt管理 | — | — | — | ✅ | ✅ |
| 知识库分类与全局配置 | — | — | — | ✅ | ✅ |

- **FR10.5.3** 文档可见性继承：项目成员可见该项目文档；部门规则可扩展可见范围；"全公司"标记覆盖（F2.6）。
- **FR10.5.4** 权限校验在后端 API 层强制执行；前端仅做展示控制；拒绝返回 403 + 统一错误体。
- **AC10.5.1** 5 角色 × 关键权限点的自动化矩阵测试全部通过。

### F10.6 KPI 埋点

- **FR10.6.1** 事件 schema：`{event, user, project_id, object_type/object_id, ts, duration_ms?, meta(JSONB)}`；与审计日志分离（审计保真、埋点保量）。
- **FR10.6.2** 核心事件：`parse.duration, rag.first_token/no_hit, chat.first_token, specdiff.start/export, bomdiff.start/confirm, fmea.generate/row.adopted/row.ignored/approve, testgen.start/dispose, report.start/approve/export`。
- **FR10.6.3** **人工基线测量**：上线前由业务方按《人工流程耗时基线表》（比对/BOM/FMEA/报告四张表，记录现行人工耗时样本 ≥5 次/项）留档，作为 ↓80%/70%/60%/70% 的分母。
- **FR10.6.4** KPI 报表：§5 每项指标一个查询（当前值 vs 基线、采纳率/修改率、no_hit 率）。
- **AC10.6.1** 演示环境跑通一轮全流程后，6 项 KPI 报表均能出数。

## 3. 落地映射（随里程碑交付）

| 子项 | M1 | M2 | M3 | M4 |
| ---- | ---- | ---- | ---- | ---- |
| F10.1 对象模型 | ✅ 全量定义 | 知识库关联 | 比对对象 | 用例/报告/Issue/Risk 联动 |
| F10.2 状态机 | ✅ 通用组件 | 文档定版 | 比对结论 | FMEA/用例/报告（完整闭环） |
| F10.3 审计日志 | ✅ 表+中间件+Prompt注册表 | rag/chat 事件 | 比对事件 | 生成类事件+采纳率数据 |
| F10.4 审计查询页 | API | ✅ 页面上线 | 比对筛选 | 生成类筛选 |
| F10.5 RBAC | ✅ 四级模型+预置角色 | 文档权限继承 | 比对对象权限 | 生成物定版权限 |
| F10.6 KPI 埋点 | ✅ 框架+基线测量启动 | 首响监控 | 比对耗时报表 | 采纳率/修改率报表 |

## 4. API 概要

```
POST /api/v1/{objects}/{id}/transition      # 通用状态转换（body: action, comment）
GET  /api/v1/audits                         # 审计查询（限管理员）
GET  /api/v1/kpi/reports/{kpi_name}         # KPI 报表
CRUD /api/v1/admin/users /roles /projects   # 管理端
```

## 5. 非目标

工作流引擎级可配置流程（Phase 1 状态机硬编码 + 配置表即可）、SSO/LDAP 对接（若客户环境必须，列为交付配置项）、细粒度字段级权限、跨系统统一身份（第四阶段）。

## 6. 开放问题

- **Q1** 权限矩阵初版需与客户方管理规范核对（尤其"项目经理能否定版 FMEA"）。
- **Q2** 审计存储容量估算与归档策略（1 年在线 + 冷备？）。
- **Q3** SSO/LDAP 是否为该客户私有化交付的必要项（影响 M1 排期）。
- **Q4** 人工基线测量的组织与见证方式（建议客户方质量部参与背书，KPI 才有公信力）。
