# F3 AI知识检索（RAG问答）— 任务清单（Tasks）

| | |
| ---- | ---- |
| Feature | F3-rag-retrieval |
| 输入 | specs/F3-rag-retrieval.md、specs/F3-rag-retrieval.clarifications.md（C-Q1–Q4）、specs/F3-rag-retrieval.plan.md（冲突时以后两者为准）、specs/README.md |
| 关联 | specs/F1-document-parsing.tasks.md（统一解析模型为前置）、specs/F2-knowledge-base.tasks.md（ingestion 事件/可见性谓词/zhcfg 为前置）、specs/F10-platform-governance.tasks.md（M1 骨架为前置）、specs/F7-fmea-generation.md（object_source_link 消费对端） |
| 阶段 | speckit-tasks |
| 粒度约定 | 每条任务 0.5–2 人日；超过 2 人日须继续拆分 |
| 前置 | F10 M1 骨架（LLMGateway/prompt_registry/审计通道/require_perm/kpi_events/KPI SQL 视图）、F1.6 统一解析模型读视图（`GET .../parse`）、F2 事件 `document.ingestable/superseded/delisted` + 可见性谓词生成函数 + `zhcfg` 分词配置 + kb_revision_service 已就绪 |

> 依赖列格式：依赖的任务号。编号即执行顺序（可并行：T03/T04/T07/T08 相互独立；T10 与 T11 后半段可并行）。

---

## 任务清单

### T01 F3 接入点骨架：审计事件定义、状态机接线、权限点、KPI 埋点

- **目标**：一次性定义 F3 挂接 F10 的接入点——① 审计事件常量：`rag.query / rag.no_hit / rag.link.created / rag.link.deleted / rag.threshold.updated`（spec §5、FR10.3.3 `<domain>.<verb>` 命名；`rag.query` 字段契约：query/改写后 query/模型与 prompt 版本/kb_version/citations[]/citations_dropped/no_hit/gray_zone/include_superseded 开关状态，即「AI引用准确率可抽样审计」KPI 数据源，C-Q2）；② 状态机接线：确认 RAG 答案为即时交互产物，`rag_conversations/rag_messages` **不注册** transition 配置（plan §2.5，仅预留接入位）；③ 权限点清单 `rag.query / rag.link.manage / rag.config.manage`（plan §2.5，config 仅 AI管理员，C-Q4）；④ KPI 埋点契约：`rag.first_token`（duration_ms，P95 ≤ 5s）、`rag.no_hit`、`rag.feedback` 注册进 F10 KPI SQL 视图（FR10.6.1）。同时登记本 feature 错误码（`QUERY_EMPTY/QUERY_TOO_LONG/CONVERSATION_NOT_FOUND/MESSAGE_NOT_FOUND/LINK_TARGET_NOT_FOUND/LINK_DUPLICATE/RAG_CONFIG_FORBIDDEN`，plan §3.2）与 prompt 注册表条目骨架 `f3.rag_answer / f3.query_rewrite`（FR10.3.4，禁裸字符串）。
- **涉及文件/模块**：`apps/backend/app/modules/platform/audit/events.py`（F3 事件段追加）、`app/modules/rag/constants.py`（权限点/错误码）、`app/modules/platform/kpi/views.sql`（三个 KPI 视图段）、`app/modules/platform/prompts/registry.py`（f3.* 条目）、`app/modules/platform/workflow/configs.py`（F3 无注册项的显式注释）
- **完成标准**：事件/权限/错误码/prompt 常量表与 spec §5、plan §2.5/§3.2 逐条对应并有单元断言；三个 KPI 事件写入 kpi_events 后可被 SQL 视图聚合（`rag.first_token` 分位数查询冒烟）；状态机无 F3 注册项的架构测试（防误加审批流，plan §2.5）
- **依赖**：无（复用 F10 M1 已有 T01 常量骨架）
- **粒度**：0.5 天

### T02 F3 数据模型 + 迁移

