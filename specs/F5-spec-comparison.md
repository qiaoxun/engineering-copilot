# F5 规格书智能对比 — Feature Spec

| | |
| ---- | ---- |
| 编号 | F5 |
| 来源 | PRD §46.4、§21；UI 页面13；PHASE1_FEATURES F5.1–F5.6 |
| 依赖 | F1.4/F1.6（参数字段与解析模型） |
| 被依赖 | F4（spec_diff 技能） |
| 里程碑 | M3 |

## 1. 概述

两份规格书（PDF/Word）自动字段级对比：同模板做字段 Diff，跨模板由 AI 做字段语义映射（PRD §21：Nominal Capacity ≈ Rated Capacity ≈ Typical Capacity）；差异带重要性分级与 AI 总结；人工确认后的映射沉淀复用。验收 KPI：文档比对时间 ↓ ≥ 80%。

## 2. Feature Units

### F5.1 同模板字段级 Diff

- **FR5.1.1** 输入：两份已 `PARSE_CONFIRMED` 的文档（A/B），可各自选择文档版本。
- **FR5.1.2** 字段对齐：参数键归一化后精确匹配（忽略大小写、全半角、空白、单位写法差异）；匹配不上的键进入 F5.2 跨模板流程。
- **FR5.1.3** 输出行结构：`{参数, A值(含单位/原文), B值(含单位/原文), 差异类型(值差异/仅A有/仅B有/单位差异), 等级}`；数值型计算相对偏差 `Δ%`。
- **FR5.1.4** 每行可定位：点击参数名高亮 A/B 文档中的来源字段（复用 F1 的 `source_block_id` → 页码/bbox）。
- **AC5.1.1** 人工标注差异集（3 组真实规格书对）上，系统差异召回率 ≥ 95%（初版目标，见 Q2）。

### F5.2 跨模板 AI 语义映射

- **FR5.2.1** 候选映射生成：未匹配键与对方键做嵌入相似度召回 top3 + LLM 判断同义性，输出映射建议及理由。
- **FR5.2.2** 映射建议呈现在独立"映射确认区"，人工逐条 确认/拒绝；未经确认的映射不参与最终 Diff 结论。
- **FR5.2.3** 确认的映射写入映射库：`{key_a, key_b, scope(global/模板族), confirmed_by, confirmed_at}`。
- **FR5.2.4** 后续对比先查映射库自动应用，命中行标注"已按历史映射对齐"（可人工解除）。
- **AC5.2.1** 第二次对比相同模板族时，已确认映射自动生效且行上可见标注。

### F5.3 差异重要性分级

- **FR5.3.1** 规则分级（可配置表）：安全相关参数（绝缘/耐压/防爆/温度极限）差异 → 🔴；关键性能（容量/内阻/循环寿命/倍率）→ 🟠；其余 → 🟡；仅单方存在默认 🟡。
- **FR5.3.2** LLM 可建议调整等级（如参数上下文表明其关键性），调整处标注"AI建议"，人工可改。
- **FR5.3.3** 每行分级可人工覆盖，覆盖记录入审计。

### F5.4 AI 差异总结

- **FR5.4.1** 输出结构化总结：`{总体结论, Top差异清单(按等级/偏差排序), 风险提示}`，自然语言，例如"循环寿命存在明显差异（A:500次 vs B:800次，↓37.5%）"。
- **FR5.4.2** 总结仅基于 Diff 数据生成，**禁止引入外部知识**；总结为 [AI] 草稿态，随对比结论走 F10.2 确认流。

### F5.5 对比结果导出

- **FR5.5.1** Excel：Sheet1 差异明细（含等级/偏差/来源页码），Sheet2 映射关系，Sheet3 AI 总结。
- **FR5.5.2** PDF：同内容排版报告；`DRAFT` 态导出自动加"草稿"水印，`APPROVED` 后无水印。

### F5.6 映射关系沉淀

- **FR5.6.1** 映射库管理页：按参数/模板族查询、停用（停用写审计）、查看确认人与时间。
- **FR5.6.2** 映射库初始为空；仅人工确认产生条目，AI 建议永不自动入库。

## 3. 数据模型（核心）

| 实体 | 关键字段 |
| ---- | ---- |
| `spec_diff_run` | id, project_id, doc_a(id+version), doc_b(id+version), status(F10.2), summary(JSONB), created_by |
| `spec_diff_row` | run_id, param_key, value_a, value_b, delta_pct?, diff_type, level(红橙黄), level_source(rule/ai/human), locate_a, locate_b |
| `field_mapping` | key_a, key_b, scope, status(active/disabled), confirmed_by, confirmed_at |

## 4. API 概要

```
POST /api/v1/spec-diff/runs              # 发起对比（异步，返回 task_id）
GET  /api/v1/spec-diff/runs/{id}         # 总览 + 总结
GET  /api/v1/spec-diff/runs/{id}/rows    # 差异明细（筛选：等级/类型）
POST /api/v1/spec-diff/runs/{id}/mappings/confirm   # 批量确认映射
POST /api/v1/spec-diff/runs/{id}/confirm # 结论定版（F10.2）
POST /api/v1/spec-diff/runs/{id}/export  # excel/pdf
```

## 5. 横切接入（F10）

- **状态机**：对比结论（含 AI 总结）`DRAFT → APPROVED`；定版后差异分级锁定。
- **审计**：`specdiff.run / mapping.confirmed / mapping.disabled / level.overridden / run.confirmed`，记录模型与 prompt 版本、映射库版本。
- **KPI**：`specdiff.start → specdiff.export` 耗时（对照人工基线，验收 ↓80%）。

## 6. 非目标

合同/招标书类非结构文本比对、双文档版式视觉比对（像素级）、批量多文档两两对比矩阵。

## 7. 开放问题

- **Q1** 安全/关键参数清单与分级规则表由业务专家提供初版。
- **Q2** 差异召回率验收目标值与标注集规模。
- **Q3** 映射库 scope 粒度：Phase 1 先 global + 手动模板族，是否需要按客户/产品线自动分域。
