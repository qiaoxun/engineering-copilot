# F8 测试需求与用例生成 — 技术方案（Plan）

| | |
| ---- | ---- |
| Feature | F8-test-case-generation |
| 输入 | specs/F8-test-case-generation.md、specs/F8-test-case-generation.clarifications.md（冲突时以其为准）、PHASE1_SPEC.md、PHASE1_FEATURES.md、specs/README.md、UI_GUIDE 页面19/20 |
| 关联 | specs/F10-platform-governance.plan.md（对象模型 TestCase/状态机映射 DRAFT→ADOPTED/IGNORED/审计/RBAC/KPI/LLMGateway/Prompt注册表）、specs/F3-rag-retrieval.plan.md（object_source_link 共用表 A8、/links 端点、原文定位）、specs/F1-document-parsing.plan.md（统一解析模型/Fields 参数/OCR 置信度）、specs/F2-knowledge-base.plan.md（项目关联文档/分类标签/kb_version）、specs/F4-ai-chat.md（testcase_gen 技能入口、F4.5 异步任务）、specs/F9-test-report.md（Case ID 导入校验 FR9.1.2、external_case_no 展示约定）、specs/F7-fmea-generation.plan.md（生成管线/自检重试/diff 留痕同构先例） |
| 阶段 | speckit-plan（仅设计，不写代码） |
| 里程碑 | M4（F8.1 → {F8.2 ∥ F8.3} → {F8.4 ∥ F8.5} → F8.6） |

> 本 plan 中所有设计决策均标注溯源（FR/AC/Q 编号）。clarifications（Q1–Q4 决策）全文有效，引用处标注「C-Qx」。

---

## 1. 架构与模块落点

### 1.1 总体架构

对齐既定技术栈：**后端 FastAPI 模块化单体 + Celery + PostgreSQL(pgvector) + MinIO；前端 React + TypeScript + Ant Design**。F8 落在独立顶层模块 `testgen/`，核心由五部分组成：① **输入资料选择**（四类资料候选项组装：项目关联文档按 F2 标签分三类 + 历史用例库筛选，FR8.1.1–FR8.1.3）；② **生成管线**（异步 Celery：F1 解析模型读取 → 需求生成 → 用例生成 → 代码级自检 → 复用判定（确定性）→ 号段分配 → 落库统计，FR8.2/FR8.3/FR8.4）；③ **逐条处置**（采用/编辑后采用/忽略、diff 留痕、批量处置、依据侧滑，FR8.5）；④ **用例库管理**（执行状态人工流转 + Excel 批量导入 + 历史归档，FR8.6）；⑤ **覆盖率统计**（确定性 SQL 统计，无 LLM，FR8.3.3 + spec §5 KPI 口径）。输入文档一律经 F1 统一解析模型（specs/README 数据契约，C-Q1），依据引用落共用表 `object_source_link`（F3 plan A8），**LLM 在本 feature 中只出现在两处：测试需求七要素生成、测试用例七字段生成**；复用判定、覆盖率、号段分配、执行状态全部为确定性代码。

```text
apps/backend/
├── app/
│   ├── core/                        # F10 平台地基（workflow/audit/rbac/kpi/prompts/objects）
│   ├── modules/
│   │   ├── testgen/                 # ← F8 本体
│   │   │   ├── api/                 # test-gen/runs、test-requirements、test-cases、
│   │   │   │                        # historical-cases、test-coverage 路由
│   │   │   ├── inputs/              # F8.1 四类资料候选：F2 项目关联文档按标签分组 + 历史用例筛选
│   │   │   ├── generate/            # F8.2/F8.3 生成管线（Celery testgen 队列）
│   │   │   │   ├── gather.py        # 所选文档 F1 解析模型读取 + 序列化组装（FR8.2.2，C-Q1）
│   │   │   │   ├── llm_requirements.py  # 七要素 LLM 结构化生成（FR8.2.1）
│   │   │   │   ├── llm_cases.py     # 七字段 LLM 结构化生成 + 需求挂接（FR8.3.1/8.3.3）
│   │   │   │   ├── validate.py      # 代码级自检：要素空值剔除/字段校验/挂接校验（FR8.2.1、FR8.3.3）
│   │   │   │   ├── reuse.py         # 复用判定：关键词预筛 + 向量余弦（FR8.4.1，C-Q2）
│   │   │   │   └── numbering.py     # Case ID 号段预占与分配（FR8.3.2，C-Q4）
│   │   │   ├── dispose/             # F8.5 逐条/批量处置、编辑 diff、依据消费（FR8.5）
│   │   │   ├── library/             # F8.6 执行状态流转/Excel导入/归档（FR8.6）
│   │   │   ├── coverage/            # 覆盖率统计（C-Q3 口径，确定性 SQL）
│   │   │   └── evidence/            # 依据引用消费（复用 GET /api/v1/links，F3 plan A8）
│   │   ├── documents/               # F1：进程内只读复用（解析模型/Fields/原文定位端点转发）
│   │   ├── rag/                     # F3：进程内复用检索服务（复用判定向量计算走统一 embedding）
│   │   └── platform/                # F10：workflow/audit/rbac/kpi/prompts/objects
│   ├── worker/                      # Celery app；testgen 队列（生成任务）
│   └── main.py
└── alembic/
apps/frontend/
└── src/
    ├── pages/test/                  # 页面19 测试管理首页（需求/用例总览 + 覆盖率卡 + 生成入口）
    ├── pages/test/generate/         # 页面20 AI测试用例生成（四类资料勾选 + 已选清单常显 +
    │                                # 进度 + 新增/复用统计卡 + 逐条处置列表）
    ├── pages/test/cases/            # 项目用例集（列表 + 执行状态 + 批量导入 + 归档）
    └── features/testgen/            # 处置卡片（[采用][编辑][查看依据]）、依据侧滑、
                                     # 统计卡、执行状态标签、Excel 导入向导组件
```

### 1.2 生成管线（核心流程）

