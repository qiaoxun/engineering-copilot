# F9 测试报告生成 — 技术方案（Plan）

| | |
| ---- | ---- |
| Feature | F9-test-report |
| 输入 | specs/F9-test-report.md、specs/F9-test-report.clarifications.md（冲突时以其为准）、PHASE1_SPEC.md、PHASE1_FEATURES.md、specs/README.md、UI_GUIDE 页面21 |
| 关联 | specs/F10-platform-governance.plan.md（对象模型 TestReport/Issue 多态来源 report_anomaly、状态机 DRAFT→IN_REVIEW→APPROVED 及"结论节已确认"transition 钩子、审计/RBAC/KPI/LLMGateway/Prompt注册表）、specs/F8-test-case-generation.plan.md（test_cases ADOPTED 用例集与 criteria 结构化消费、Case ID 校验对齐、执行状态导入行级警告同构先例）、specs/F7-fmea-generation.plan.md（fmea_rows.source='report_anomaly'/source_ref 预留、docxtpl 导出与 DRAFT 水印先例、修订版本机制）、specs/F6-bom-comparison.plan.md（Issue 创建与双向链接先例、质量问题分类同源）、specs/F3-rag-retrieval.plan.md（历史质量问题检索/kb_version）、specs/F2-knowledge-base.plan.md（质量问题分类标签）、specs/F1-document-parsing.plan.md（xlsx/csv native 通道，禁绕过数据契约） |
| 阶段 | speckit-plan（仅设计，不写代码） |
| 里程碑 | M4（F9.1 → F9.2 → F9.3 → F9.4 → {F9.5 ∥ F9.6}） |

> 本 plan 中所有设计决策均标注溯源（FR/AC/Q 编号）。clarifications（Q1–Q3 决策）全文有效，引用处标注「C-Qx」。

---

## 1. 架构与模块落点

### 1.1 总体架构

对齐既定技术栈：**后端 FastAPI 模块化单体 + Celery + PostgreSQL(pgvector) + MinIO；前端 React + TypeScript + Ant Design**。F9 落在独立顶层模块 `report/`（F10 plan §1.2 模块清单预留名），核心由六部分组成：① **数据导入与自动判定**（模板下载 → F1 通道解析 xlsx/csv → 行级校验（Case ID 关联校验）→ 确定性判定规则引擎（三型 criteria，C-Q1）→ 待人工判定兜底，FR9.1）；② **确定性统计与图表**（统计口径固化 + 服务端图表预渲染，纯代码无 LLM，FR9.2）；③ **异常项分析**（确定性超限计算 + [AI] 整改建议（RAG 结合知识库历史质量问题），FR9.3）；④ **报告正文**（八节模板装配 + AI 结论草稿 + 人工确认闸门，FR9.4）；⑤ **导出**（docxtpl 渲染 Word/PDF、DRAFT 水印、导出记录，FR9.5）；⑥ **后续联动**（异常项 → FMEA 行 / Issue，FR9.6）。

**LLM 在本 feature 中只出现在两处：异常项 AI 整改建议（FR9.3.2）、报告结论草稿（FR9.4.2）**。数据导入、Case ID 校验、自动判定、统计、图表、超限幅度、水印、导出渲染、编号分配全部为确定性代码；历史质量问题召回走 F3 检索服务（embedding + kb_version，非生成式 LLM 直调）。

```text
apps/backend/
├── app/
│   ├── core/                        # F10 平台地基（workflow/audit/rbac/kpi/prompts/objects）
│   ├── modules/
│   │   ├── report/                  # ← F9 本体
│   │   │   ├── api/                 # test-reports 路由（drafts/rows/anomalies/body/
│   │   │   │                        #  conclusion/transition/export/to-fmea/to-issues）
│   │   │   ├── import/              # F9.1 模板下载、F1 通道文件解析、行级校验、
│   │   │   │   ├── parser.py        #   xlsx/csv → 行记录（禁绕过 F1 数据契约）
│   │   │   │   ├── validate.py      #   Case ID 关联校验/列模板校验/行级警告（FR9.1.2）
│   │   │   │   └── judge.py         #   判定规则引擎：threshold/range/boolean + AND 语义
│   │   │   │                        #   + 自由文本正则兜底抽取（C-Q1，版本化）
│   │   │   ├── stats/               # F9.2 统计（口径固化 caliber_version）+ 分组汇总
│   │   │   │   └── charts.py        #   图表预渲染 PNG（matplotlib）→ MinIO（FR9.2.2）
│   │   │   ├── anomaly/             # F9.3 超限计算（确定性）+ AI 建议任务 + 确认/备注/责任归属
│   │   │   ├── body/                # F9.4 八节正文装配（stats/charts/anomalies 数据源）+
│   │   │   │   └── conclusion.py    #   AI 结论草稿（grounding 校验）
│   │   │   ├── export/              # F9.5 docxtpl 渲染 + PDF 转换 + DRAFT 水印 +
│   │   │   │                        #   模板管理（内置默认/实施期替换，C-Q2）+ 导出记录
│   │   │   └── linkage/             # F9.6 to-fmea（写 fmea_rows）/to-issues（platform Issue）
│   │   ├── documents/               # F1：xlsx/csv native 通道只读复用（数据契约）
│   │   ├── rag/                     # F3：进程内复用检索服务（历史质量问题召回，kb_version）
│   │   ├── testgen/                 # F8：只读消费 ADOPTED test_cases（含 criteria_structured）
│   │   ├── fmea/                    # F7：to-fmea 行写入经其行服务（source/source_ref 契约）
│   │   └── platform/                # F10：workflow/audit/rbac/kpi/prompts/objects(Issue/Task)
│   ├── worker/                      # Celery app；report 队列（正文生成/建议生成/导出）
│   └── main.py
└── alembic/
apps/frontend/
└── src/
    ├── pages/test/report/           # 页面21 测试报告生成（数据状态卡 + [AI] 异常分析卡 +
    │                                #  [生成正式报告][生成FMEA风险][创建问题单]）+
    │                                #  报告列表 / 导入向导 / 明细与待人工判定 / 正文编辑 /
    │                                #  报告预览与导出
    └── features/report/             # 导入警告列表组件、判定标准快照卡、异常项卡片
                                     # （[AI]建议/确认/备注/责任归属）、图表组件、水印预览、
                                     #  联动对话框（选 FMEA/选分类/责任人）
```

### 1.2 核心流程