- **目标**：新表 `chunks`（VECTOR(1024) + HNSW cosine 索引、`tsv` GENERATED 列（zhcfg）+ GIN 索引、`kb_version`、`superseded/delisted`、`embed_model`、`ingest_task_id`、幂等 `UNIQUE(doc_id, doc_version, chunk_index)`、召回主路径部分索引 `WHERE superseded=false AND delisted=false`，plan §2.1）；`rag_conversations / rag_messages`（继承 BaseEntity，sources/citations_dropped JSONB、no_hit/gray_zone/rewritten_query/feedback 列，plan §2.2）；`object_source_link`（F3.4.2 与 F7.3 共用单表，`UNIQUE(src_type, src_id, document_id, doc_version, page, quote_digest)`，plan §2.3/A8）；`golden_sets` 新增 `kind` 列（DEFAULT 'parse'，FR10.1.4 只增不删，plan §2.4）。Alembic 迁移；pgvector 扩展启用确认。
- **涉及文件/模块**：`app/modules/rag/models.py`、`app/modules/links/models.py`、`alembic/versions/*`、`app/modules/evals/models_ext.py`（golden_sets kind 列）
- **完成标准**：迁移可上下执行且 golden_sets 仅新增可空带默认列（FR10.1.4 checklist）；`UNIQUE(doc_id, doc_version, chunk_index)` 幂等键与 link 防重 UNIQUE 生效断言；HNSW/GIN/部分索引存在性迁移测试；rag_messages BaseEntity 公共列齐备（FR10.1.3）
- **依赖**：T01
- **粒度**：1.5 天

### T03 Ingestion 管线：分块 → 嵌入 → 入库（F3.1 离线通路）

- **目标**：Celery `rag` 队列任务订阅 F2 事件（plan §1.2）：`document.ingestable` → 读 F1 统一解析模型 `GET .../parse` 合并视图（A1，禁自解析）→ 章节感知分块（目标 512 / 上限 1024 token，句子级拆分；表格序列化为「表头: 值」文本行，整表 ≤1024 token 优先整表成块）→ bge-m3 批量嵌入 → chunks 入库（携带 doc_id/doc_version/section_id/page/bbox/kb_version/embed_model）→ 回调 `kb_revision_service.record(INGEST)`；`document.superseded` → 旧版本 chunk `superseded=true` + kb_revision(SUPERSEDE)（FR3.1.2）；`document.delisted` → `delisted=true`（F2 plan A4）。以 `ingest_task_id` + UNIQUE 幂等键去重，任务重触发先删后插、kb_revision 不重复递增。
- **涉及文件/模块**：`app/modules/rag/ingestion/chunker.py`、`embedder.py`、`writer.py`、`ingestion/events.py`、`app/worker/tasks/rag_ingest.py`
- **完成标准**：PARSE_CONFIRMED 事件 → chunk 全字段入库断言（FR3.1.1）；分块器单测（章节边界、512/1024 边界、表格序列化、token 计数）；新版本生效旧版 superseded=true（FR3.1.2）；kb_revision 回调幂等（重触发不重复 +1）；同键重触发不产生重复 chunk；含表格文档序列化正确性集成测试
- **依赖**：T02
- **粒度**：2 天

### T04 混合检索服务：候选池 → 双通道召回 → RRF → 重排 → 阈值带（F3.1/F3.5）

- **目标**：候选池 SQL 层内联 F2 可见性谓词生成函数（A3，同一函数同一配置源——无权限文档 chunk 物理上不进候选池，FR3.1.4）+ `scope: all|project`（FR3.1.5）+ `superseded=false AND delisted=false` 默认谓词 + `include_superseded` 请求级开关（默认 false，true 时放开并强制 source 标注历史版本，C-Q2）；向量通道 top50（pgvector HNSW）∪ 关键词通道 top50（tsv/zhcfg，与 F2.4 同配置，A2）→ RRF（k=60）融合 → bge-reranker-v2-m3 重排 → top-k（默认 8，配置可调，FR3.1.3）；重排分数归一化后阈值带判定：`< no_hit 阈值（锚点 0.30）`→ no_hit 分支、`[0.30, 0.45)` → gray_zone 标记（锚点仅调参起点，C-Q4/A5）；两通道并行执行 + HNSW ef_search 参数化（性能风险缓解）。
- **涉及文件/模块**：`app/modules/rag/retrieval/candidates.py`、`filters.py`、`fusion.py`（RRF）、`reranker.py`、`thresholds.py`、`app/modules/rag/config.py`（运行时配置读取）
- **完成标准**：候选池 SQL 层权限过滤断言——无权限用户的候选池计数不含该文档 chunk（非结果后过滤，FR3.1.4）；scope 两分支（FR3.1.5）；include_superseded=false 默认排除、true 时命中且带版本标记 + 开关状态可入审计（C-Q2）；RRF 融合排序单测（FR3.1.3）；阈值带三分支单测（<0.30 / 0.30–0.45 / ≥0.45，A5）；语义问法走向量通道、料号精确词走 tsvector 通道的集成用例（A2）
- **依赖**：T02
- **粒度**：2 天

