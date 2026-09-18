# F9 测试报告生成 — Feature Spec

| | |
| ---- | ---- |
| 编号 | F9 |
| 来源 | PRD §46.8、§32、§43；UI 页面21；PHASE1_FEATURES F9.1–F9.6 |
| 依赖 | F8（用例与判定标准）、F10.1/10.2（对象与确认流） |
| 被依赖 | F4（report_gen 技能）、F7（FMEA 风险条目联动） |
| 里程碑 | M4 |

## 1. 概述

从测试数据 + 用例 + 判定标准自动生成测试报告（PRD §32）：统计与图表、异常项定位与 AI 整改建议、模板化正文；测试结论进入正式体系前必须人工确认（PRD §43）。验收 KPI：测试报告制作时间 ↓ ≥ 70%。

## 2. Feature Units

### F9.1 测试数据导入

- **FR9.1.1** 格式：`xlsx/csv`；列模板：`Case ID / 样本编号 / 实测值 / 实测单位 / 判定（可空，系统按判定标准自动判）/ 备注`；提供模板下载。
- **FR9.1.2** 导入时与本项目用例集关联校验：Case ID 不存在 → 行级警告列表（可"忽略未知行"继续）。
- **FR9.1.3** 判定为空的行：按关联用例的判定标准自动判定（Pass/Fail）；无法判定的行标记"待人工判定"。
- **AC9.1.1** 导入含 3 条未知 Case ID 的数据文件，警告列表准确且其余行正常入库。

### F9.2 自动统计与图表

- **FR9.2.1** 自动统计：用例数 / 样本数 / Pass / Fail / 通过率；按测试项目分组汇总。
- **FR9.2.2** 图表自动生成：各测试项目通过率柱状图、失败分布图；报告配置中可选启用哪些图表。
- **FR9.2.3** 统计口径固定并在报告"数据统计"节说明（避免歧义）。

### F9.3 异常项分析

- **FR9.3.1** 对每个 Fail/超限样本输出：定位（用例 Case ID + 样本编号）、实测值 vs 判定标准、超限幅度 `((实测-标准)/标准)%`、影响判定。
- **FR9.3.2** AI 整改建议：结合异常项 + 知识库历史质量问题给出建议（标注 [AI]，走 F10.2 确认后才计入正式报告）。
- **FR9.3.3** 异常项清单支持人工补充备注与责任归属。
- **AC9.3.1** 构造含超限样本的数据集，超限幅度计算与预置答案一致。

### F9.4 报告正文生成

- **FR9.4.1** 章节模板（PRD §32，模板可编辑——docxtpl）：`概要 / 测试范围（用例集引用）/ 数据统计 / 图表 / Pass-Fail 明细 / 异常项分析 / 结论 / 附件清单`。
- **FR9.4.2** 结论章节由 AI 生成草稿（基于统计与异常项，禁止引入数据之外的信息）；**人工必须修改或明确确认后方可定版**。
- **FR9.4.3** 报告对象状态走 F10.2：`DRAFT → IN_REVIEW → APPROVED`；`APPROVED` 前导出带"DRAFT"水印。

### F9.5 报告导出

- **FR9.5.1** PDF / Word 双格式；导出记录入审计（谁、何时、哪个版本）。
- **FR9.5.2** 附件清单区列出：原始数据文件、关联 FMEA/用例集引用。

### F9.6 后续联动

- **FR9.6.1** "生成 FMEA 风险条目"：将选定异常项写入关联 FMEA 表为新行（草稿态，`失效模式/影响` 来自异常信息，附报告引用），进入 F7 审核流。
- **FR9.6.2** "创建问题单"：创建 `Issue` 对象，分类写入知识库质量问题分类（与 F6.5 同一 Issue 模型），关联报告与样本数据。
- **AC9.6.1** 从报告一键生成的 FMEA 行在 FMEA 工作台可见且带来源引用。

## 3. 数据模型（核心）

| 实体 | 关键字段 |
| ---- | ---- |
| `test_data_import` | id, report_draft_id, file_key, row_count, warnings(JSONB) |
| `test_result_row` | import_id, case_id, sample_no, measured_value, unit, verdict(pass/fail/pending), delta_pct?, note? |
| `test_report` | id, project_id, case_set_ref, stats(JSONB), charts(JSONB), body(JSONB按章节), status(F10.2), approved_by/at |
| `report_anomaly` | report_id, result_row_ref, over_limit_pct, ai_suggestion?, suggestion_status(draft/confirmed), owner_note? |

## 4. API 概要

```
POST /api/v1/test-reports/drafts             # 建草稿并导入数据文件
GET  /api/v1/test-reports/{id}               # 报告内容（统计/图表/异常/正文）
POST /api/v1/test-reports/{id}/body/generate # 生成正文草稿（异步）
POST /api/v1/test-reports/{id}/approve       # 结论确认定版（F10.2）
POST /api/v1/test-reports/{id}/export        # pdf/word
POST /api/v1/test-reports/{id}/to-fmea       # 异常项→FMEA行
POST /api/v1/test-reports/{id}/to-issues     # 异常项→问题单
```

## 5. 横切接入（F10）

- **状态机**：报告 DRAFT→APPROVED 全程人工闸门；结论章节未确认时定版操作被拒。
- **审计**：`report.imported / body.generated / anomaly.confirmed / report.approved / report.exported`。
- **KPI**：`report.start → report.export` 耗时（验收 ↓70%）；`异常项分析耗时`子段打点。

## 6. 非目标

试验设备数据直采、SPC/CPK 等深度质量统计、报告多语言、电子签章（如客户要求属交付配置项）。

## 7. 开放问题

- **Q1** 判定标准的机器可执行表达（阈值型/区间型/布尔型），影响自动判定覆盖率，需与 F8 联合设计。
- **Q2** 报告 Word 模板是否使用企业现有模板（版式由实施期配置）。
- **Q3** 报告编号规则（RB-项目-年份-序号？）是否对齐企业质量体系文件编号。