```text
① 建草稿并导入（FR9.1，同步，行数有界）：
POST /test-reports/drafts（multipart: file + project_id + title + 用例范围）
  → 校验：权限 report.create、文件格式 xlsx/csv、列模板匹配（FR9.1.1）
  → 编号分配：项目内按年计数器行 SELECT ... FOR UPDATE，RB-{项目代号}-{年份}-{seq:03d}
    （C-Q3，事务内分配、终身不变、作废不回收）
  → 用例集快照：本项目 ADOPTED test_cases id 列表 + 快照时间 → case_set_ref（FR9.4.1 引用）
  → F1 通道解析文件 → 逐行校验：Case ID 不存在于用例集 → 行级警告（可"忽略未知行"，
    FR9.1.2/AC9.1.1）；判定列已填 → 人工直填优先，与规则引擎结果冲突 → 追加警告
    「人工判定与判定标准不一致」（C-Q1 Assumptions，复核写审计 anomaly.verdict.reviewed）
  → 判定规则引擎（FR9.1.3，C-Q1）：criteria_structured 三型（threshold/range/boolean，
    多条 AND）→ Pass/Fail；单位不匹配 → pending + 警告（不换算，C-Q1 Assumptions）；
    无结构化 criteria → 正则兜底抽取数值限值（抽取规则版本记 criteria_engine_version，
    C-Q1）；抽取失败 → pending「待人工判定」+ 警告，不阻塞其余行
  → 写 test_data_imports + test_result_rows（fail 行即时计算 delta_pct，FR9.3.1 口径）→
    异常项生成（每个 Fail 行一条 report_anomalies）→ 统计与图表（②）→
    audit report.imported + KPI report.start
  → 同步返回 {report_id, report_no, stats, warnings[]}（warning 列表 UI 页面21 数据状态卡）

② 统计与图表（FR9.2，确定性）：
统计口径固定（caliber_version='v1' 写入 stats，FR9.2.3）：用例数=快照内被引用用例数；
样本数=入库行数；通过率=Pass/(Pass+Fail)（pending 不入分母、单列展示）；按测试项目分组
（用例挂接主需求的 test_item，C-Q1/F8 A9 挂接复用；未挂接归"未分组"）；自动判定覆盖率
= 自动判定行数/总行数（排除人工直填，C-Q1）一并输出。
图表（FR9.2.2）：各测试项目通过率柱状图 + 失败分布图，matplotlib 服务端渲染 PNG → MinIO，
charts JSONB 记 {type, title, enabled, file_key}；报告配置可启用/停用；UI 与导出共用同一
PNG（所见即所得，A6）

③ 待人工判定闭环（FR9.1.3）：
PATCH rows/{row_id}（verdict: pass|fail + note）→ 行更新 → 同步重算统计/异常（stats/refresh
语义内聚在 PATCH 返回）→ pending 清零是定版前置条件（A8）

④ 异常项分析（FR9.3）：
确定性部分（FR9.3.1，导入时点已算）：定位 {case_no, sample_no}、实测值 vs 判定标准
（criteria_snapshot 快照）、超限幅度 delta_pct=(|实测−limit|/limit)×100%（阈值型）/
偏离最近边界同式（区间型，C-Q1，与 UI 页面21「超出判定阈值12%」口径一致）、影响判定。
[AI] 整改建议（FR9.3.2，异步 Celery）：POST anomalies/{aid}/suggestion → RAG 召回知识库
「历史质量问题」分类（F2 标签质量/质量案例，F3 检索服务，kb_version 记录）→ LLMGateway
prompt f9.anomaly_suggestion → 结构化建议（带引用）→ suggestion_status=draft →
人工确认（confirm 端点）→ confirmed 计入正式报告 + audit anomaly.confirmed；
人工补充备注与责任归属（FR9.3.3）：PATCH anomalies/{aid}（owner_note、owner）

⑤ 正文与定版（FR9.4，F10.2）：
POST body/generate（异步）→ 八节装配：概要/测试范围（用例集引用）/数据统计（含口径说明
FR9.2.3）/图表/Pass-Fail 明细/异常项分析/附件清单七节为确定性模板装配；结论节 = AI 草稿
（输入仅统计+异常摘要，FR9.4.2 禁止数据外信息；grounding 数值守卫 A5）→ body JSONB 落库
+ audit body.generated（prompt/model/kb_version，FR10.3.1）
人工编辑正文（PATCH）→ 章节内容覆盖；结论确认 POST conclusion/confirm（修改或明确确认，
FR9.4.2）→ conclusion_confirmed=true（留痕 who/when/diff 摘要）
定版 POST transition(approve)（F10.2 通用端点，权限=工程师+，comment 必填）→ transition
service 钩子校验：conclusion_confirmed（spec §5"结论章节未确认时定版操作被拒"→
REPORT_CONCLUSION_NOT_CONFIRMED）+ pending 行清零（A8）→ DRAFT→IN_REVIEW→APPROVED →
APPROVED 锁定（OBJECT_LOCKED，修订 revision+1，FR10.2.4）→ audit report.approved +
KPI report.approve

⑥ 导出（FR9.5，异步 Celery）：
POST export {format: pdf|word} → docxtpl 渲染（占位符契约 C-Q2：{{stats.*}}/{{charts.*}}/
{{anomalies.*}}/{{conclusion}}/{{detail_rows}}/{{attachments}}）→ 未 APPROVED 叠加
"DRAFT"水印 + [AI] 内容脚注（「AI 草稿」/「AI 生成，已经人工确认」，C-Q2 Assumptions）
→ PDF 转换 → MinIO file_key → report_exports 记录（谁/何时/模板版本/水印标志，
FR9.5.1）→ audit report.exported + KPI report.export（report.start→report.export 耗时
= 验收 KPI ↓70% 的分子链路；异常项分析耗时子段 = suggestion 生成→全部确认耗时，spec §5）
附件清单（FR9.5.2）：原始数据文件 file_key + 关联 FMEA/用例集引用，从 case_set_ref/
import/linkage 反查装配

⑦ 后续联动（FR9.6）：
to-fmea（FR9.6.1）：选定异常项 + 目标 FMEA（仅 DRAFT/IN_REVIEW 可写；APPROVED 走 F7 修订
版本开新版）→ 写 fmea_rows：function（用例/测试项目）、failure_mode/effect（异常信息）、
source='report_anomaly'、source_ref={report_id, anomaly_id}（F7 plan A12 预留契约）、
row_status='manual'、s/o/d 留空待 F7 打分 → 进入 F7 审核流 → 回填 anomaly.fmea_row_id；
AC9.6.1 由 FMEA 工作台列表按 source 筛选断言
to-issues（FR9.6.2）：经 platform objects 创建 Issue（origin_type='report_anomaly'，
F10 plan 对象模型）+ 分类写入知识库质量问题分类（F2 分类 id 必填，与 F6.5 同一 Issue 模型）
+ 描述含异常快照与报告引用（report_no）→ 回填 anomaly.issue_id，双向跳转（F6 plan A7 先例）
```

### 1.3 关键架构决策