### T05 生成与引用后处理：SSE 流式 + quote 校验 + no_hit 兜底（F3.2/F3.5）

- **目标**：`POST /api/v1/rag/query` SSE 端点（A4，同步流式非任务模式）：权限检查 `require_perm("rag.query")` → 输入校验（`QUERY_EMPTY/QUERY_TOO_LONG`）→ T04 检索 → no_hit 时**不调 LLM**、下发固定模板 + 1–2 条改写建议（代码生成非 LLM，FR3.5.1）；灰区时 `meta.gray_zone=true`（FR3.5.2）；正常路径经 LLMGateway 以 `f3.rag_answer` prompt（编号片段 + 引用指令，FR3.2.2）流式生成，事件序列 `meta → answer* → sources → done`，异常以 `error` 事件 + 统一错误体下发（FR3.2.4）；引用后处理校验（A6 代码强制）：citation 的 quote 与 chunk 文本 精确 → 归一化（去空白/标点/全半角/小写）→ rapidfuzz ≥0.85 三级匹配，失败引用剔除 + 答案 `[n]†` 脚注 + `citations_dropped` 落库（FR3.2.3）；sources 组装为 FR3.2.1 全字段结构随流末尾下发；`rag_message` 持久化 + 审计 `rag.query` 全字段 + KPI `rag.first_token`（recall/rerank/llm 分段计时入 meta）与 `rag.no_hit`（FR3.5.3）。
- **涉及文件/模块**：`app/modules/rag/api/query.py`、`generation/prompt.py`、`stream.py`、`citations.py`（抽取/校验/重标）、`app/modules/rag/retrieval/filters.py`（include_superseded 审计接线）
- **完成标准**：SSE 事件序列契约测试 meta→answer*→sources→done（FR3.2.4）；sources 字段完备性（document_id/doc_version/project/uploaded_at/snippet/page/bbox/quote，FR3.2.1）；quote 三级匹配与降级剔除单测（含全半角/标点用例，FR3.2.3）+ citations_dropped 落库断言；no_hit 路径 LLM stub 零调用断言 + 模板与改写建议下发（FR3.5.1）；灰区标记断言（FR3.5.2）；审计 `rag.query` 字段完备性 schema 校验（spec §5、F10 plan §5 同款门槛）；first_token 分段计时埋点断言
- **依赖**：T01、T04
- **粒度**：2 天

### T06 多轮会话：query 改写 + 会话持久化 + 历史 API（F3.3）

- **目标**：`rag_conversations/rag_messages` service（title 首问确定性截取、last_message_at 维护、消息含 sources 最终下发版持久化，plan §2.2）；`f3.query_rewrite` prompt（温度 0，输入最近 N=3 轮 + 当前问题 → 独立完整检索词，A7——检索永远只用改写后查询，历史不进召回；首轮跳过改写以保首 token SLO）；`POST /rag/query` 接入会话上下文；`GET /api/v1/rag/conversations`（分页 + project_id 筛选）与 `GET /conversations/{id}`（含 sources 历史，FR3.3.2）；会话/消息可见性 = 创建人本人 + 项目成员（与 T04 同源谓词，plan §3.2）。
- **涉及文件/模块**：`app/modules/rag/conversation/service.py`、`rewrite.py`、`app/modules/rag/api/conversations.py`、`app/modules/rag/api/query.py`（会话接线）
- **完成标准**：第二轮指代问法触发改写、改写词入 rag_message.rewritten_query 与审计（FR3.3.1）；首轮零改写 LLM 调用断言（A7/SLO）；历史会话恢复后追问上下文正确（FR3.3.2）；会话列表/详情分页信封 `{items,total,page}` 与可见性过滤（无权限会话不可见）；N 轮窗口截断单测
- **依赖**：T02、T05
- **粒度**：1.5 天

### T07 引用关联与反馈：links + feedback（F3.4.2、FR §4）