```text
发起：
POST /test-gen/runs（body: {project_id, document_ids[], historical_case_ids[]?})
  → 校验：项目权限（testgen.create）、≥1 项输入（FR8.1.2）、文档属当前项目且解析可用
    （PARSE_CONFIRMED，specs/README 数据契约，C-Q1）
  → generation_run 记录（inputs 快照：doc_version/parse_version/OCR置信度元数据，C-Q1）
    + 号段预占（预估产出 × 1.2 缓冲，C-Q4）→ Celery testgen 队列 → task_id（SSE）

管线（SSE 推送 stage）：
gather     读取所选文档 F1 统一解析模型（sections/blocks/tables/fields），按序列化上限
           组装 LLM 输入；Fields 参数（值+单位）优先保留（FR8.3.4 量化阈值来源，C-Q1）
gen_req    LLMGateway → prompt f8.test_requirements → JSON Schema 七要素结构化输出
           （FR8.2.1），逐条附证据锚点 {document_id, block_id|field_key, quote}（FR8.2.2）
validate   代码级自检①：七要素任一为空 → 无效行，无效集作为错误反馈重试 1 次（FR8.2.1）；
           证据锚点校验：document_id ∈ run inputs 且锚点存在于解析模型，非法锚点剔除
           （不判行无效）→ 合法锚点写 object_source_link(src_type='test_requirement')
gen_case   LLMGateway → prompt f8.test_cases → JSON Schema 七字段结构化输出，每条携带
           requirement_seq 挂接（FR8.3.1/8.3.3）；判定标准指令要求优先引用规格书参数
           字段并携带量化阈值（FR8.3.4，C-Q1）
validate2  自检②：七字段完整性 + steps 为编号列表 + requirement_seq 必须命中本次需求集
           （无法挂接 → 保留用例、标 unmapped，FR8.3.3）；无效行重试 1 次后剔除计数
reuse      确定性复用判定（FR8.4.1，C-Q2）：候选 = 历史用例库 + 本项目已采用用例
           （C-Q2 Assumptions）→ 「测试项目+判定标准」关键词粗匹配预筛 → 平台统一
           embedding 余弦相似度 ≥ 0.90（testgen.reuse.threshold）→ 标"复用" +
           reuse_of + 相似度分数；[阈值−0.05, 阈值) → 标"疑似复用"，不计复用统计
numbering  从号段预占区间顺序分配 TC-{项目代号}-{序号3位零填充}（FR8.3.2，C-Q4）
persist    test_requirements / test_cases 落库（state=DRAFT、ai_generated=true）；run 汇总
           stats{new, reused, unmapped, invalid_dropped}；模型/prompt/kb_version/输入清单
           入 generation_run.meta（审计 testgen.run 数据源，FR10.3.1）
完成       audit testgen.run + KPI testgen.generate（耗时）→ SSE SUCCESS →
           F4 任务卡「查看生成结果」（F4.4）；前端跳页面20处置列表，全部 DRAFT + [AI]

人工闭环（处置，FR8.5）：
采用（dispose action=adopt）→ DRAFT→ADOPTED（F10.2 状态机映射，人工触发，C-Q3 Assumptions）
编辑后采用（PATCH 先改后 adopt）→ 逐字段写 case_diffs/testreq_diffs + audit *.edited
  （FR8.5.2 diff 双用途：审计 + 修改率统计）
查看依据（侧滑）→ GET /links?src_type=test_requirement|test_case&src_id= → 片段 + 跳原文
  （FR8.5.1；OCR 低置信度来源带 F1 标红提示，C-Q1 Assumptions）
批量采用/忽略（按当前筛选条件，FR8.5.3）→ 逐条 transition + 审计
复用项卡片固定提示「复用为系统建议，请核对测试条件与判定标准是否适用于本项目」（C-Q2）

用例库管理（FR8.6）：
执行状态人工更新 PATCH exec-status（未开始/进行中/通过/失败）→ 写 case_exec_history
  （操作人+时间，FR8.6.1/AC8.6.1）+ audit case.exec_status.changed（spec §5）
Excel 批量导入执行状态 → F1 解析（xlsx native 通道）→ Case ID 匹配 → 行级警告列表
  （未知 Case ID 可忽略继续，FR8.6.2；语义对齐 F9.1.2）
归档 POST /projects/{id}/cases/archive → 已采用用例复制入 historical_cases（含 embedding）
  → 供 F8.1.3 选择与 F8.4 复用判定（FR8.6.3）
覆盖率 GET /projects/{id}/test-coverage → 分子/分母/覆盖率 + 未覆盖需求明细下钻（C-Q3）
KPI：testgen.generate 耗时；testgen.start → 处置完成耗时（spec §5）；
  采纳率/修改率可统计（FR8.5.2 diff 数据源，PRD §50 AI 类 KPI）
```

### 1.3 关键架构决策