| # | 决策 | 溯源 |
| ---- | ---- | ---- |
| A1 | **自动判定为确定性规则引擎、零 LLM**：消费 F8 侧 `criteria_structured`（JSONB，C-Q1：F8 产出侧一次结构化、F9 只消费不改写），三型 threshold/range/boolean、多条 AND、人工直填 > 规则判定 > pending 优先级；自由文本兜底走正则抽取数值限值（非 LM 判定，保证可复现可审计，C-Q1）；引擎版本 `criteria_engine_version` 记录于 import，升级不回溯重判、APPROVED 报告判定结果不可覆盖（C-Q1 Assumptions）。判定时点快照 `criteria_snapshot` 入行，保证 AC9.3.1 预置答案可复现 | FR9.1.2、FR9.1.3、AC9.3.1；C-Q1 及 Assumptions |
| A2 | **导入为同步两步模型的单步化、文件规模有界**：`POST /drafts` 一次完成建草稿+编号分配+导入+判定+统计+异常（FR9.4.1 编号草稿创建即分配，C-Q3）；行数上限 10,000（超出拒绝 `REPORT_IMPORT_TOO_LARGE`）；行级警告随响应返回可"忽略未知行"继续（FR9.1.2 语义：未知行不入库、警告列表可展开，AC9.1.1）。文件解析经 F1 xlsx/csv native 通道（禁绕过数据契约，specs/README；F8 plan A11 同构先例） | FR9.1.1、FR9.1.2、AC9.1.1；C-Q3；specs/README 数据契约 |
| A3 | **统计/图表/超限计算全确定性 + 口径版本化**：stats 由 SQL/纯函数计算并携带 `caliber_version`（FR9.2.3"统计口径固定并在报告说明"——口径文本随 caliber_version 固化进「数据统计」节）；pending 行不入通过率分母、单列展示（假设③）；分组键=挂接主需求 test_item（假设④）；图表 matplotlib 服务端单点渲染 PNG（中文字体随镜像打包），UI 与导出共用同一 PNG 保证所见即所得、且导出物可复现（A6）；delta_pct 公式按 criteria 类型分支实现为纯函数（AC9.3.1 单测直验） | FR9.2.1–FR9.2.3、AC9.3.1；C-Q1；假设③④ |
| A4 | **AI 只有两处、且都是"草稿 + 人工闸门"**：① 异常项整改建议（FR9.3.2）suggestion_status draft→confirmed，未确认建议不进正文异常项分析的正式内容（正文只渲染 confirmed 项 + draft 项显式标「待确认」不入结论依据）；② 结论草稿（FR9.4.2）人工修改或明确确认后才可定版（conclusion_confirmed 闸门，transition 钩子强制，spec §5）。无任何 AI 输出直写 APPROVED 通路（FR10.2.2：定版仅人工 transition 端点） | FR9.3.2、FR9.4.2；spec §5；FR10.2.2 |
| A5 | **结论 grounding 数值守卫（防幻觉的确定性兜底）**：prompt 强约束"仅使用输入统计与异常数据"；生成后代码抽取结论中的数值（百分比/计数）与 stats/anomalies JSONB 交叉核对，出现数据外数值 → 带差异反馈重试 1 次 → 仍失败则降级为模板化结论（统计句式拼装，无 LLM）+ 警告标记 `conclusion_fallback=true`，不阻塞流程；结论草稿整体 DRAFT + [AI] 标识（specs/README AI 草稿语义） | FR9.4.2；FR10.3.1；specs/README |
| A6 | **模板契约冻结、单点渲染**：内置默认 docxtpl 模板（八节即 FR9.4.1），占位符契约（`{{stats.*}}/{{charts.*}}/{{anomalies.*}}/{{conclusion}}/{{detail_rows}}/{{attachments}}`）文档化冻结；实施期可上传替换企业模板（版本化留存 + audit `report.template.updated`，C-Q2）；模板版本写入导出记录，已导出历史文件不因模板变更重渲染（C-Q2 Assumptions，FR9.5.1 可复现）；Word/PDF 双格式共用同一数据装配层（C-Q2）；导出异步 Celery（PDF 转换 + MinIO 上传，F7 plan `fmea_export` 先例） | FR9.4.1、FR9.5.1；C-Q2 及 Assumptions |
| A7 | **状态机接 F10.2、定版闸门双重校验**：test_report 继承 BaseEntity，state `DRAFT→IN_REVIEW→APPROVED`（F10 plan §2.2 转换配置表已有报告映射）；APPROVED 前提：① transition service 钩子校验 `conclusion_confirmed=true`（F10 plan 预留钩子位，spec §5"结论未确认定版被拒"）；② 本 feature 追加钩子：无 pending 判定行（A8，待人工判定未清零不可定版）；APPROVED 锁定 → OBJECT_LOCKED、修订 revision+1（FR10.2.4）；DRAFT/IN_REVIEW 导出叠"DRAFT"水印（FR9.4.3；F5/F6/F7 先例、C-Q2 Assumptions） | FR9.4.3；spec §5；FR10.2.1/FR10.2.4；F10 plan §2.2 |
| A8 | **待人工判定是定版硬闸门、判定冲突走警告不阻塞**：pending 行提供 PATCH 人工判定（FR9.1.3"待人工判定"兜底路径的闭环）；定版时 pending>0 → `REPORT_PENDING_VERDICT_EXISTS`（测试结论必须人工确认，PRD §43/验收；宁可阻塞定版不可带未判定行进入正式体系）；人工直填与规则引擎冲突 → 行级警告提示复核（不阻塞导入），复核动作写 audit `anomaly.verdict.reviewed`（C-Q1 Assumptions） | FR9.1.3；spec §5；PRD §43（验收）；C-Q1 Assumptions |
| A9 | **异常项 = 行级 Fail 自动派生 + 联动双向回链**：每个 Fail 行导入时点自动生成 report_anomalies（criteria_snapshot 固化，FR9.3.1 四要素确定性可算）；ai_suggestion 为可空 JSONB（含 model/prompt_version/kb_version/citations 全套审计字段内嵌，FR10.3.1）；fmea_row_id/issue_id 反向回链支撑 UI 页面21 三按钮的联动状态展示；to-fmea 复用 F7 plan A12 预留的 `source='report_anomaly' + source_ref` 契约（不新建 FMEA 侧表）；to-issues 复用 platform `issues(origin_type='report_anomaly')`（F10 plan 对象模型、F6.5 同一 Issue 模型） | FR9.3.1–FR9.3.3、FR9.6.1、FR9.6.2、AC9.6.1；F7 plan A12；F10 plan §2.1；F6 plan A7 |
| A10 | **编号 = 项目内按年计数器 + 事务内分配 + 作废不回收**：项目级 report_no 游标行 `SELECT ... FOR UPDATE` 串行化（F8 plan A6 同手法）；`RB-{项目代号}-{年份}-{seq:03d}`、超 999 自然进位、草稿删除不回收（C-Q3）；`external_report_no` 可空承载企业受控编号，非空时列表/详情/导出/联动引用优先展示（C-Q3）；编号终身不变保证导出记录与 FMEA/Issue 引用追溯链稳定（C-Q3） | FR9.5.1、FR9.6.1、FR9.6.2；C-Q3 及 Assumptions |
| A11 | **F8 criteria 结构化以新增可空列落地、不动 F8 既有契约**：F8 plan 的 `test_cases.criteria` 为 TEXT；C-Q1 要求结构化——implement 阶段在 test_cases 新增可空列 `criteria_structured JSONB`（F8 生成/采用流程写入，向后兼容 FR10.1.4，跨 feature 协调项登记，不修改 F8 plan/spec 文件）；F9 导入时点从用例集快照读取并随行快照，运行期不依赖 F8 表在线状态 | C-Q1；FR10.1.4；FR9.1.3 |
| A12 | **前端页面21按 UI_GUIDE 落地、单报告页内闭环**：数据状态卡（样本/Pass/Fail + 警告列表可展开）+ [AI] 异常分析卡（建议/超限幅度/确认按钮）+ 三动作按钮 [生成正式报告][生成FMEA风险][创建问题单]；正文编辑器按八节分块；定版/导出/联动按钮按权限显隐、后端 require_perm 强制（F10 plan A7）；[AI] 内容角标 + DRAFT 水印预览 | FR9.1–FR9.6 各条；UI_GUIDE 页面21；F10 plan A7 |
| A13 | **F4 技能复用同一入口**：F4 report_gen 技能经 `POST /test-reports/drafts` 与 `POST /{id}/body/generate` 同一入口发起（spec 头表被依赖 F4；F6/F7/F8 plan 先例），任务卡展示报告状态与三联动动作（F4.4） | spec 头表；F4.2/F4.4 |

---

## 2. 数据模型