- **目标**：`POST /api/v1/links`（{src_type, src_id, document_id, doc_version, page?, bbox?, quote}，`rag.link.manage` 权限，src 存在性校验 `LINK_TARGET_NOT_FOUND`、UNIQUE 防重 `LINK_DUPLICATE`，A8）；`GET /api/v1/links?src_type=&src_id=` 目标对象侧"依据"列表（F7.3 只读消费契约）；`DELETE /api/v1/links/{id}`（created_by 本人或项目经理）；审计 `rag.link.created / rag.link.deleted`。`POST /api/v1/rag/feedback`（{message_id, rating: up|down, comment?}）→ kpi_events(`rag.feedback`) + rag_messages.feedback 回填（`MESSAGE_NOT_FOUND`）。
- **涉及文件/模块**：`app/modules/links/api/links.py`、`app/modules/links/service.py`、`app/modules/rag/api/feedback.py`、`app/modules/rag/conversation/service.py`（回填）
- **完成标准**：link 创建/查询/删除集成测试 + UNIQUE 防重与 `LINK_DUPLICATE`（FR3.4.2）；src 不存在返回 `LINK_TARGET_NOT_FOUND` 统一错误体；删除权限矩阵（本人/项目经理可删、他人 403）；F7 消费侧契约测试——fmea_row 侧"依据"列表可读（A8）；feedback 落 kpi_events 且消息回填、`rag.feedback` 可被 KPI 视图聚合
- **依赖**：T02
- **粒度**：1 天

### T08 检索运行时配置：阈值/top_k/轮数（C-Q4）

- **目标**：`PUT /api/v1/rag/config`（AI管理员，`rag.config.manage`）：no_hit 阈值 / 灰区上界 / top_k / 上下文轮数 N，修改 emit `rag.threshold.updated` 审计并记录当时 kb_version（C-Q4）；`GET /api/v1/rag/config`（前端开关/灰区提示带读取）；非 AI管理员写 403 + `RAG_CONFIG_FORBIDDEN`。T04/T05 的阈值读取全部改为经此配置（运行时热读，锚点 0.30/0.45 仅为初始值）。
- **涉及文件/模块**：`app/modules/rag/api/config.py`、`app/modules/rag/config.py`、`app/modules/platform/audit/`（emit 接入）
- **完成标准**：AI管理员修改阈值生效且审计含前后值 + kb_version（C-Q4）；工程师/AI管理员以外角色 PUT 返回 403（权限矩阵测试）；T04 阈值带单测改为参数化驱动（配置值注入而非硬编码，A5）；GET 返回当前生效配置
- **依赖**：T01、T02
- **粒度**：0.5 天

### T09 金标评测与阈值调参：golden_set_rag_v1（C-Q1/C-Q3/C-Q4、A9）

- **目标**：`golden_sets`（kind='rag'）装载 `golden_set_rag_v1`：≥50 条 query-文档对（覆盖密封失效案例/历史DFM问题/料号使用项目三类场景 + 参数表密集文档）+ ≥10 条无答案类（C-Q1）；离线评测脚本分层输出——检索层 Recall@8（AC3.1.1）、端到端引用准确率（AC3.2.1）、无答案类误答率（AC3.5.1 硬门槛）、分场景分项报表、citations_dropped 率；阈值/k/N 网格调参产出 C-Q4 锚点验证报告（报告版本化）；嵌入/重排模型更换回归流程演练（全量复嵌入 + 重跑金标 + 复审阈值，C-Q4 Assumptions）。
- **涉及文件/模块**：`app/modules/rag/evals/`、`evals/rag/golden_set_rag_v1.json`、`eval/run_eval.py`、调参报告（specs/ 下 F3 评测记录）
- **完成标准**：评测脚本对金标集可重复运行并输出三指标报告；金标集就绪后 Recall@8 ≥ 85%、引用准确率 ≥ 90%、误答率 = 0 判定逻辑落地（C-Q1 正式验收目标，非建议值）；无答案类问题全部返回 no_hit 模板（AC3.5.1，端到端断言）；分通道（向量/关键词）贡献度观测输出（zhparser 风险观测，plan §6）；内部自建金标先跑通管线，客户金标延迟不阻塞（C-Q1 Assumptions）
- **依赖**：T03、T05、T06
- **粒度**：2 天

### T10 前端 RAG 对话页：流式答案、角标定位、开关与反馈（UI 页面23）