| # | 决策 | 溯源 |
| ---- | ---- | ---- |
| A1 | **LLM 仅两处、只产出文本内容**：需求七要素与用例七字段的结构化生成本体；复用判定（FR8.4.1 明确"语义相似度 ≥ 阈值"）、覆盖率统计（C-Q3）、Case ID 分配（FR8.3.2）、执行状态（FR8.6.1"人工更新"）、Excel 导入匹配全部为确定性代码。LLM 输出不直接产生任何"复用"标记或统计数据（同 F7 plan A1 分层手法） | FR8.2.1、FR8.3.1、FR8.4.1、FR8.6.1；C-Q2/C-Q3 |
| A2 | **输入只走 F1 统一解析模型且必须 PARSE_CONFIRMED**：三类文档（规格书/客户需求/企业测试标准）均为当前项目关联文档（FR8.1.1 天然限定），经 F1.6 入口读取（C-Q1：不建企业标准专用抽取器）；LLM 输入按 sections/fields 组装，Fields 参数表优先保留（FR8.3.4 量化阈值 + C-Q1"判定标准优先从 Fields/表格参数取值"）；OCR 低置信度块照常纳入但元数据记入 run.inputs（C-Q1 交付策略） | FR8.1.1、FR8.3.4；C-Q1；specs/README 数据契约；F7 plan A2 同构 |
| A3 | **两级生成 + 代码级自检 + 各一次带错误反馈重试**：先需求后用例（用例挂接需求是硬约束 FR8.3.3）；七要素/七字段任一为空即该条无效（FR8.2.1"生成侧自检"），无效集作错误反馈重试 1 次；仍无效剔除并计入 stats.invalid_dropped（不静默丢弃）；两级均空结果 → 任务 FAILED（TESTGEN_GENERATION_FAILED） | FR8.2.1、FR8.3.3；FR10.3.1；F7 plan A3 同构 |
| A4 | **依据引用 = LLM 输出锚点 + 代码校验后落 object_source_link**：与 F7 的检索挂引用不同，F8 输入即所选文档，故 schema 允许携带证据锚点 `{document_id, block_id|field_key, quote}`（指向本次提供的解析模型内容）；validate 阶段代码校验 document_id ∈ run.inputs 且锚点真实存在，非法锚点剔除（evidence_status='unverified'），合法锚点写 `object_source_link(src_type='test_requirement'|'test_case')`（F3 plan A8 共用表扩展枚举值，implement 阶段与 F3 侧协调）。量化阈值（FR8.3.4）：判定标准含"值+单位"且匹配 F1.4 Fields 时自动关联该字段锚点，可定位原文 | FR8.2.2、FR8.3.4；C-Q1；F3 plan A8；F7 plan A4 对照 |
| A5 | **复用判定为确定性两段算法、标注永不自动生效**：① 关键词预筛（「测试项目+判定标准」分词粗匹配，zhparser 通道）淘汰测试对象明显不同的候选；② 平台统一 embedding（bge-m3，与 F3 一致）余弦相似度判定；阈值 0.90 为配置项 `testgen.reuse.threshold`，边界带 [阈值−0.05, 阈值) 标"疑似复用"但不计复用统计（C-Q2）。复用项与新增项同入 DRAFT 逐条人工处置，卡片展示来源链接+分数+固定提示（C-Q2 兜底）；历史库为空全标新增（C-Q2 Assumptions）。候选范围 = 历史用例库 + 本项目已采用用例（C-Q2 Assumptions）；embedding 在归档/采用时点预计算存储，判定阶段零在线 embedding 调用 | FR8.4.1、FR8.4.2、AC8.4.1；C-Q2 及 Assumptions |
| A6 | **Case ID 号段预占 + 项目内游标分配 + 作废不回收**：run 创建时按「预估产出条数 ×1.2」预占号段记入 generation_run（C-Q4）；分配器从预占区间顺序取号，`TC-{项目代号}-{seq:03d}`（超 999 自然进位）；任务失败/用例忽略后号段作废不回收（宁留空洞不重号，C-Q4）；并发防护：项目级 case_no 游标行 `SELECT ... FOR UPDATE` 串行化（在 F4.5 异步任务模型内，无需分布式锁）；`external_case_no` 可空列承载企业编号，非空时列表/详情/导出与 F9 侧优先展示，TC 号不变（C-Q4）；项目代号变更不回溯已生成 ID（C-Q4 Assumptions） | FR8.3.2；C-Q4 及 Assumptions；F9 FR9.1.1 |
| A7 | **状态机接 F10.2 通用 workflow、处置即定版、ADOPTED 不锁定**：test_requirement/test_case 继承 BaseEntity，state 走 F10.2 映射 `DRAFT→ADOPTED/IGNORED`（F10 plan §2.2 转换配置表；无 IN_REVIEW 中间态）；dispose 为 F10 通用 transition 的语义化包装端点，仅人工 API 可触发（FR10.2.2：AI 无直写终态通路）；IGNORED→ADOPTED 允许重新采用（处置可逆，入审计）。**ADOPTED 后允许继续编辑**（用例执行期需修正，FR8.6 生命周期使然）：逐字段写 diff + 审计，不做 OBJECT_LOCKED（与 FMEA 定版锁定不同，见假设②）；执行状态为独立列 + 独立历史表，不入 F10 状态机（spec §5"执行状态独立于 AI 状态机"） | FR8.5.1、FR8.5.2、FR8.6.1；spec §5；F10 plan §2.2；C-Q3 Assumptions |
| A8 | **diff 单表双用：修改率统计与审计共用**：`testreq_diffs` / `case_diffs` 为唯一修改留痕处，逐字段记录 old/new + 操作人/时间；audit `*.edited` 引用 diff id；修改率 = 有 ≥1 条 diff 的已采用对象 / 已采用对象（编辑记录前后 diff，FR8.5.2）。[AI] 标注为对象级（ai_generated 列）+ 处置卡片角标，人工编辑后角标消除（对齐 specs/README「[AI] 输出 UI 必须带标识」与 F7 plan A9 语义，F8 字段级角标简化为对象级——七字段整体生成，处置粒度即对象） | FR8.5.2；spec §5 KPI；specs/README AI 草稿语义；F7 plan A9 对照 |
| A9 | **覆盖率统计 = 确定性 SQL + 权重配置预留**：`覆盖率 = 有≥1条ADOPTED用例挂接的ADOPTED需求数 / ADOPTED需求总数`，不加权（C-Q3）；挂接关系为统计基础（FR8.3.3），经 test_case_requirements 关联表 JOIN 计算；`GET /test-coverage` 返回分子/分母/覆盖率 + 未覆盖需求明细下钻；实现读取配置 `testgen.coverage.weights`（默认全 1），质量部后续加权仅改配置与计算（C-Q3 预留）；未映射用例不入覆盖率口径、在 run 统计与用例列表单独可见（假设④） | FR8.3.3；C-Q3；spec §5 KPI |
| A10 | **归档 = 复制入 historical_cases 物理表 + 预计算 embedding**：POST archive 将本项目 ADOPTED 用例（含最终字段与执行结果摘要）复制入 `historical_cases`（来源项目/时间/源用例 id），同批计算 embedding 存储（pgvector）；归档幂等（UNIQUE(source_case_id)）；项目结项钩子触发同一服务（FR8.6.3"项目结项（或手动操作）"）。归档物供 F8.1.3 筛选选择与 F8.4 复用判定，跨项目可见性遵循项目权限继承（FR10.5.3：历史用例仅项目成员可被推荐/检索，库内列表限本部门+本人项目，见假设⑤） | FR8.6.3、FR8.1.3、FR8.4.1；FR10.5.3；C-Q2 |
| A11 | **执行状态 Excel 导入为同步操作、行级警告语义对齐 F9.1.2**：模板列 `Case ID / 执行状态 / 备注（可空）`，模板下载提供；解析经 F1 xlsx native 通道（禁绕过数据契约）；逐行校验：Case ID 不存在 → 行级警告（可"忽略未知行"继续）；状态值非法 → 行级错误；成功行更新 exec_status + 写 history + 审计；文件规模有界（≤5000 行），同步返回警告列表不排任务队列（假设⑥） | FR8.6.2；specs/README 数据契约；F9 FR9.1.2 对照 |
| A12 | **前端页面19/20按 UI_GUIDE 落地、处置列表客户端内存操作**：生成配置页四类资料分组勾选 + 已选清单常显 + 历史用例按项目/关键词筛选（FR8.1.1–FR8.1.3）；统计卡 `新增 N / 复用 N`、复用项可展开看历史来源（FR8.4.2）；逐条处置卡片 [采用][编辑后采用][查看依据]（FR8.5.1）；用例集列表执行状态标签 + 筛选 + 批量导入对话框 + 归档按钮（FR8.6）；单 run 产出有界（≤百条级），处置列表全量加载客户端筛选（同 F7 plan A11 手法）；定版/处置按钮按权限显隐，后端 require_perm 强制（F10 plan A7） | FR8.1–FR8.6 各条；UI_GUIDE 页面19/20；F10 plan A7 |
| A13 | **F4 技能复用同一入口**：F4 testcase_gen 技能经 `POST /test-gen/runs` 同一入口发起（spec 头表被依赖 F4；同 F6/F7 plan 先例），任务卡展示统计与后续动作（F4.4.2） | spec 头表；F4.2/F4.4；F7 plan A12 同构 |