全部主键 UUIDv7、时间 UTC（specs/README 约定）。`test_reports` 继承 F10 BaseEntity 公共列（FR10.1.3：id/project_id/created_by/created_at/updated_at/state/audit_ref + revision），注册进 F10.1 统一对象模型（FR10.1.1 TestReport）；`issues` 多态来源 `report_anomaly` 已在 F10 plan 对象模型预留（FR10.1.2）。

### 2.1 test_report 与 test_data_import / test_result_row（spec §3）

```text
test_reports(
  # BaseEntity 公共列：id, project_id, created_by, created_at, updated_at,
  #                    state(DRAFT→IN_REVIEW→APPROVED, F10.2 映射，A7), audit_ref,
  #                    revision INT DEFAULT 1（FR10.2.4 修订链）
  report_no VARCHAR UNIQUE,          # RB-{项目代号}-{年份}-{seq:03d}（C-Q3，A10）
  external_report_no VARCHAR NULL,   # 企业受控编号（人工录入，非空时优先展示，C-Q3）
  title VARCHAR,                     # 报告名称（如"高温循环测试报告"，UI 页面21）
  case_set_ref JSONB,                # 用例集引用快照 {case_ids[], case_count, snapshot_at,
                                     #  fmea_refs[]?}（FR9.4.1 测试范围节、FR9.5.2 附件清单）
  stats JSONB,                       # {caliber_version, case_total, sample_total, pass,
                                     #  fail, pending, pass_rate, auto_judge_coverage,
                                     #  by_item[{item, case_total, sample_total, pass,
                                     #  fail, pass_rate}]}（FR9.2.1/FR9.2.3，C-Q1 覆盖率）
  charts JSONB,                      # [{type: pass_rate_bar|fail_distribution, title,
                                     #  enabled, file_key}]（FR9.2.2，PNG 在 MinIO，A3）
  body JSONB,                        # 按章节八节 [{section: summary|scope|stats|charts|
                                     #  detail|anomalies|conclusion|attachments, content,
                                     #  ai_generated?, fallback?}]（FR9.4.1）
  conclusion_confirmed BOOLEAN DEFAULT false,   # FR9.4.2 定版闸门（A7）
  confirmed_by→users NULL, confirmed_at,
  conclusion_fallback BOOLEAN DEFAULT false,    # 结论降级标记（A5，观测）
  report_config JSONB,               # {charts_enabled[], watermark=auto, ...}（FR9.2.2 配置）
  template_id UUID NULL,             # 渲染模板（NULL=内置默认，C-Q2）
  approved_by→users NULL, approved_at          # spec §3
)
-- 索引：(project_id, state), (report_no) UNIQUE, (external_report_no)

test_data_imports(                   # spec §3：id, report_draft_id, file_key, row_count, warnings
  id UUIDv7 PK,
  report_id→test_reports,            # report_draft_id（草稿即报告对象，状态机同一对象）
  file_key VARCHAR,                  # 原始数据文件 MinIO key（FR9.5.2 附件清单）
  file_name VARCHAR, format VARCHAR, # xlsx | csv（FR9.1.1）
  row_count INT,                     # 总行数
  warnings JSONB,                    # [{row_no, case_id?, code: unknown_case|verdict_conflict|
                                     #  unit_mismatch|judge_failed|column_skipped, message}]
                                     # （FR9.1.2 警告列表 + C-Q1 抽取规则版本化载体）
  criteria_engine_version VARCHAR,   # 判定/抽取引擎版本（C-Q1 Assumptions，不回溯重判）
  imported_by→users, imported_at
)
-- 索引：(report_id)

test_result_rows(                    # spec §3：import_id, case_id, sample_no, measured_value,
                                     # unit, verdict(pass/fail/pending), delta_pct?, note?
  id UUIDv7 PK,
  import_id→test_data_imports, report_id→test_reports, row_no INT,
  case_id→test_cases NULL,           # 逻辑引用（未知行不入库仅警告，FR9.1.2，A2）
  case_no VARCHAR,                   # 冗余快照（用例后续变更不影响已导入报告，A1 快照原则）
  test_item VARCHAR,                 # 冗余分组键（挂接主需求 test_item，假设④）
  sample_no VARCHAR, measured_value NUMERIC, unit VARCHAR,
  verdict VARCHAR,                   # pass | fail | pending（FR9.1.3）
  verdict_source VARCHAR,            # manual | rule | extracted | pending
                                     # （人工直填/结构化规则/正则抽取/待人工，C-Q1）
  criteria_snapshot JSONB,           # 判定时点判定标准快照（含 criteria_structured 或抽取
                                     #  结果 + 引擎版本，可复现，AC9.3.1，A1）
  delta_pct NUMERIC NULL,            # 超限幅度（fail 行，FR9.3.1/C-Q1 公式，A3）
  note TEXT NULL                     # 备注（FR9.1.1 列模板"备注"）
)
-- 索引：(report_id, verdict), (report_id, case_no), (import_id, row_no)
```

### 2.2 report_anomaly 与导出/模板（spec §3）

```text
report_anomalies(                    # spec §3：report_id, result_row_ref, over_limit_pct,
                                     # ai_suggestion?, suggestion_status(draft/confirmed),
                                     # owner_note?
  id UUIDv7 PK,
  report_id→test_reports,
  result_row_id→test_result_rows,    # result_row_ref（UNIQUE，一行至多一条异常，A9）
  location JSONB,                    # {case_no, sample_no, row_no}（FR9.3.1 定位）
  measured_vs_criteria JSONB,        # {measured_value, unit, limit/min/max, op}（FR9.3.1）
  over_limit_pct NUMERIC,            # = delta_pct（FR9.3.1 超限幅度，AC9.3.1）
  impact VARCHAR,                    # 影响判定（FR9.3.1：如"容量不合格，整批次拒绝接收"，
                                     #  按规则引擎生成的确定性文案 + 人工可改）
  ai_suggestion JSONB NULL,          # {items:[{text, priority?, kb_refs?}], model,
                                     #  model_version, prompt_id, prompt_version,
                                     #  kb_version, citations[], generated_at}
                                     # （FR9.3.2，[AI] 标注；审计字段内嵌 FR10.3.1，A4/A9）
  suggestion_status VARCHAR DEFAULT 'none',
                                     # none | draft | confirmed（FR9.3.2/F10.2，确认才入
                                     #  正式报告正文，A4）
  suggestion_confirmed_by→users NULL, suggestion_confirmed_at,
  owner→users NULL, owner_note TEXT NULL,   # 责任归属 + 备注（FR9.3.3）
  fmea_row_id UUID NULL,             # → fmea_rows（to-fmea 反向回链，AC9.6.1，A9）
  issue_id UUID NULL                 # → issues（to-issues 反向回链，FR9.6.2，A9）
)
-- 索引：(report_id), (report_id, suggestion_status), (result_row_id) UNIQUE,
--      (fmea_row_id), (issue_id)

report_templates(                    # C-Q2：实施期模板替换（版本化留存）
  id UUIDv7 PK, name VARCHAR, file_key VARCHAR, version INT,
  is_default BOOLEAN DEFAULT false,  # 内置默认模板种子行
  placeholder_contract_version VARCHAR,   # 契约冻结版本号（C-Q2）
  uploaded_by→users NULL, uploaded_at, state VARCHAR    # DRAFT|APPROVED（复用 F10 workflow）
)

report_exports(                      # FR9.5.1 导出记录：谁、何时、哪个版本
  id UUIDv7 PK, report_id→test_reports,
  format VARCHAR,                    # pdf | word
  file_key VARCHAR,                  # 导出物 MinIO key（历史不重渲染，C-Q2 Assumptions）
  template_id UUID NULL, template_version INT,     # 渲染时点模板版本（可复现）
  report_revision INT,               # 渲染时点报告 revision
  watermarked BOOLEAN,               # DRAFT 水印标志（FR9.4.3）
  exported_by→users, exported_at
)
-- 索引：(report_id, exported_at)
```