- **目标**：`pages/rag` 会话列表 + 历史恢复 + 对话区；`features/rag-chat`：流式答案渲染（answer 增量）、`[n]` 角标可点击跳转对应 source 卡片（AC3.2.2）、灰区提示条「以下内容供参考，匹配度较低」（FR3.5.2）、no_hit 模板与改写建议展示（FR3.5.1）、「包含历史版本」开关（include_superseded，默认关闭）+ 历史版本徽标（C-Q2）、点赞点踩（FR §4）、追问输入、scope（全部知识库/当前项目）选择；AI 标识（specs/README 通用语义）。
- **涉及文件/模块**：`apps/frontend/src/pages/rag/*`、`features/rag-chat/*`
- **完成标准**：组件测试——流式渲染增量拼装、角标点击滚动定位 source 卡片（AC3.2.2）、no_hit 模板展示且输入框给改写建议（FR3.5.1）、灰区提示条显隐随 meta.gray_zone（FR3.5.2）、开关默认关闭且开启后命中带历史版本徽标（C-Q2）、点赞点踩调用反馈接口、会话列表恢复历史（FR3.3.2）
- **依赖**：T05、T06
- **粒度**：2 天

### T11 前端原文定位与关联操作（F3.4）

- **目标**：`features/source-card`：四要素展示（文档/项目/时间/片段，FR3.2.1）+ [查看原文] + [关联到当前FMEA][关联到项目]；`features/pdf-viewer`：pdf.js 跳转 `page` + 按 `bbox` 高亮（FR3.4.1，复用 F1 校对视图 bbox 渲染）；`features/parse-snapshot`：Excel/Word 按 `section_id` 经 F1 `GET .../parse` 渲染表格/段落快照（A1 复用 parse-viewer）；关联对话框 → `POST /links`，目标对象（FMEA 行/项目）侧展示"依据"列表（`GET /links`，FR3.4.2）。
- **涉及文件/模块**：`apps/frontend/src/features/source-card/*`、`features/pdf-viewer/*`、`features/parse-snapshot/*`
- **完成标准**：组件测试——PDF 命中跳转正确页并高亮 bbox 区域（FR3.4.1、AC3.2.2 点击链路）；Excel/Word 命中展示对应表格/段落快照；关联对话框提交成功后目标侧"依据"列表出现新条目（FR3.4.2）；重复关联展示 `LINK_DUPLICATE` 提示；无 `rag.link.manage` 权限时关联按钮隐藏（A6 式权限隐藏）
- **依赖**：T07、T10
- **粒度**：2 天

### T12 性能与一致性：首 token SLO 压测 + ingestion 对账（spec §5、plan §6）

- **目标**：10 万 chunk 规模压测——召回+重排+LLM 首 token P95 ≤ 5s（`rag.first_token` KPI，分段计时定位超标段）；HNSW 参数（m/ef_construction/ef_search）与召回率权衡记录入配置；SSE 长连接并发下的连接池/超时/每用户限流（plan 风险表配额控制）；ingestion 对账任务（比对 ingest_state 与 chunk 存在性，偏差告警、任务可重触发，F2 plan A5 风险同源）。
- **涉及文件/模块**：`evals/rag/bench_first_token.py`、`app/worker/tasks/rag_reconcile.py`、`app/modules/rag/config.py`（HNSW/限流参数）、压测报告
- **完成标准**：压测报告显示 P95 ≤ 5s（或附超标段定位与缓解记录）；限流超限返回统一错误体；对账任务对人为制造的 chunk 缺失产生告警且重触发后一致；HNSW 参数记录归档（plan §6 风险闭环）
- **依赖**：T03、T05、T06
- **粒度**：1 天

### T13 端到端验收（覆盖 F3 全部 AC）