---

## 2. 数据模型

全部主键 UUIDv7、时间 UTC（specs/README 约定）。`test_requirements`/`test_cases` 继承 F10 BaseEntity 公共列（FR10.1.3：id/project_id/created_by/created_at/updated_at/state/audit_ref），注册进 F10.1 统一对象模型（FR10.1.1 TestCase；TestRequirement 为其扩展注册对象，implement 阶段补注册表条目）。

### 2.1 test_requirement 与 test_case（spec §3）

```text
test_requirements(
  # BaseEntity 公共列：id, project_id, created_by, created_at, updated_at,
  #                    state(DRAFT→ADOPTED|IGNORED, F10.2 映射，A7), audit_ref
  run_id→generation_runs NULL,       # 生成来源 run（手工来源为 NULL，见假设③）
  seq INT,                           # run 内序号（LLM 挂接寻址键，UNIQUE(run_id, seq)）
  test_item TEXT,                    # 测试项目（七要素①）
  purpose TEXT,                      # 测试目的（②）
  test_condition TEXT,               # 测试条件（③）
  test_method TEXT,                  # 测试方法（④）
  test_equipment TEXT,               # 测试设备（⑤）
  sample_quantity TEXT,              # 样本数量（⑥）
  criteria TEXT,                     # 判定标准（⑦；任一为空即无效行，FR8.2.1）
  ai_generated BOOLEAN DEFAULT false,# 采纳率分母口径（A8）
  evidence_status VARCHAR,           # linked | unverified（锚点全部被剔时，A4）
  disposed_by→users NULL, disposed_at,   # 处置留痕（FR8.5.1）
  created_at/updated_at（BaseEntity）
)
-- 索引：(project_id, state), (run_id, seq) UNIQUE

test_cases(
  # BaseEntity 公共列（state: DRAFT→ADOPTED|IGNORED，A7）
  run_id→generation_runs NULL, seq INT,
  case_no VARCHAR UNIQUE,            # TC-{项目代号}-{seq:03d}（FR8.3.2，C-Q4，A6）
  external_case_no VARCHAR NULL,     # 企业既有编号（人工录入，展示优先，C-Q4）
  requirement_ids JSONB,             # 逻辑挂接（冗余快照，供展示）；统计真值在关联表
  precondition TEXT,                 # 前置条件（PRD §31）
  input_condition TEXT,              # 输入条件
  steps JSONB,                       # 操作步骤编号列表 ["1. ...", "2. ..."]
  expected TEXT,                     # 预期结果
  criteria TEXT,                     # 判定标准（尽量含量化阈值，FR8.3.4）
  equipment TEXT,                    # 测试设备
  requirement_mapped BOOLEAN DEFAULT true,  # false = 未映射需求（FR8.3.3 标注+统计）
  reuse_flag VARCHAR DEFAULT 'new',  # new | reused | suspected（疑似复用不计统计，C-Q2）
  reuse_of→historical_cases NULL,    # 复用来源用例（FR8.4.1 来源链接）
  reuse_score NUMERIC NULL,          # 相似度分数（处置卡片展示，C-Q2）
  ai_generated BOOLEAN DEFAULT false,
  exec_status VARCHAR DEFAULT 'not_started',
                                     # not_started | in_progress | passed | failed
                                     # （未开始/进行中/通过/失败，FR8.6.1，独立于 state，A7）
  exec_note TEXT NULL,               # 执行备注（Excel 导入备注列/手工填写）
  exec_updated_by→users NULL, exec_updated_at,
  evidence_status VARCHAR,           # linked | unverified | no_mapping（A4/FR8.3.3）
  archived_case_id→historical_cases NULL,  # 归档回指（防重复归档，A10 幂等）
)
-- 索引：(project_id, state), (project_id, exec_status), (case_no) UNIQUE,
--       (external_case_no), (reuse_flag), (run_id, seq)
```

### 2.2 关联表、diff、历史库与 run（spec §3）

```text
test_case_requirements(              # 用例↔需求挂接（覆盖率统计真值，FR8.3.3，A9）
  id UUIDv7 PK, case_id→test_cases, requirement_id→test_requirements,
  linked_by VARCHAR,                 # generation | manual（编辑阶段可人工调整挂接）
  UNIQUE(case_id, requirement_id)
)

testreq_diffs(                       # FR8.5.2 编辑 diff（审计+修改率共用，A8）
  id UUIDv7 PK, requirement_id→test_requirements, project_id,
  field VARCHAR,                     # test_item|purpose|test_condition|test_method|
                                     # test_equipment|sample_quantity|criteria
  old_value JSONB, new_value JSONB, edited_by→users, edited_at
)
case_diffs(                          # 同构：precondition|input_condition|steps|expected|
  ...                                # criteria|equipment|requirement_ids|external_case_no
)
-- 均为 append-only（冲正以新记录追加，对齐审计 append-only 语义，F7 plan 假设③手法）
-- 索引：(对象id), (project_id, edited_by, edited_at)；修改率=有≥1条diff的ADOPTED对象/ADOPTED对象

historical_cases(                    # FR8.6.3 归档库（F8.1.3/F8.4 复用来源，A10）
  id UUIDv7 PK,
  source_case_id→test_cases UNIQUE,  # 幂等键（一用例至多一条归档，A10）
  project_id,                        # 来源项目（"test_case 的归档视图（来源项目、时间）"，spec §3）
  case_no, external_case_no, test_item（来自挂接主需求冗余）, precondition, input_condition,
  steps JSONB, expected, criteria, equipment,
  exec_summary JSONB,                # 归档时点执行结果摘要 {passed, failed, total}
  embedding vector,                  # 平台统一 embedding 预计算（A5，复用判定零在线调用）
  embedding_model VARCHAR,           # 模型标识（模型更换需全量重算，风险表）
  archived_by→users, archived_at, source_case_updated_at
)
-- 索引：(project_id), pgvector ivfflat(embedding)；关键词预筛走 test_item+criteria 文本列

generation_runs(                     # spec §3：供审计与统计
  id UUIDv7 PK, project_id, created_by→users, created_at,
  inputs JSONB,                      # [{document_id, doc_version, parse_version, tag,
                                     #  ocr_ratio, low_conf_ratio}]（C-Q1 元数据；FR10.3.1）
  historical_case_ids JSONB NULL,    # 显式勾选的历史用例（FR8.1.1 第四类）
  reserved_from INT, reserved_to INT,# 号段预占区间（C-Q4，A6）
  model VARCHAR, model_version, prompt_req_id/version, prompt_case_id/version,
  kb_version INT,                    # 审计必填（FR10.3.1，specs/README kb_version 约定）
  stats JSONB,                       # {new, reused, suspected, unmapped, invalid_dropped,
                                     #  req_total, case_total}（FR8.4.2 统计卡数据源）
  status VARCHAR,                    # QUEUED/RUNNING/SUCCESS/FAILED/CANCELED（specs/README）
  task_id UUID                       # F10 Task 对象关联（SSE 进度）
)
-- 索引：(project_id, created_at)

case_exec_history(                   # FR8.6.1 状态流转记录操作人与时间（AC8.6.1 历史可查）
  id UUIDv7 PK, case_id→test_cases, old_status, new_status,
  changed_by→users, changed_at, source VARCHAR,   # manual | excel_import
  note TEXT NULL
)
-- 索引：(case_id, changed_at)
```