### 2.3 共用与平台侧（不新建表）

```text
issues                               # F10.1 platform 对象：origin_type='report_anomaly'，
                                     # origin_id=anomaly_id（F10 plan §2.1 多态来源预留，
                                     # FR10.1.2）；分类列挂 F2 质量问题分类 id（FR9.6.2，与 F6.5 同一模型）
fmea_rows                            # F7 表（F9 不新建）：to-fmea 经 F7 行服务写入，
                                     # source='report_anomaly'、source_ref={report_id,
                                     # anomaly_id}（F7 plan A12 预留契约）
test_cases.criteria_structured JSONB # F8 表新增可空列（A11，跨 feature 协调项，FR10.1.4）
object_source_link                   # F3/F7/F8 共用单表：本次不扩展 src_type（异常项依据
                                     #  已内嵌 criteria_snapshot/kb citations；kb 引用走
                                     #  ai_suggestion.citations，FR9.3.2）
tasks                                # F10.1 Task：type='report_body_gen'|'report_suggestion'|
                                     # 'report_export'，result_ref=report_id（specs/README 异步）
audit / kpi_events / state_transitions  # F10.3/F10.6/F10.2 平台表直接复用
```

---

## 3. API 设计（遵循 specs/README：REST /api/v1、统一错误体、异步任务 SSE）

### 3.1 端点清单

```text
# 导入与草稿（F9.1）
GET  /api/v1/test-reports/import-template
                                     # 数据文件模板下载（Case ID/样本编号/实测值/实测单位/
                                     #  判定/备注，FR9.1.1）
GET  /api/v1/test-reports?project_id=&state=&q=&page=&page_size=
                                     # 列表（external_report_no 非空优先展示，C-Q3）
POST /api/v1/test-reports/drafts     # multipart: file + project_id + title
                                     # → 201 {report_id, report_no, stats, warnings[],
                                     #        pending_count}
                                     # 同步：编号分配+导入+判定+统计+异常（A2）；
                                     # 可"忽略未知行"：body ignore_unknown_rows=true，
                                     # 缺省 false 时存在 unknown_case 警告 → 422 返回警告列表
                                     # 供确认（FR9.1.2/AC9.1.1）
GET  /api/v1/test-reports/{id}       # 报告内容：stats/charts/body/anomalies 摘要/附件清单/
                                     #  report_no/external_report_no（FR9.4、spec §4，C-Q3 Assumptions）
PATCH /api/v1/test-reports/{id}      # 编辑：title/report_config（图表启用 FR9.2.2）/
                                     #  external_report_no/body 各章节内容（人工编辑，FR9.4.2；
                                     #  APPROVED → OBJECT_LOCKED，A7）

# 明细与判定（F9.1.3）
GET  /api/v1/test-reports/{id}/rows?verdict=&case_no=&page=&page_size=
                                     # Pass-Fail 明细分页（FR9.4.1 明细节同源）
PATCH /api/v1/test-reports/{id}/rows/{row_id}
                                     # body: {verdict: pass|fail, note?} 待人工判定闭环
                                     # （FR9.1.3）→ 同步重算 stats/anomalies 并返回
POST /api/v1/test-reports/{id}/stats/refresh
                                     # 显式重算（行级 PATCH 已内含，供批量判定后调用，FR9.2.1）

# 异常项（F9.3）
GET  /api/v1/test-reports/{id}/anomalies
PATCH /api/v1/test-reports/{id}/anomalies/{aid}
                                     # {owner_note?, owner_id?, impact?} 备注与责任归属
                                     # （FR9.3.3）
POST /api/v1/test-reports/{id}/anomalies/{aid}/suggestion
                                     # 生成 AI 整改建议（异步 → task_id，FR9.3.2；RAG 召回
                                     #  历史质量问题 + LLMGateway，A4）
POST /api/v1/test-reports/{id}/anomalies/{aid}/suggestion/confirm
                                     # 人工确认建议（可携编辑后内容）→ confirmed +
                                     #  audit anomaly.confirmed（FR9.3.2/F10.2，A4）

# 正文与定版（F9.4，spec §4）
POST /api/v1/test-reports/{id}/body/generate
                                     # 异步生成正文草稿（八节装配 + AI 结论，FR9.4.1/9.4.2）
                                     # → task_id（SSE）
POST /api/v1/test-reports/{id}/conclusion/confirm
                                     # 结论人工确认（修改或明确确认，FR9.4.2）→
                                     #  conclusion_confirmed=true + 留痕
POST /api/v1/test-reports/{id}/transition
                                     # F10.2 通用端点：{action: submit_review|approve,
                                     #  comment}；approve 钩子校验 conclusion_confirmed
                                     #  （spec §5 → REPORT_CONCLUSION_NOT_CONFIRMED）+
                                     #  pending 清零（A8 → REPORT_PENDING_VERDICT_EXISTS）
GET  /api/v1/test-reports/{id}/transitions
                                     # 转换历史（F10 plan）

# 导出（F9.5，spec §4）
POST /api/v1/test-reports/{id}/export
                                     # body: {format: pdf|word} → 异步 task_id → file_key
                                     # （FR9.5.1；未 APPROVED 自动 DRAFT 水印，FR9.4.3/A6）
GET  /api/v1/test-reports/{id}/exports
                                     # 导出记录列表（谁/何时/哪个版本/水印标志，FR9.5.1）
GET  /api/v1/test-reports/{id}/attachments
                                     # 附件清单：原始数据文件 + 关联 FMEA/用例集引用
                                     # （FR9.5.2，从 case_set_ref/import/linkage 装配）

# 模板管理（C-Q2，实施期，管理员）
GET  /api/v1/report-templates        POST /api/v1/report-templates（上传 docxtpl，版本化 +
                                     #  audit report.template.updated）

# 后续联动（F9.6，spec §4）
POST /api/v1/test-reports/{id}/to-fmea
                                     # body: {anomaly_ids[], fmea_id}（目标仅 DRAFT/
                                     #  IN_REVIEW；APPROVED 需携 fmea_revision 开修订版）
                                     # → 写 fmea_rows（草稿态，F7 审核流）→ 201 {rows[]}
                                     # （FR9.6.1/AC9.6.1，A9）
POST /api/v1/test-reports/{id}/to-issues
                                     # body: {anomaly_ids[], classification_id, assignee_id?,
                                     #  due_date?} → 经 platform 创建 Issue（origin=
                                     #  report_anomaly，分类=知识库质量问题分类，FR9.6.2）
GET  /api/v1/test-reports/{id}/anomalies/{aid}/issue     # 正向跳转（F6 plan A7 先例）

# 任务（specs/README 异步约定）
GET  /api/v1/tasks/{id}/events       # SSE：QUEUED/RUNNING(stage=suggest|generate|export,
                                     #  progress)/SUCCESS/FAILED/CANCELED
POST /api/v1/tasks/{id}/cancel       # F4.5
```

