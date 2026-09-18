# F4 AI Chat / AI助手 — Clarifications

> 本文件记录 `specs/F4-ai-chat.md` §7 开放问题的最终决策，plan/tasks/implement 阶段以本文件为准。
> 决策不修改 spec 原文；与原文存在细化/覆盖关系时逐条注明。
> 依据：PRD §7/§7.3（统一入口与任务卡）、§52（首响 ≤5s、异步队列）；UI_GUIDE「全平台统一框架（右侧 AI Copilot 固定区域）」+ 页面01 + 三十（右侧统一 AI Copilot）；F5–F9 各自的总览/统计字段；F10.1（Task/ChatSession 对象）、F10.3（审计命名）、F10.6（KPI 埋点）；specs/README.md 全局约定（异步任务 SSE、UUIDv7、金标集机制先例 F1/F3）。

## Clarifications

- Q1: 任务卡「风险统计」各技能的取数字段需与 F5–F9 spec 对齐 → 决策：任务卡风险统计采用**统一展示 schema** `risk_stats: [{key, label, value, level?(红/橙/黄)}]`，由各技能任务 SUCCESS 时从其结果对象的既有统计字段一次性快照写入 `task.result_stats`（JSONB），Phase 1 各技能映射如下（**只读快照，不在 F4 侧重算**）：`spec_diff` → `spec_diff_run` 差异行按等级聚合 `{total_diffs, red, orange, yellow}`（FR5.3.1、`spec_diff_row.level`）；`bom_diff` → `bom_diff_run.overview` 的风险分布 `{total_items, diff_count, high, mid, low}`（FR6.4.1、`bom_diff_item.risk`）；`fmea_gen` → `fmea_row` 按 RPN 阈值聚合 `{row_count, high(RPN≥100), mid(50–99), low(<50)}`（FR7.2.3，阈值随 F7 Q2 决策联动）；`testcase_gen` → 无风险语义，展示生成统计 `{new, reused, requirement_count}`（FR8.4.2，level 置空）；`report_gen` → 报告统计 `{case_count, sample_count, pass, fail, anomaly_count}`（FR9.2.1、FR9.3.1）；`knowledge_qa`/`general_chat` 无卡片（FR4.4.2 已定义），`parse` 类任务卡不展示风险统计（理由：卡片是各技能结果总览的镜像，统一 schema 让 F4 渲染与技能解耦、新增技能零改 F4；影响 FR4.4.1、FR4.4.2、AC4.4.1，细化 §3 数据模型 `task` 字段——新增 `result_stats` 快照列，plan 阶段据此扩展 F10.1 Task 对象）。
- Q2: 意图路由准确率目标与金标集维护机制 → 决策：采纳建议并落地为正式机制——**AC4.2.1 的 ≥90% 作为 M2 正式验收目标**；金标集初版七意图 × ≥20 条（共 ≥140 条），标注沿用 F1/F3 金标集的双人标注+仲裁流程，版本化为 `golden_set_route_v1` 上线前定版；维护机制：**线上低置信样本自动回流**——FR4.2.2 触发澄清的样本、用户点击候选意图按钮的纠正样本、FR4.2.3 人工切换意图重路由的样本，去重后进入待标注池，由 AI管理员 每月复审入库发布 `golden_set_route_vN`；每次意图分类 prompt 版本或模型变更，必须回归跑全量金标集（`route.accuracy` KPI，对齐 F10.6.2 埋点），不达标不得发布（理由：与 F3 Q1 已确立的金标集机制保持一致，避免另建标注体系；低置信回流让金标集随真实分布演化，覆盖初始表述集盲区；影响 FR4.2.1、FR4.2.2、FR4.2.3、AC4.2.1、§5 KPI `route.accuracy`）。
- Q3: Copilot 是否需要全页面常驻（首页独立区 vs 右侧 Copilot 两形态需 UI 定稿）→ 决策：**两形态都做、共享同一会话引擎与组件**——首页（UI 页面01）保留独立大输入区作为工作台门面，会话创建/续接后自动展开为右侧 Copilot 形态；全平台各业务页面右侧 Copilot **常驻（默认展开、可一键收起）**，并继承当前页面所在项目（FR4.3.1）与页面上下文（UI_GUIDE 三十：AI 应理解「当前页面上下文」）。理由：UI_GUIDE「全平台统一 UI 框架」已将「右侧：AI Copilot（可随时展开/收起）」列为三个固定区域之一，页面30 进一步要求业务页内 AI 感知当前对象，说明常驻侧栏是框架级决定而非待定项；首页大输入区与常驻侧栏服务同一会话流，复用组件后增量成本仅为入口布局（影响 FR4.1.1、FR4.3.1、FR4.2.3——切换意图/任务卡交互在两形态中行为一致；关联 PRD §7「让工程师不需要知道应进入哪个模块」）。

## Assumptions

- 会话内上传触发的 F1 解析也走统一 Task（type=parse），以任务卡形式在对话流中展示进度；完成即把解析结果注入会话上下文（FR4.1.1），该类卡片无后续动作按钮区、无风险统计。
- `task.result_stats` 为任务完成时的只读快照，不随源对象后续人工处置（如 F6.5 差异处置、F7 打分修改）自动刷新；卡片提供「查看最新」跳转到结果对象，以对象页为准。
- 金标集回流池的复审节奏（每月）与 F3 Q3 抽样审计共用 AI管理员 的月度例行动作，Phase 1 不开发自动化回流工具，回流样本经审计导出 + 人工入池。
- 右侧 Copilot 的「页面上下文感知」Phase 1 仅注入页面所在项目与当前对象引用（object_type/object_id），不做整页 DOM 理解；深度上下文路由属后续阶段。