### 2.3 共用与平台侧（不新建表）

```text
object_source_link                   # F3/F7/F8 共用单表（F3 plan A8）：本次扩展
                                     # src_type ∈ {test_requirement, test_case}，
                                     # dst=document/chunk（含 page/bbox 定位，FR8.5.1 跳原文）
tasks                                # F10.1 Task：type='testgen_run'，result_ref=run_id
audit / kpi_events / state_transitions  # F10.3/F10.6/F10.2 平台表直接复用
```

---

## 3. API 设计（遵循 specs/README：REST /api/v1、统一错误体、异步任务 SSE）

### 3.1 端点清单

```text
# 输入资料与发起（F8.1，异步生成）
GET  /api/v1/projects/{id}/test-gen/inputs
                                     # 四类候选分组：{spec_docs[], customer_req_docs[],
                                     # test_standard_docs[], historical_cases[]}
                                     # （文档按 F2 标签分组，历史用例支持 ?q=&source_project=，
                                     # FR8.1.1/8.1.3，A12/假设⑦）
POST /api/v1/test-gen/runs           # body: {project_id, document_ids[], historical_case_ids[]?}
                                     # → 201 {run_id, task_id}
                                     # 校验：权限 testgen.create、≥1 输入（FR8.1.2）、
                                     # 文档属项目 + PARSE_CONFIRMED（A2）
GET  /api/v1/test-gen/runs?project_id=&status=&page=&page_size=
GET  /api/v1/test-gen/runs/{id}      # run 元数据 + stats 统计卡（FR8.4.2）+ 结果列表
                                     # （requirements + cases，含 reuse 标注与 evidence 摘要）

# 测试需求（F8.2/F8.5）
GET   /api/v1/test-requirements      # ?project_id=&state=&run_id=&q= 分页
GET   /api/v1/test-requirements/{id} # 详情 + 依据引用摘要 + 挂接用例列表
PATCH /api/v1/test-requirements/{id} # 编辑（七要素逐字段），写 diff + audit（FR8.5.2）
POST /api/v1/test-requirements/{id}/dispose
                                     # body: {action: adopt|ignore}（FR8.5.1；DRAFT→ADOPTED/
                                     # IGNORED，IGNORED→ADOPTED 重采用，A7）
POST /api/v1/test-requirements/batch-dispose
                                     # body: {action, filters}（FR8.5.3 按筛选条件批量）

# 测试用例（F8.3/F8.5）
GET   /api/v1/test-cases             # ?project_id=&state=&exec_status=&reuse_flag=&q=
GET   /api/v1/test-cases/{id}        # 详情 + 挂接需求 + 依据摘要 + 执行历史
PATCH /api/v1/test-cases/{id}        # 编辑（七字段 + requirement_ids 挂接调整 + external_case_no），
                                     # 写 diff + audit（FR8.5.2）
POST /api/v1/test-cases/{id}/dispose # {action: adopt|ignore}（FR8.5.1）
POST /api/v1/test-cases/batch-dispose
GET  /api/v1/test-cases/{id}/evidence
                                     # 依据明细（片段/来源文档/定位 bbox/OCR提示，FR8.5.1，
                                     # = GET /api/v1/links?src_type=test_case&src_id= 的语义化包装）

# 执行状态（F8.6.1/F8.6.2，人工）
PATCH /api/v1/test-cases/{id}/exec-status
                                     # body: {exec_status, note?} → 写 history + audit
                                     # case.exec_status.changed（spec §5；AC8.6.1）
POST /api/v1/test-cases/exec-status-import
                                     # multipart xlsx → 同步行级结果 {imported, warnings[]}
                                     # （FR8.6.2，A11/假设⑥）；GET .../exec-status-import/template
GET  /api/v1/test-cases/{id}/exec-history   # AC8.6.1 历史可查

# 覆盖率与归档（C-Q3 / FR8.6.3）
GET  /api/v1/projects/{id}/test-coverage
                                     # {numerator, denominator, coverage, weights_applied,
                                     #  uncovered: [{requirement_id, test_item, ...}]}（A9）
POST /api/v1/projects/{id}/cases/archive
                                     # 已采用用例归档入历史库（body 可选 case_ids，
                                     # 缺省全量 ADOPTED；幂等，FR8.6.3，A10）
GET  /api/v1/historical-cases        # ?q=&source_project=&page= （F8.1.3 筛选选择，A12）

# 依据引用增删（编辑阶段人工补链）——复用 F3 通用链接接口（F3 plan A8）
POST   /api/v1/links                 # {src_type: test_requirement|test_case, src_id, ...}
DELETE /api/v1/links/{id}

# 任务（specs/README 异步约定）
GET  /api/v1/tasks/{id}/events       # SSE：QUEUED/RUNNING(stage=gather|gen_req|validate|
                                     # gen_case|validate2|reuse|numbering|persist,
                                     # progress)/SUCCESS/FAILED/CANCELED
POST /api/v1/tasks/{id}/cancel       # F4.5
```

### 3.2 语义与错误