### 3.2 语义与错误

- 统一错误体 `{"code","message","detail"}`。本 feature 新增错误码：
  - `REPORT_IMPORT_TEMPLATE_MISMATCH`（FR9.1.1 列模板不符）
  - `REPORT_IMPORT_TOO_LARGE`（A2 行数超限）
  - `REPORT_UNKNOWN_CASES_CONFIRM_REQUIRED`（FR9.1.2：存在未知 Case ID 且未携带 ignore_unknown_rows，detail=警告列表）
  - `REPORT_CONCLUSION_NOT_CONFIRMED`（spec §5：结论章节未确认时定版被拒，A4/A7）
  - `REPORT_PENDING_VERDICT_EXISTS`（A8：存在待人工判定行，定版被拒）
  - `REPORT_NO_ANOMALIES_SELECTED`（FR9.6：to-fmea/to-issues 未选或所选异常无 Fail 依据）
  - `REPORT_FMEA_NOT_EDITABLE`（FR9.6.1：目标 FMEA APPROVED 且未指定修订版本，A9/F7 修订机制）
  - `REPORT_CLASSIFICATION_REQUIRED`（FR9.6.2：质量问题分类必填）
  - `REPORT_EXPORT_FAILED`（A6：渲染/转换失败，task FAILED 附原因）
  - `INVALID_TRANSITION`/`FORBIDDEN`/`OBJECT_LOCKED` 复用 F10 通用码（FR10.2/FR10.5）
- **异步边界**：正文生成（FR9.4，LLM）、AI 建议生成（FR9.3.2，LLM+RAG）、导出（FR9.5，渲染+转换）走 Celery `report` 队列 + SSE（specs/README 异步约定）；导入/判定/统计/行判定/确认/备注/联动/transition 均为同步操作（A2/A3：确定性、有界、需即时反馈警告列表）。F4 report_gen 技能复用同一入口（A13）。
- **幂等与并发**：编号分配经项目游标行锁串行化（A10）；suggestion/confirm 幂等（confirmed 后再 confirm 返回当前态）；to-fmea/to-issues 幂等（anomaly 已有 fmea_row_id/issue_id → 跳过并计入响应逐条结果，部分成功语义）；body/generate 重复触发 → 取消在途任务后重排（F4.5 cancel 语义）。
- **权限**（F10.5 矩阵）：查看/编辑/行判定/异常备注/发起生成与导出 = 工程师+（项目成员可见性继承 FR10.5.3）；定版（approve）= 工程师+（F10.2.1 报告行：定版权限工程师+，结论节须已确认）；模板上传/替换 = 系统管理员/AI管理员；删除类操作 Phase 1 不开放（报告全量留存供审计追溯，F6 plan A8 同取向）。
- **统计口径**（FR9.2.3）：caliber_version='v1' 固化于 stats 并渲染进「数据统计」节；与 F10.6 KPI 报表注释同源；口径变更 = caliber_version 升版 + 新报告生效、历史报告不重算（对齐 C-Q1 引擎不回溯原则）。

---

## 4. AI/LLM 使用点

| 项 | 设计 | 溯源 |
| ---- | ---- | ---- |
| LLM 使用范围 | **两处**：① 异常项 AI 整改建议（FR9.3.2）；② 报告结论草稿（FR9.4.2）。自动判定（FR9.1.3，C-Q1 明确非 AI）、统计/图表（FR9.2）、超限幅度（FR9.3.1）、正文其余七节装配（FR9.4.1）、导出渲染（FR9.5）、联动写入（FR9.6）全部确定性代码 | A1/A3/A4；C-Q1 |
| 模型策略 | 经 F10 `LLMGateway`：生成模型走配置（私有化可替换、数据不出企业域，PRD §53）；审计记录实测 model/model_version。历史质量问题召回复用 F3 检索服务（平台统一 embedding + kb_version 快照），无新增模型需求 | F10 plan §4 挂点 2；FR10.3.1；FR9.3.2 |
| Prompt 策略 | Prompt 注册表管理，两个 prompt_id：`f9.anomaly_suggestion`（输入：异常四要素 {case_no, sample_no, 实测值 vs 判定标准, delta_pct} + RAG 召回的历史质量问题片段（含出处）+ 输出要求：2–4 条可执行建议、逐条标注依据引用或显式"经验建议"、禁止编造检测数据）；`f9.report_conclusion`（输入：仅 stats JSONB 序列化 + confirmed 异常摘要 + 待人工判定计数 + 输出要求：结论段 + 关键发现列表、**只能使用输入中出现的数值**、不得引入数据之外的信息（FR9.4.2 原文约束）、pending>0 时须显式声明）。禁止裸字符串 prompt（FR10.3.4） | FR9.3.2、FR9.4.2；FR10.3.4 |
| 结构化输出 schema | 强制 JSON Schema（Pydantic 校验）。建议：`{"suggestions":[{"text","priority":"high|medium|low","basis":"kb|experience","kb_doc_ids":[]?}]}`；结论：`{"conclusion_md","key_findings":[{"finding","stat_ref"}]}`——**schema 不含 delta_pct、统计值等可计算字段的新数值**（stat_ref 只能引用输入提供的 stats 键路径，构造性约束 grounding）。schema 校验失败/超出约束 → 带错误反馈重试 1 次（A5） | FR9.3.2、FR9.4.2；A5 |
| Grounding/防幻觉 | ① 结论数值守卫：代码抽取结论数值与 stats/anomalies 交叉核对，失败重试 1 次后降级模板化结论 + `conclusion_fallback` 标记（A5，FR9.4.2"禁止引入数据之外的信息"的确定性兜底）；② stat_ref 键路径白名单校验（引用不存在的统计键 → 剔除该 finding）；③ 建议的 kb_doc_ids 校验 ∈ 本次 RAG 召回集合，非法引用降为 basis=experience；④ 两处输出均 DRAFT + [AI] 标识 + 人工确认闸门（A4，specs/README AI 草稿语义）；⑤ 审计记录 kb_version + citations 可回查（FR10.3.1）；⑥ 导出物 [AI] 脚注标识（C-Q2 Assumptions） | FR9.3.2、FR9.4.2；FR10.3.1；C-Q1/C-Q2 Assumptions |
| 审计接入 | `report.imported`（含引擎版本与警告统计）、`anomaly.suggestion.generated`（模型/prompt版本/kb_version/citations，FR10.3.1——spec §5 未列但 AI 操作必录，按 `<domain>.<verb>` 补名）、`anomaly.confirmed`、`anomaly.verdict.reviewed`（C-Q1 Assumptions 复核）、`body.generated`（prompt/model/kb_version）、`report.approved`、`report.exported`（含模板版本/水印标志）、`report.template.updated`（C-Q2）（spec §5 + C-Q1/Q2 补充，命名对齐 FR10.3.3 统一清单） | spec §5；FR10.3.1、FR10.3.3；C-Q1/Q2 |
| KPI 埋点 | `report.start`（草稿创建）、`report.approve`、`report.export`（FR10.6.2 清单内）；**`report.start → report.export` 耗时 = 验收 KPI「测试报告制作时间 ↓≥70%」分子**（spec §5；基线分母为 F10.6.3 人工基线表）；「异常项分析耗时」子段 = anomaly suggestion 生成时点 → 该报告全部异常 confirmed 时点（spec §5 子段打点）；导出记录表为 KPI 报表的版本维度数据源 | spec §5；FR10.6.1–FR10.6.4 |
| 评测方式 | ① **AC9.3.1 金标场景（M4 硬门槛）**：`evals/report_anomaly/` 预置含超限样本数据集 + 预置答案，离线断言 delta_pct 计算与预置答案一致（阈值型/区间型/边界用例/单位不匹配用例全覆盖，A3 纯函数直验）；② **AC9.1.1 集成金标**：含 3 条未知 Case ID 的文件 → 警告列表准确 + 其余行正常入库；③ 结论 grounding 评测：金标集（≥2 组统计+异常输入）断言数值守卫零漏报（结论数值 ⊆ 输入数据）+ 人工走查结论可用性（结论是否覆盖 Pass/Fail 概况、异常、pending 声明）；④ 建议质量人工走查：可执行性、依据正确性（kb 引用抽查）、采纳率观测；⑤ 自动指标（观测）：conclusion_fallback 率、建议确认率、pending 率、自动判定覆盖率分布；⑥ prompt/模型版本变更触发①③回归 | AC9.3.1、AC9.1.1；FR9.4.2；C-Q1；spec §5 KPI |

