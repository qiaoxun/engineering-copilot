# F4 AI Chat / AI助手 — Feature Spec

| | |
| ---- | ---- |
| 编号 | F4 |
| 来源 | PRD §7、§7.3、§52；UI 页面01 + 右侧Copilot；PHASE1_FEATURES F4.1–F4.5 |
| 依赖 | F1–F3（知识检索技能）、F5–F9（其余技能入口）、F10.1（Task 对象） |
| 被依赖 | —（工作台统一入口） |
| 里程碑 | M2 |

## 1. 概述

工作台统一入口："告诉AI你要做什么"。对话框负责意图识别并路由到 Phase 1 六个技能；长耗时任务以 AI 任务卡形式异步执行并推送进度（PRD §7.3 / §52）。

## 2. Feature Units

### F4.1 对话框与文件上传

- **FR4.1.1** 输入框支持自然语言 + 文件上传；上传文件经 F1 解析后进入当前会话上下文（如"对比这两个文件"）。
- **FR4.1.2** CAD 扩展名（`stp/step/dwg/dxf/ipt/sldprt` 等）可上传但即时提示："Phase 1 暂不支持 CAD 文件解析，文件已保存到项目文档（存档）"。
- **FR4.1.3** 消息类型：`text / file / task_card / system_notice`；历史消息持久化、可回溯。

### F4.2 意图识别与路由

- **FR4.2.1** 意图分类器（LLM，结构化输出）：输入消息 + 会话上下文 → 七类之一：`spec_diff / bom_diff / fmea_gen / testcase_gen / report_gen / knowledge_qa / general_chat`。
- **FR4.2.2** 置信度 < 0.6 时反问澄清，并给出候选意图按钮（如"你是想做【规格书对比】还是【BOM比对】？"）。
- **FR4.2.3** 路由成功后显示系统消息"已为您启动【规格书对比】"，用户可点击切换意图重新路由。
- **FR4.2.4** 技能所需参数不足时在对话内引导补齐（例：spec_diff 缺文件 → 提示选择或上传两份规格书；缺项目 → 提示先绑定项目）。
- **FR4.2.5** `knowledge_qa` 直接复用 F3；`general_chat` 仅闲聊/平台使用咨询，不产出业务对象。
- **AC4.2.1** 金标指令集（每意图 ≥20 条表述）路由准确率 ≥ 90%（初版目标，见 Q2）。

### F4.3 项目上下文绑定

- **FR4.3.1** 新会话必须先选择项目（Copilot 侧边栏继承当前页面所在项目）；顶部常显当前项目。
- **FR4.3.2** 会话期间产生的所有任务、对象自动挂到该项目；切换项目即新开会话。
- **FR4.3.3** 无项目权限的用户无法在对应项目下发起会话任务。

### F4.4 AI 任务卡

- **FR4.4.1** 卡片字段：任务名、任务类型、状态（`排队中/执行中(进度%)/成功/失败/已取消`）、风险统计（任务类型支持时展示，如 BOM 差异数/高风险数）、后续动作按钮区。
- **FR4.4.2** 后续动作按技能配置（点击即跳转对应工作台并预填上下文）：

| 技能 | 后续动作 |
| ---- | ---- |
| spec_diff | 查看对比报告 |
| bom_diff | 查看差异明细 / 生成FMEA（差异转入F7输入）/ 创建整改任务 |
| fmea_gen | 查看/编辑 FMEA |
| testcase_gen | 查看用例集 |
| report_gen | 查看报告 / 创建问题单 |
| knowledge_qa | （无卡片，直接回答） |

- **FR4.4.3** 失败卡片显示失败原因码 + "重试"按钮；取消中的任务可被用户主动取消。
- **AC4.4.1** 发起 BOM 比对后，卡片在对话流中出现并实时更新进度直至完成，动作按钮可用。

### F4.5 异步任务与进度通知

- **FR4.5.1** 生成/比对/解析类全部异步：创建 `Task` → Celery 队列 → SSE（`/tasks/{id}/events`）推送进度 → 完成后更新任务卡。
- **FR4.5.2** 简单问答与知识检索走同步流式响应，首 token 时间 P95 ≤ 5s（PRD §52）。
- **FR4.5.3** 用户离开页面任务继续执行；回到会话时自动刷新任务卡状态（未读完成数提示）。
- **FR4.5.4** 单用户并发任务上限（默认 3，可配置），超出排队并提示。
- **AC4.5.1** 发起 FMEA 生成后关闭浏览器，5 分钟后回来任务已完成且卡片状态正确。

## 3. 数据模型（核心）

| 实体 | 关键字段 |
| ---- | ---- |
| `chat_session` | id, project_id, user_id, title?, created_at |
| `chat_message` | session_id, seq, role(user/assistant/system), type, content, payload(JSONB: file refs / task_card) |
| `task` | id, session_id?, project_id, type(6技能+parse), status, progress, result_ref(对象id), error_code?, created_by —— F10.1 统一对象 |

## 4. API 概要

```
POST /api/v1/chat/sessions                  # 创建会话（绑定项目）
POST /api/v1/chat/sessions/{id}/messages    # 发消息（同步技能SSE返回；异步技能返回task_id）
GET  /api/v1/tasks/{id}/events              # SSE 进度
POST /api/v1/tasks/{id}/cancel
POST /api/v1/chat/upload                    # 会话内文件上传（含CAD拦截提示）
```

## 5. 横切接入（F10）

- **审计**：`chat.message`（含路由结果与置信度）、`task.created/canceled`；各技能执行由其自身模块审计。
- **权限**：F4.3.3 项目级权限校验；技能入口复用各功能模块的权限点。
- **KPI**：`chat.first_token`、`route.accuracy`（金标集回归）、`task.duration`（按类型）。

## 6. 非目标

多模态输入（语音/图片理解）、跨系统自主执行（Phase 4）、CAD 解析、会话分享。

## 7. 开放问题

- **Q1** 任务卡"风险统计"各技能的取数字段需与 F5–F9 spec 对齐（本稿已在各文档定义）。
- **Q2** 意图路由准确率目标与金标集维护机制（建议：线上低置信样本回流金标集）。
- **Q3** Copilot 是否需要全页面常驻（UI_GUIDE 页面01 为首页独立区 + 右侧Copilot 两种形态，需 UI 定稿）。