- 统一错误体 `{"code","message","detail"}`。本 feature 新增错误码：
  - `TESTGEN_INPUT_REQUIRED`（FR8.1.2：未选择任何输入）
  - `TESTGEN_SOURCE_DOC_NOT_READY`（A2：所选文档未解析成功或未 PARSE_CONFIRMED，detail 列出不合格文档）
  - `TESTGEN_GENERATION_FAILED`（A3：重试后仍无有效需求/用例）
  - `TESTGEN_RUN_NOT_CANCELABLE`（任务已 SUCCESS/FAILED 后取消）
  - `TESTCASE_EXEC_STATUS_INVALID`（FR8.6.1：非法状态值）
  - `TESTCASE_IMPORT_TEMPLATE_MISMATCH`（FR8.6.2：列模板不符，A11）
  - `TESTCASE_ARCHIVE_NOT_ADOPTED`（FR8.6.3：仅 ADOPTED 用例可归档，A10）
  - `INVALID_TRANSITION`/`FORBIDDEN`/`OBJECT_LOCKED` 复用 F10 通用码（FR10.2/FR10.5）
- **异步边界**：仅生成 run 走 Celery `testgen` 队列 + SSE（specs/README 异步约定）；处置/编辑/执行状态/归档/Excel 导入均为同步操作；F4 testcase_gen 技能经同一 runs 端点入队（A13）。
- **幂等与并发**：编辑以后写为准（单人编辑假设，spec §6 非目标未含协同编辑）；同项目并发发起 run：号段预占经项目游标行锁串行化（A6）；归档幂等（UNIQUE source_case_id）；批量 dispose 对已终态对象跳过（部分成功语义，响应逐条结果）。
- **权限**（F10.5 矩阵）：查看/编辑/处置/执行状态更新/导入/归档 = 工程师+（项目成员可见性继承 FR10.5.3）；发起生成 = 工程师+；历史用例库跨项目列表 = 项目成员（可见性规则假设⑤）；删除类操作 Phase 1 不开放（DRAFT run 保留审计）。
- **统计口径**（FR8.4.2、C-Q2/C-Q3）：统计卡复用数仅计 reuse_flag='reused'（suspected 不计）；覆盖率分母/分子仅计 ADOPTED 对象（A9）；未映射用例单独计数展示（假设④）；口径与 F10.6 KPI 报表注释同源固化。

---

## 4. AI/LLM 使用点

| 项 | 设计 | 溯源 |
| ---- | ---- | ---- |
| LLM 使用范围 | **两处**：① 测试需求七要素生成（FR8.2.1）；② 测试用例七字段生成（FR8.3.1）。复用判定（FR8.4.1）、覆盖率（C-Q3）、Case ID（FR8.3.2）、执行状态/导入/归档（FR8.6）全部确定性代码 | A1/A3/A5/A9 |
| 模型策略 | 经 F10 `LLMGateway`：生成模型走配置（私有化可替换、数据不出企业域，PRD §53）；审计记录实测 model/model_version。embedding 复用平台统一 bge-m3 通道（复用判定 + 归档预计算），无新增模型需求 | F10 plan §4 挂点 2；FR10.3.1；C-Q2 |
| Prompt 策略 | Prompt 注册表管理，两个 prompt_id：`f8.test_requirements`（输入：项目上下文 + 所选文档解析模型序列化文本（Fields 参数表优先，A2）+ 输出要求：七要素齐全、逐条附证据锚点、判定标准含量化阈值时引用参数字段）；`f8.test_cases`（输入：本轮已生成需求集（seq+全文）+ 同源文档摘要 + 输出要求：七字段齐全、steps 编号列表、每条挂接 ≥1 requirement_seq、无法挂接显式输出 unmapped、禁止编造 Case ID——case_no 由代码分配）。禁止裸字符串 prompt（FR10.3.4） | FR8.2.1、FR8.3.1–FR8.3.4；FR10.3.4 |
| 结构化输出 schema | 强制 JSON Schema（Pydantic 校验）。需求：`{"requirements":[{seq, test_item, purpose, test_condition, test_method, test_equipment, sample_quantity, criteria, evidence:{document_id, anchor, quote}?}]}`；用例：`{"cases":[{seq, requirement_seqs:[...]|"unmapped", precondition, input_condition, steps:[], expected, criteria, equipment}]}`——**schema 不含 case_no、复用标记与任何统计字段**（构造性保证 A1：编号/复用/统计不可能由 LLM 产出）。schema 校验失败/要素空 → 带错误反馈重试 1 次（A3） | FR8.2.1、FR8.3.1–FR8.3.3；A3/A4 |
| Grounding/防幻觉 | ① 证据锚点代码校验后才落 object_source_link（A4，非法锚点剔除不静默采纳）；② 挂接校验：requirement_seqs 必须命中本轮需求集，否则标 unmapped（FR8.3.3）；③ 复用判定仅由向量+预筛代码产生（A5）；④ 生成产物整体 DRAFT + [AI] 标识 + 逐条人工处置（FR8.5、specs/README AI 草稿语义）；⑤ 审计记录 kb_version + 输入清单 + 引用清单可抽样回查（FR10.3.1）；⑥ OCR 来源依据卡片带 F1 标红提示（C-Q1 Assumptions） | FR8.2.2、FR8.3.3、FR8.5.1；FR10.3.1；C-Q1/C-Q2 |
| 审计接入 | `testgen.run`（模型/prompt版本/kb_version/输入清单/输出数，spec §5）、`testreq.edited/adopted/ignored`、`case.edited/adopted/ignored`（spec §5 命名）、`case.exec_status.changed`（spec §5）、`case.exec_status.imported`、`case.set.archived`（新增按 `<domain>.<verb>` 规则命名，FR10.3.3） | spec §5；FR10.3.1、FR10.3.3 |
| KPI 埋点 | `testgen.generate`（run 任务耗时）；`testgen.start → 处置完成` 耗时（spec §5：run.created_at → 该 run 全部产出对象达终态时点，需求覆盖率 KPI 的过程指标）；`*.adopted/*.edited` 埋点供采纳率/修改率报表（PRD §50 AI 类 KPI）；覆盖率报表为质量类 KPI 输出（FR8 验收） | spec §5；FR10.6.2–FR10.6.4；C-Q3 |
| 评测方式 | ① **AC8.4.1 金标场景**（M4 硬门槛）：`evals/testgen_reuse/` 固化重复项目场景集——预置历史用例库 + 同类重复项目文档，离线跑管线断言：统计卡新增/复用划分与预置答案一致、复用项来源链接正确、边界带样本标 suspected 不计复用；② 需求/用例质量评测：金标集（≥2 个项目样例，含规格书+客户需求+企业标准混合输入）人工走查——七要素/七字段有效行率、量化阈值正确率（criteria 中阈值与规格书参数一致的比例）、挂接正确率抽样；③ 自动指标（观测）：invalid_dropped 率、unmapped 率、证据锚点有效率（合法锚点/输出锚点）、复用判定预筛淘汰率；④ prompt/模型版本变更触发金标回归；⑤ 线上采纳率/修改率为观测指标（不设硬门槛）；⑥ 覆盖率口径正确性以集成测试断言（C-Q3 公式） | AC8.4.1；C-Q1–C-Q3；spec §5 KPI |