---

## 5. 测试策略

| 层级 | 内容 | 溯源 |
| ---- | ---- | ---- |
| 单元（判定规则引擎） | 三型 criteria 判定矩阵：threshold 四算子、range 开闭边界（默认闭区间，C-Q1 Assumptions）、boolean；多条件 AND 语义；优先级（manual > rule > extracted > pending，C-Q1）；单位不匹配 → pending + 警告（不换算）；正则兜底抽取（数值限值 + 单位对齐成功/失败样本）；抽取失败 → pending；引擎版本号写入快照 | FR9.1.2、FR9.1.3、AC9.3.1；C-Q1 及 Assumptions；A1 |
| 单元（超限与统计） | delta_pct 公式：阈值型 \|实测−limit\|/limit×100%、区间型最近边界、与预置答案一致（AC9.3.1 直接断言）；统计口径：通过率分母排除 pending、分组汇总、自动判定覆盖率、caliber_version 固化；列模板校验、行数上限 | FR9.2.1–FR9.2.3、AC9.3.1；C-Q1；A2/A3；假设③④ |
| 单元（编号与正文装配） | 编号格式/进位/项目游标并发互斥/作废不回收（C-Q3）；八节装配完整性（八节齐全、图表启用配置生效 FR9.2.2、统计口径说明入 stats 节）；占位符契约 schema 校验（C-Q2） | FR9.4.1；C-Q2/C-Q3；A6/A10 |
| 单元（grounding 守卫） | 结论含数据外数值 → 重试反馈构造 → 降级模板化结论 + fallback 标记；stat_ref 非法键剔除；kb_doc_ids ∉ 召回集降级 experience | FR9.4.2；A5 |
| 集成（导入与判定闭环） | fixtures：项目 ADOPTED 用例集（含三型 criteria 与仅自由文本用例）+ xlsx/csv 样例 → 端到端：警告列表准确（AC9.1.1：3 条未知 Case ID）+ 其余行入库；pending → PATCH 人工判定 → stats 重算；直填与规则冲突 → 警告 + reviewed 审计；模板不符 → REPORT_IMPORT_TEMPLATE_MISMATCH；未知行未确认 → REPORT_UNKNOWN_CASES_CONFIRM_REQUIRED；引擎升级不回溯历史报告（C-Q1 Assumptions） | FR9.1.1–FR9.1.3、AC9.1.1；C-Q1；A1/A2/A8 |
| 集成（异常与 AI 闸门） | Fail 行自动派生异常（四要素 + criteria_snapshot）；suggestion 异步生成 → SSE 事件 → draft 态 + [AI]；未确认建议不进正文正式内容（A4）；confirm → confirmed + anomaly.confirmed 审计（内嵌审计字段完备性 FR10.3.1）；owner_note/owner 补充（FR9.3.3）；kb_version/citations 落库可回查 | FR9.3.1–FR9.3.3；FR10.3.1；A4/A9 |
| 集成（定版与导出） | 结论未确认 → approve 409 REPORT_CONCLUSION_NOT_CONFIRMED（spec §5）；pending 未清零 → REPORT_PENDING_VERDICT_EXISTS（A8）；确认后 IN_REVIEW→APPROVED 成功（comment 必填）→ 编辑返回 OBJECT_LOCKED、revision+1（FR10.2.4）；APPROVED 前导出带 DRAFT 水印 + [AI] 脚注、APPROVED 后无水印（FR9.4.3，金标断言 PDF/Word 各一）；导出记录谁/何时/模板版本/revision（FR9.5.1）；模板替换后历史导出不重渲染（C-Q2 Assumptions）；附件清单含原始文件 + FMEA/用例集引用（FR9.5.2） | FR9.4.2–FR9.4.3、FR9.5.1、FR9.5.2；spec §5；FR10.2.4；C-Q2 |
| 集成（联动） | to-fmea：写 fmea_rows（source='report_anomaly'/source_ref/row_status）→ FMEA 工作台按来源可筛可见（AC9.6.1）；目标 FMEA APPROVED 且无修订 → REPORT_FMEA_NOT_EDITABLE；幂等（重复提交跳过已关联项）；to-issues：Issue 创建（origin_type='report_anomaly'）+ 分类必填 + 双向跳转（F6 plan A7 先例）；联动后 anomaly 回链字段更新 | FR9.6.1、FR9.6.2、AC9.6.1；F7 plan A12；F10 plan §2.1 |
| 集成（审计与 KPI） | report.imported/body.generated/anomaly.confirmed/report.approved/report.exported 全事件断言（FR10.3.1 字段完备性门槛）；report.start→report.export 耗时打点与 KPI 报表出数；异常项分析耗时子段可聚合 | spec §5；FR10.3.1、FR10.6 |
| **禁绕过测试**（AC1.6.1 复用） | import-linter 禁止 report 模块自行解析 xlsx/csv（必须经 F1 通道）、禁止直连模型 SDK（必须经 LLMGateway）、禁止绕过 F3 检索服务直查 chunks、禁止 worker 层 import transition service（FR10.2.2 AI 直写 APPROVED 禁令） | specs/README 数据契约；FR10.2.2；F10 plan §5 |
| 权限矩阵 | 参数化：5 角色 × {导入/编辑/行判定/建议确认/定版/导出/联动/模板管理}；项目可见性断言；定版权限（工程师+）与 FMEA 定版（研发主管）差异显式断言；F4 report_gen 复用同一入口断言（A13） | FR10.5 矩阵；F10.2.1 表 |
| API 契约 | 统一错误体/分页信封/SSE payload schema；新错误码逐条断言；to-fmea/to-issues 部分成功响应结构；导入同步响应结构（stats+warnings） | specs/README、§3.2 |
| 评测 | `evals/report_anomaly/` 金标（AC9.3.1 硬门槛）+ AC9.1.1 集成金标 + 结论 grounding 评测 + 建议质量走查 + prompt/模型变更回归 + 版本化归档 | §4 评测 |
| 前端 | 组件测试：数据状态卡与警告列表（页面21）；导入向导（模板下载/忽略未知行确认）；待人工判定行编辑；异常项卡片（[AI] 角标/确认/备注/责任归属）；正文八节编辑器与结论确认流；图表展示与启用配置；定版对话框（comment）与水印预览；导出记录列表；联动对话框（选 FMEA/修订提示、选分类/责任人）与回链跳转；模板管理页（管理员） | FR9.1–FR9.6 各条；UI_GUIDE 页面21；C-Q2 |