- **目标**：演示环境全链路验收：上传文档（F1/F2 前置）→ ingestion 入库 kb_version+1 → 新版本生效旧版不再命中（FR3.1.2）→ 提问（三类典型场景：密封失效案例/历史DFM/料号项目，PRD §36）→ 流式答案带 [n] 角标点击定位原文（AC3.2.2）→ source 卡片 [查看原文] 跳页+bbox 高亮 / Excel 快照（FR3.4.1）→ [关联到当前FMEA] → FMEA 侧可见"依据"（FR3.4.2）→ 多轮追问改写正确（FR3.3.1/3.3.2）→ 无答案类问题返回"未找到"（AC3.5.1）→ 灰区提示（FR3.5.2）→ 无权限用户检索不到无权文档（FR3.1.4）→ include_superseded 开关与历史版本标注（C-Q2）→ AI管理员调阈值入审计（C-Q4）→ 审计 `rag.query` 导出供月度抽样（C-Q3）→ 金标集全量评测出报告（AC3.1.1/AC3.2.1）→ 私有化核对（bge-m3/reranker/LLM 本地化，外呼=空项 F3 范围核对）。产出验收核对单逐项勾稽。
- **涉及文件/模块**：`apps/backend/tests/e2e/test_f3_acceptance.py`、F3 验收核对单（`specs/` 下 F3 验收记录）
- **完成标准**：以下 AC 全部通过——**AC3.1.1**（金标 Recall@8 ≥ 85%）、**AC3.2.1**（金标引用准确率 ≥ 90% 且抽样审计口径可统计）、**AC3.2.2**（每个事实性结论可点击定位原文）、**AC3.5.1**（无答案类 ≥10 条误答率 = 0）；并以用例覆盖 FR3.1.1–3.1.5、FR3.2.1–3.2.4、FR3.3.1/3.3.2、FR3.4.1/3.4.2、FR3.5.1–3.5.3；新增模块行覆盖率 ≥80%（全局规则）
- **依赖**：T09、T10、T11、T12
- **粒度**：1 天

---

## 任务依赖图

```text
T01 → T02 ─┬→ T03 ─────────┐
           ├→ T04 → T05 ─┬─┼→ T06 ─┐
           ├→ T07 ───────┼─┘       ├→ T09 ─┐
           └→ T08 ───────┘         │       ├→ T13
                        T10（依赖 T05/T06）─┴→ T11 ┤
                        T12（依赖 T03/T05/T06）───┘
可并行：T03 / T04 / T07 / T08（仅依赖 T02）；T09 与 T10/T11/T12 可并行
```

并行建议：T03（ingestion）与 T04（检索）互不依赖可并行（T04 单测用夹具 chunk 数据）；T07/T08 独立可随时插入；T10 依赖 T05/T06，T11 依赖 T07/T10；T09 金标评测在 T05/T06 后即可启动，与前端并行。

---

## Breakdown 决策与假设（Clarifications / Assumptions）

- **[D1] 集成测试不单列任务**：F2 清单有独立契约测试任务（T10），本清单将 ingestion 契约、检索权限 SQL 层断言、SSE 事件序列、审计 schema 校验等集成测试**分散进 T03–T08 各自的完成标准**——F3 的跨模块风险点（权限过滤、引用校验、幂等）都已绑定到对应实现任务的验收里，独立测试任务只会重复断言；跨 feature 对端（F2 事件、F7 消费）契约分别在 T03 与 T07 内覆盖。
- **[D2] T04 与 T03 可并行**：检索逻辑开发不依赖真实 ingestion 产出的数据，单测以夹具 chunk 行驱动；两任务在 T09/T12/T13 处汇合做真实语料回归。理由：ingestion（离线）与检索（在线）是 plan §1.1 明确的两条独立通路。
- **[D3] 金标集数据就绪节奏（T09）**：golden_set_rag_v1 双人标注依赖业务方资源（C-Q1 Assumptions），T09 先以内部自建金标集跑通评测管线与三指标判定脚本；客户金标就绪后复测作为 M2 Exit 前置检查项（沿用 F2 [D2] 模式）。AC3.1.1/AC3.2.1 的正式达标判定在 T13 验收核对单中标注「金标版本」。
- **[D4] 嵌入/重排/LLM 以本地推理服务桩起步**：bge-m3/bge-reranker/生成式 LLM 均为私有化部署外部服务（plan §4），开发期以 LLMGateway 桩（确定性返回 + 可注入延迟/漂移引用）跑通全部逻辑与测试；真实模型接入属部署联调，纳入 T12 压测与 T13 验收，不单列任务。
- **[D5] 阈值数值不写入任何任务完成标准**：C-Q4 明确 0.30/0.45 仅为调参起点，故 T04/T08 验收断言的是「阈值带判定逻辑 + 配置化 + 审计化」，数值由 T09 网格调参产出；AC3.5.1（误答率=0）作为数值侧硬门槛在 T09/T13 判定。
- **[D6] 任务粒度校验**：拆解结果 13 条 ≤ 15 条上限，plan 粒度合格，无需回改 plan。