---

## 5. 测试策略

| 层级 | 内容 | 溯源 |
| ---- | ---- | ---- |
| 单元（自检与校验） | 七要素/七字段空值剔除；无效集重试反馈构造；两级均空 → FAILED；invalid_dropped 计数；证据锚点校验（document_id 不在 inputs / 锚点不存在 → 剔除 + unverified）；requirement_seqs 未命中 → unmapped 标注（FR8.3.3）；steps 编号列表规范化 | FR8.2.1、FR8.3.3；A3/A4 |
| 单元（复用判定） | 预筛关键词粗匹配命中/淘汰矩阵（测试对象不同 → 淘汰）；余弦 ≥0.90 → reused；[0.85,0.90) → suspected 不计统计；历史库为空 → 全 new 且统计卡正常（C-Q2 Assumptions）；阈值/边界带配置项生效；候选范围 = 历史库 + 本项目 ADOPTED（C-Q2） | FR8.4.1、FR8.4.2；C-Q2 及 Assumptions；A5 |
| 单元（号段与覆盖率） | 号段预占区间分配顺序性；3 位零填充/进位；作废不回收（失败 run 后空洞）；项目游标并发分配互斥；覆盖率公式（C-Q3）：分母排除 DRAFT/IGNORED、分子要求 ADOPTED 用例挂接、权重配置默认全 1、uncovered 明细正确 | FR8.3.2、FR8.3.3；C-Q3/C-Q4；A6/A9 |
| 集成（生成管线） | fixtures：预置规格书+客户需求+企业标准（F1 解析桩）端到端 SUCCESS；断言 SSE 事件序列（gather→gen_req→validate→gen_case→validate2→reuse→numbering→persist）；需求/用例落库 DRAFT + ai_generated + evidence 落 object_source_link 且 /links 反查可读；OCR 元数据入 run.inputs（C-Q1）；未确认文档 → TESTGEN_SOURCE_DOC_NOT_READY；零输入 → TESTGEN_INPUT_REQUIRED | FR8.1.2、FR8.2.1–FR8.2.3、FR8.3.1–FR8.3.4；C-Q1；specs/README 异步 |
| 集成（处置与统计） | 逐条采用/忽略/编辑 → state 变更 + diff 落库 + 审计 + 修改率正确；批量按筛选处置部分成功；复用卡片展示来源链接+分数+固定提示（C-Q2）；AC8.4.1 金标场景：对含历史用例的重复项目发起生成，统计卡划分正确（评测集断言） | FR8.4.1、FR8.4.2、FR8.5.1–FR8.5.3、AC8.4.1 |
| 集成（用例库管理） | exec-status 更新 → history 记录操作人时间、列表与详情同步可见（AC8.6.1）；Excel 导入：正常行入库、未知 Case ID 警告可忽略、非法状态行级错误、模板不符 → TESTCASE_IMPORT_TEMPLATE_MISMATCH；归档幂等、归档后 historical_cases 可被 F8.1.3 检索与 F8.4 命中（FR8.6.3 闭环）；二次生成复用判定命中归档用例（归档→复用全链路） | FR8.6.1–FR8.6.3、AC8.6.1、AC8.4.1；A10/A11 |
| 集成（覆盖率与 KPI） | 覆盖率端点分子/分母/明细与手工 SQL 一致；testgen.run 审计含模型/prompt/kb_version/输入清单（FR10.3.1 字段完备性门槛）；start→处置完成耗时打点；采纳率/修改率报表可出数 | FR8.3.3、C-Q3；spec §5；FR10.3.1、FR10.6 |
| **禁绕过测试**（AC1.6.1 复用） | import-linter 禁止 testgen 模块直读 MinIO 原件/自建文档解析（输入一律消费 F1 解析模型）；禁止直连模型 SDK（必须经 LLMGateway）；禁止自行查 chunks 表（embedding 复用统一通道） | FR1.6.2、AC1.6.1；specs/README 数据契约；F10 plan 挂点 2 |
| 权限矩阵 | 参数化：5 角色 × {发起生成/编辑/处置/执行状态/导入/归档/覆盖率查看}；项目可见性断言；F4 testcase_gen 复用同一入口断言（A13） | FR10.5 矩阵；spec 头表 |
| API 契约 | 统一错误体/分页信封/SSE payload schema；新错误码逐条断言；批量部分成功响应结构 | specs/README、§3.2 |
| 评测 | `evals/testgen_reuse/` 金标场景（AC8.4.1，M4 硬门槛）+ 需求/用例质量人工走查集 + 自动指标观测 + prompt/模型变更回归 + 版本化归档 | §4 评测；AC8.4.1 |
| 前端 | 组件测试：四类资料勾选与已选清单常显（FR8.1.1–8.1.3）；统计卡与复用项展开（FR8.4.2）；处置卡片三动作与侧滑跳原文（FR8.5.1）；编辑表单 diff 提示；批量处置（FR8.5.3）；用例列表执行状态筛选与更新（FR8.6.1）；导入向导警告展示（FR8.6.2）；归档确认；覆盖率卡与未覆盖下钻（C-Q3）；[AI] 角标与复用提示条 | FR8.1–FR8.6 各条；UI_GUIDE 页面19/20 |

覆盖率目标遵循全局规则（新增模块 ≥80%）。

---

## 6. 风险与非目标

### 风险

