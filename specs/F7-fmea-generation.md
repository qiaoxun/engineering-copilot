# F7 AI FMEA生成 — Feature Spec

| | |
| ---- | ---- |
| 编号 | F7 |
| 来源 | PRD §46.6、§26、§43；UI 页面16；PHASE1_FEATURES F7.1–F7.6 |
| 依赖 | F1.6（解析输入）、F2/F3（历史案例引用）、F10.2（审核流） |
| 被依赖 | F4（fmea_gen 技能）、F9.6（异常转 FMEA 风险条目） |
| 里程碑 | M4 |

## 1. 概述

基于规格书/结构信息 + 知识库历史案例生成 FMEA 初稿：五维链（功能→失效模式→失效影响→失效原因→控制措施，PRD §26）、S/O/D 与 RPN、每条建议附历史依据；专业表格编辑 + 人工审核定版（PRD §43）。验收 KPI：FMEA 初稿时间 ↓ ≥ 60%；AI 建议采纳率/修改率可统计。

## 2. Feature Units

### F7.1 五维链生成

- **FR7.1.1** 输入：当前项目关联的规格书/结构类文档（多选，来自 F2）+ 项目/产品上下文；可选填写 FMEA 范围说明（如"仅电池包密封子系统"）。
- **FR7.1.2** 生成输出为结构化行（JSON Schema 约束，LLM 结构化输出）：`{功能, 失效模式, 失效影响, 失效原因, 控制措施, 引用[]}`；五个维度任一为空则该行无效，生成后自检并剔除/重试。
- **FR7.1.3** 每行携带 ≥1 条知识库案例引用（复用 F3 检索，`object_source_link` 关联）；检索无命中时该行标注"无历史依据"。
- **FR7.1.4** 生成走异步任务（F4.5），完成后进入 FMEA 工作台（UI 页面16），初稿态为 `DRAFT`。
- **AC7.1.1** 对含明确功能描述的规格书生成 ≥10 行有效五维链（金标场景走查：维度语义正确、无空维度）。

### F7.2 S/O/D 打分与 RPN

- **FR7.2.1** S/O/D 建议值基于：内置规则（按失效影响的严重度语义）+ 历史案例中的既有打分统计；每项建议附一句理由。
- **FR7.2.2** 评分标准表（1–10 语义分档）系统内置可配置，由业务专家评审后固化。
- **FR7.2.3** `RPN = S × O × D` 实时计算；风险色标阈值可配置（默认 ≥100 红 / 50–99 橙 / <50 绿，对齐 VDA/AIAG 见 Q2）。
- **FR7.2.4** S/O/D/RPN 人工可改；人工改动覆盖 AI 建议并记录。

### F7.3 历史依据引用

- **FR7.3.1** 每行提供"查看历史案例"侧滑面板：引用片段、来源文档、项目、时间，可跳转原文定位（复用 F3.4）。
- **FR7.3.2** 引用可增删（工程师可补充自己知道的历史案例链接）。

### F7.4 专业表格编辑

- **FR7.4.1** 类电子表格交互：行内编辑、增行/删行、按列排序、按风险等级筛选。
- **FR7.4.2** AI 生成的单元格带 [AI] 角标；人工修改后角标消失，修改前后值记入 diff。
- **FR7.4.3** 批量操作：按行 采纳/忽略 AI 建议；`采纳率 = 采纳行数 / AI生成行数`，`修改率 = 被人工修改行数 / 采纳行数`，埋点上报。
- **AC7.4.1** 采纳/忽略/行内编辑操作后，统计数字在 KPI 报表中正确出现。

### F7.5 人工审核流

- **FR7.5.1** 状态流转：`DRAFT（AI初稿/编辑中）→ IN_REVIEW（提交审核）→ APPROVED（定版）`；APPROVED 后表格锁定。
- **FR7.5.2** 定版操作限"研发主管"角色；定版时强制填写审核意见。
- **FR7.5.3** 定版后需修改 → 创建新修订版本（revision +1），旧版本只读留存；版本可对照。
- **AC7.5.1** 工程师角色无定版按钮/接口（403）；定版后编辑接口返回锁定错误。

### F7.6 FMEA 导出

- **FR7.6.1** Excel / Word，标准 FMEA 表格排版（表头含 S/O/D/RPN 列）；`DRAFT` 导出带草稿水印。
- **FR7.6.2** 导出内容含：行明细、审核意见、版本号、定版人与时间。

## 3. 数据模型（核心）

| 实体 | 关键字段 |
| ---- | ---- |
| `fmea` | id, project_id, product_id?, revision, status(F10.2), scope_note?, approved_by/at, review_comment |
| `fmea_row` | fmea_id, seq, function, failure_mode, effect, cause, control, s, o, d, rpn, ai_generated(bool), evidence_links[](object_source_link) |
| `fmea_row_diff` | row_id, field, old, new, edited_by, edited_at —— 修改率与审计共用 |
| `sod_rubric` | 维度, 分值, 语义描述, weight? —— 可配置评分标准 |

## 4. API 概要

```
POST /api/v1/fmeas/generate            # 发起生成（异步）
GET  /api/v1/fmeas/{id}                # 表格数据（行+引用）
PATCH /api/v1/fmeas/{id}/rows/{rid}    # 行内编辑
POST /api/v1/fmeas/{id}/rows/batch     # 批量采纳/忽略/增删
POST /api/v1/fmeas/{id}/submit-review  # DRAFT→IN_REVIEW
POST /api/v1/fmeas/{id}/approve        # 定版（限研发主管）
POST /api/v1/fmeas/{id}/revise         # 新修订版本
POST /api/v1/fmeas/{id}/export         # excel/word
```

## 5. 横切接入（F10）

- **状态机**：F7.5 是 F10.2 在生成类对象上的样板实现；AI 无任何直写 APPROVED 通路。
- **审计**：`fmea.generated`（模型/prompt版本/kb_version/引用清单/输出行数）、`row.edited`（diff）、`row.adopted/ignored`、`fmea.approved`。
- **KPI**：`fmea.generate` 耗时；`start(发起生成)→approve` 人工总耗时（验收 ↓60%）；采纳率/修改率报表（PRD §50 AI类KPI）。

## 6. 非目标

DFMEA/PFMEA 模板差异与工艺流程联动（PFMEA 属第二阶段制程能力）、多方协同实时编辑、FMEA 数据库跨项目复用治理。

## 7. 开放问题

- **Q1** S/O/D 评分标准表初稿（业务专家）与五维链生成质量的评测集（建议 3 个项目金标）。
- **Q2** 色标阈值采用 VDA-SSR 还是 AIAG-VDA FMEA 手册标准（影响阈值与列结构）。
- **Q3** 单个 FMEA 建议行数上限（防 token 失控，建议初稿 ≤50 行，可分区域多次生成）。