覆盖率目标遵循全局规则（新增模块 ≥80%）。

---

## 6. 风险与非目标

### 风险

| 风险 | 影响 | 缓解 |
| ---- | ---- | ---- |
| AI 结论幻觉（引入数据外信息） | FR9.4.2 硬约束被破坏、正式报告失真 | prompt 强约束 + 数值守卫 + 重试 + 模板化降级（A5）+ 结论必须人工确认才可定版（A4/A7）；fallback 率入观测指标 |
| 结构化 criteria 覆盖率低（历史用例多为自由文本） | pending 率高、人工判定负担大 | 正则兜底抽取（C-Q1）覆盖数值型；pending 率观测反哺 F8 侧生成质量（FR8.3.4 量化阈值要求）；人工判定闭环 + 定版闸门保证不漏判（A8） |
| 单位不一致 / 单位换算错误判定 | 错误 Pass/Fail，工程风险 | C-Q1 Assumptions 保守策略：不换算、置 pending + 警告交人工；单位不匹配率入警告统计 |
| 判定标准抽取（正则）误抽取 | 错误自动判定 | 抽取结果随 criteria_snapshot 展示可核对；verdict_source='extracted' 行在明细可筛；抽取失败宁可 pending（C-Q1"判不了显式交人工"） |
| F8 侧 criteria_structured 列落地时序 | F9 依赖落空 | A11：新增可空列向后兼容（FR10.1.4），F9 消费侧对 NULL 有完整兜底路径（正则→pending）；跨 feature 协调项在 implement 阶段先行确认 |
| 企业 docxtpl 模板版式复杂（页眉页脚/受控文件标识） | 导出还原度不足 | C-Q2：Phase 1 内置默认模板保 KPI 验收；占位符契约冻结使企业模板接入为纯配置；深度适配列实施期服务项不阻塞 M4 |
| PDF 转换还原度（docx→pdf 字体/分页漂移） | 双格式不一致 | 转换器字体随镜像打包（与图表中文字体同源）；导出集成测试对双格式各做内容断言；差异记录为已知限制 |
| 目标 FMEA 状态冲突（APPROVED 不可写） | 联动失败体验差 | 前端预检 FMEA 状态并提示开修订版本；后端 REPORT_FMEA_NOT_EDITABLE 兜底（A9/F7 修订机制） |
| 大数据量导入拖慢同步接口 | 接口超时 | 行数上限 10,000（A2）+ 模板引导分批；超限明确报错而非降速 |
| KPI 基线缺失（人工制作报告耗时未测） | ↓70% 无法验收 | F10.6.3 人工基线联合测量为 M1 交付项；report.start/export 全链路打点（§4 KPI） |
| 统计口径理解分歧（pending 是否计入通过率） | 验收争议 | 口径文本随报告「数据统计」节输出（FR9.2.3）+ caliber_version 固化；口径变更走版本化不回溯 |

### 非目标（Phase 1）

- 试验设备数据直采、SPC/CPK 等深度质量统计（spec §6）
- 报告多语言、电子签章（spec §6：如客户要求属交付配置项）
- 与 TCM/试验管理系统对接（spec §6；Phase 2，与 F8 非目标同批）
- 企业质量体系编号自动对接（C-Q3：Phase 2，`external_report_no` 人工录入过渡）
- AI 直写 APPROVED / 免确认定版通路（FR10.2.2 架构约束；定版仅人工 transition）
- 已 APPROVED 报告的判定结果重判/回溯重算（C-Q1 Assumptions；修改走 revision 修订链）
- 报告协同实时编辑（单人编辑、后写为准，与 F7/F8 假设一致）
- FMEA→Issue 结构化双向链接的进一步治理（沿用 F7 plan 假设⑥边界，F9 只建 anomaly→issue 正向回链）
- 报告模板在线可视化编辑器（C-Q2：模板为文件级替换，在线编辑器 Phase 2 评估）

---

## 7. 决策与假设记录（承接 clarifications）

- C-Q1：判定标准在 `test_case` 结构化落库（`criteria_structured` JSONB，F8 产出侧写入、F9 只消费），三型 threshold/range/boolean、多条 AND；判定优先级 人工直填 > 结构化规则 > pending；自由文本正则兜底（版本化，非 LM）；delta_pct 公式按类型分支；自动判定覆盖率入统计口径。→ A1/A3、§1.2①、§2.1、§4、§5、§6
- C-Q2：Phase 1 内置默认 docxtpl 模板（八节），占位符契约冻结；模板文件实施期可替换（版本化 + `report.template.updated` 审计）；图表 PNG 占位注入；模板版本入导出记录、历史导出不重渲染。→ A6、§1.2⑤⑥、§2.2、§3.1、§5
- C-Q3：编号 `RB-{项目代号}-{年份}-{seq:03d}` 草稿创建事务内分配、终身不变、作废不回收；`external_report_no` 可空、非空优先展示；企业编号自动对接 Phase 2。→ A10、§1.2①、§2.1、§3.1
- 新增决策（无对应 Q，依 FR 推定，均已在正文标注）：
  - **假设①** 导入为同步接口（建草稿+导入+判定+统计一次完成，行数 ≤10,000）：警告列表需即时交互确认（FR9.1.2"可忽略未知行继续"），且无 LLM 环节、耗时确定性可控；与 F8 执行状态导入（A11 先例）同取同步，与 F9 正文/导出（LLM/渲染）走异步区分。
  - **假设②** `test_data_import.report_draft_id` 落为 `report_id` 外键：草稿与报告是同一对象的状态（F10.2 状态机挂在 test_report 上），导入是报告创建动作的一部分，不建独立草稿实体。
  - **假设③** 通过率 = Pass/(Pass+Fail)，pending 不入分母、单列展示（待判定样本既非合格也非不合格，计入分母会低估通过率）；口径文本随报告输出并接受质量部实施期核对（FR9.2.3 本意即消除歧义）。
  - **假设④** "按测试项目分组"的分组键 = 用例挂接主需求（F8 `test_case_requirements` 首条）的 `test_item`；未挂接需求的用例样本归入"未分组"组并在统计中显式展示（复用 F8 挂接数据，不重建分组模型）。
  - **假设⑤** 导出为异步任务（Celery `report` 队列）：PDF 转换与 MinIO 上传耗时不确定，对齐 F7 `fmea_export` 先例；导出记录在任务 SUCCESS 时点写入。
  - **假设⑥** 定版追加 pending 清零闸门（A8）：spec §5 仅明确结论确认闸门，但 PRD §43"测试结论必须人工确认"覆盖全部判定结果，带 pending 行定版即存在未经确认的结论成分，故阻塞并给出明确错误码。
  - **假设⑦** 图表集合 Phase 1 固定两类（各测试项目通过率柱状图、失败分布图，FR9.2.2 明示），图表"配置启用"指对这两类的启用/停用；新增图表类型属后续增强，charts JSONB 结构已预留 type 枚举扩展位。
  - **假设⑧** 影响判定（FR9.3.1）为规则引擎生成的确定性文案（按超限幅度分档 + 是否致命项），允许人工修改；不引入 LLM 判定影响等级（保持异常四要素全可复现，AC9.3.1 口径）。