| 风险 | 影响 | 缓解 |
| ---- | ---- | ---- |
| LLM 生成质量不稳定（要素泛泛、用例不可执行、挂接错位） | 处置成本高、采纳率低迷 | 代码级自检 + 重试（A3）；金标质量走查驱动 prompt 迭代（§4 评测②）；unmapped 显式标注不混入覆盖率（假设④） |
| 复用误判（误复用沿用不适用判定标准） | 工程风险 | C-Q2 保守设计：高阈值 0.90 + 关键词预筛 + 标注永不自动生效 + 处置卡片固定核对提示；误采用可编辑修正留 diff（FR8.5.2） |
| 证据锚点有效率低（LLM 锚点频繁对不上解析模型） | FR8.2.2 依据可追溯性打折 | 锚点校验强制（A4）+ evidence_status 可筛选；锚点有效率入观测指标；prompt 中附锚点编号清单降低幻觉；人工可经 /links 补链 |
| 企业测试标准为扫描件（OCR 质量） | 阈值抽取与依据质量下降 | C-Q1：优先引导电子版；OCR 比例/置信度入 run.inputs 观测；低置信度依据卡片标红提示核验（不阻断）；样例到位仅适配 F1 层 |
| 历史用例库冷启动 | 首期复用统计无意义 | C-Q2 Assumptions：空库全标新增、统计卡正常；AC8.4.1 金标场景以评测集预置历史库验证，不依赖线上数据积累 |
| 号段空洞引发编号连续性质疑 | 客户验收观感 | C-Q4 已决策"作废不回收、宁留空洞不重号"；`external_case_no` 承载企业编号；空洞可在导出/报表说明 |
| 执行状态人工维护负担（Phase 1 无自动化对接） | 用例库状态失真、覆盖率外指标失真 | Excel 批量导入（FR8.6.2，A11）+ 模板下载；执行历史可查（AC8.6.1）；自动化对接列入 §6 非目标（Phase 2） |
| embedding 模型更换导致历史向量失效 | 复用判定退化 | historical_cases.embedding_model 记录模型标识；更换视为 kb/模型版本变更，全量重算任务 + 金标回归（对齐 F3 plan C-Q4 同款约束） |
| KPI 基线缺失（人工编写测试需求/用例耗时未测） | spec §5 耗时 KPI 无法验收 | F10.6.3 人工基线联合测量为 M1 交付项；testgen 全链路打点覆盖（§4 KPI） |
| 覆盖率口径与质量部理解分歧 | 验收争议 | C-Q3 已固化不加权口径 + 明细下钻可核对；权重配置预留；口径对齐列入上线前验收流程项（非开发阻塞） |

### 非目标（Phase 1）

- 自动化测试脚本生成、测试执行调度、与 TCM/试验管理系统对接（spec §6）
- 覆盖率按需求类型加权计算（C-Q3：仅预留 `testgen.coverage.weights` 配置，待质量部口径）
- 企业编号体系自动对接与双向映射（C-Q4：Phase 2，`external_case_no` 人工录入过渡）
- 执行状态自动回写/自动化测试系统集成（FR8.6.2 明确 Phase 1 人工更新）
- 手工新建测试需求/用例入口（假设③：Phase 1 生成+编辑已覆盖；独立建库 Phase 2 评估）
- 需求/用例的跨项目共享用例库治理、标准条款树结构（C-Q1 Assumptions）
- AI 直写 ADOPTED（FR10.2.2 架构约束；dispose 仅人工 API）
- 协同实时编辑（后写为准 + 单人编辑假设）

---

## 7. 决策与假设记录（承接 clarifications）

- C-Q1：企业测试标准统一经 F1.6 解析入库（扫描件走 F1.3 OCR 兼容路径），作为检索上下文供生成引用，量化阈值优先取自 Fields/表格参数；不建专用抽取器，样例适配仅发生在 F1 层；OCR 比例/置信度入 `generation_run.inputs` 观测。→ A2/A4、§1.2、§2.2、§6
- C-Q2：复用判定 = 关键词预筛 + 向量余弦 ≥ 0.90（配置项 `testgen.reuse.threshold`，边界带 0.05 同为配置项）；复用标记仅为提示性标注、永不自动采用，处置卡片带来源链接+分数+固定核对提示；疑似复用不计统计；候选 = 历史用例库 + 本项目已采用用例。→ A5、§1.2、§2.1、§4、§5、§6
- C-Q3：覆盖率 = 有≥1条 ADOPTED 用例的 ADOPTED 需求数 / ADOPTED 需求总数，不加权；权重配置 `testgen.coverage.weights` 预留（默认全 1）；API 返回分子/分母/明细下钻；处置即定版（ADOPTED 与平台 APPROVED 语义在本 feature 同义）。→ A7/A9、§3.1、§4、§5、§6
- C-Q4：Case ID = `TC-{项目代号}-{序号3位零填充}`，项目内递增、超 999 自然进位；号段按预估 ×1.2 预占、作废不回收；不与企业编号体系兼容映射，`external_case_no` 可空列人工录入且非空时优先展示；企业编号自动对接 Phase 2。→ A6、§2.1、§3.1、§6
- 新增决策（无对应 Q，依 FR 推定，均已在正文标注）：
  - **假设①** 执行状态（exec_status）不入 F10 状态机，为独立列 + `case_exec_history` 独立留痕（spec §5 明确"执行状态独立于 AI 状态机"；FR8.6.1 要求操作人与时间可查）。
  - **假设②** ADOPTED 后允许继续编辑（不 OBJECT_LOCKED）：用例在执行期（FR8.6）需随实测修正，完全锁定不可行；代价由逐字段 diff + 审计承担（FR8.5.2），修改率统计不受影响；IGNORED→ADOPTED 重采用允许（处置可逆，入审计）。与 FMEA APPROVED 锁定语义的差异源于 F8 无 IN_REVIEW 定版环节、处置即定版（C-Q3 Assumptions）。
  - **假设③** 需求/用例仅由生成产生（run_id 非空）+ 编辑演化，不提供手工新建入口（spec FR8.5 处置动作仅 采用/编辑后采用/忽略，无新建；若实施期客户强需求，经变更评审补充，接口预留 source 字段扩展位）。
  - **假设④** 未映射用例（unmapped）不入覆盖率口径（覆盖率按需求定义，C-Q3），在 run 统计（stats.unmapped）与用例列表筛选（requirement_mapped=false）单独可见，满足 FR8.3.3"计入统计"。
  - **假设⑤** 历史用例库可见性：归档对象随来源项目权限继承（项目成员可见，FR10.5.3）；F8.1.3 候选列表默认展示本部门可见项目的归档用例，不支持的项目不出现在筛选器。最终口径实施期与客户确认。
  - **假设⑥** Excel 执行状态导入为同步接口（行级警告列表随响应返回，不对齐 F9 的"草稿+导入"两步模型——F8 导入仅改状态字段，无报告联动，文件规模有界 ≤5000 行，A11）。
  - **假设⑦** 四类资料的候选分组依据 F2 标签：规格书=tag `spec_sheet`、客户需求=tag `customer_req`、企业测试标准=tag `test_standard`（C-Q1 Assumptions：与规格书/客户需求同一文档表 + F2 分类标签）；标签缺失文档不入候选并在 inputs 端点返回提示（引导补标，不阻塞）。
  - **假设⑧** 需求↔用例挂接为 M2N 关联表（test_case_requirements），spec §3 的 `requirement_ids[]` 以 JSONB 冗余快照保留供展示；覆盖率统计以关联表为真值（A9）；编辑阶段允许人工调整挂接（linked_by='manual'，服务覆盖率口径的准确性）。
