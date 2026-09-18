# Phase 1 Feature Specs

PHASE1_SPEC.md / PHASE1_FEATURES.md 中 F1–F10 的详细功能规格。每份 Spec 面向开发可直接拆任务：需求编号、数据模型、API 概要、横切接入、验收标准。

## 索引

| 文件 | Feature | Feature Units | 里程碑 |
| ---- | ---- | ---- | ---- |
| [F1-document-parsing.md](./F1-document-parsing.md) | 文档解析引擎 | F1.1–F1.6 | M1 |
| [F2-knowledge-base.md](./F2-knowledge-base.md) | 企业知识库 | F2.1–F2.6 | M2 |
| [F3-rag-retrieval.md](./F3-rag-retrieval.md) | AI知识检索（RAG） | F3.1–F3.5 | M2 |
| [F4-ai-chat.md](./F4-ai-chat.md) | AI Chat / AI助手 | F4.1–F4.5 | M2 |
| [F5-spec-comparison.md](./F5-spec-comparison.md) | 规格书智能对比 | F5.1–F5.6 | M3 |
| [F6-bom-comparison.md](./F6-bom-comparison.md) | BOM智能比对 | F6.1–F6.6 | M3 |
| [F7-fmea-generation.md](./F7-fmea-generation.md) | AI FMEA生成 | F7.1–F7.6 | M4 |
| [F8-test-case-generation.md](./F8-test-case-generation.md) | 测试需求与用例生成 | F8.1–F8.6 | M4 |
| [F9-test-report.md](./F9-test-report.md) | 测试报告生成 | F9.1–F9.6 | M4 |
| [F10-platform-governance.md](./F10-platform-governance.md) | 工程确认与追溯机制（横切） | F10.1–F10.6 | M1骨架，随M2–M4落地 |

## 全文约定

### 编号
- **需求** `FR<x.y.n>`：x.y 对应 Feature Unit，n 为需求序号。需求必须可测试。
- **验收** `AC<x.y.n>`：对应需求或 Feature Unit 的验收条款。
- **开放问题** `Q<编号>`：需产品/架构拍板的事项，各文档末尾汇总，不阻塞开发启动。

### API
- REST，前缀 `/api/v1`，JSON；资源名复数。分页 `?page=&page_size=`，返回 `{items, total, page}`。
- 统一错误体：`{"code": "MACHINE_READABLE_CODE", "message": "人类可读原因", "detail": {...}}`。
- 异步任务：所有生成/比对/解析类操作返回 `task_id`；进度经 `GET /api/v1/tasks/{id}/events`（SSE）推送；任务状态机 `QUEUED/RUNNING/SUCCESS/FAILED/CANCELED`。
- ID 统一 UUIDv7；时间 UTC ISO-8601。

### 通用平台语义（详见 F10）
- 所有 AI 生成物创建即 `DRAFT` 态；`APPROVED`（定版）只能由具备定版权限的人工操作触发；**任何 API 都不允许 AI 输出直接写 APPROVED**。
- 所有 AI 操作必须产生审计事件，携带 prompt 版本、模型标识、kb_version、引用数据。
- 需求中标注 **[AI]** 的输出均为草稿性质，UI 必须带 AI 标识。

### 数据契约
- **统一解析模型**（F1.6）是全平台唯一文档数据入口，`parse_schema_version` 版本化；下游 F2/F5/F6/F7/F8 禁止绕过它自行解析。
- **kb_version**：知识库逻辑版本号，每次 RAG ingestion 生效变更 +1；审计日志记录当时值。

### 术语
| 术语 | 含义 |
| ---- | ---- |
| 解析模型 | F1.6 定义的 Document → Sections → Blocks/Tables → Fields 结构 |
| 低置信度 | 解析元素 confidence < 阈值（默认 0.85），UI 标红待人工校对 |
| 定版 | 对象经人工确认进入 APPROVED 终态 |
| 处置 | 人工对差异/AI建议作出 确认/忽略/转任务 的动作 |
| 映射库 | F5 跨模板字段语义映射的持久化存储 |
