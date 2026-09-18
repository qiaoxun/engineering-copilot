# F2 企业知识库 — 任务清单（Tasks）

| | |
| ---- | ---- |
| Feature | F2-knowledge-base |
| 输入 | specs/F2-knowledge-base.md、specs/F2-knowledge-base.clarifications.md（C-Q1–Q4）、specs/F2-knowledge-base.plan.md（冲突时以后两者为准）、specs/README.md |
| 关联 | specs/F10-platform-governance.tasks.md（M1 骨架为前置）、specs/F1-document-parsing.tasks.md（解析管线为前置）、specs/F3-rag-retrieval.tasks.md（ingestion 契约对端） |
| 阶段 | speckit-tasks |
| 粒度约定 | 每条任务 0.5–2 人日；超过 2 人日须继续拆分 |
| 前置 | F10 M1 骨架（对象模型/BaseEntity、审计写入通道、require_perm、`/api/v1/tasks` SSE）与 F1 上传/解析管线已就绪；F3 ingestion 以桩实现参与本 feature 集成测试，真实 ingestion 属 F3 任务清单 |

> 依赖列格式：依赖的任务号。编号即执行顺序（可并行：T04/T05/T06 相互独立；T08 与 T04–T06 后半段可并行）。

---

## 任务清单

### T01 F2 接入点骨架：审计事件定义、状态机接线、权限点、KPI/kb_version 契约

- **目标**：一次性定义 F2 挂接 F10 的接入点——① 审计事件常量：`document.uploaded / version.created / deleted / acl.changed / recommended / category.updated / tag.created / kb.revision_applied`（FR2 §5、FR10.3.3 `<domain>.<verb>` 命名）；② 状态机接线：确认 `documents.state` Phase 1 **不注册** transition 配置（spec §6 非目标、plan A10，仅预留接入位）；③ 权限点清单 `kb.upload / kb.edit / kb.manage_taxonomy / kb.delete / kb.visibility`（FR2.6.1、spec §5 分类树管理挂 AI管理员）；④ KPI：无独立 KPI 事件，但落地 `kb_version_service.current()` 契约（`kb_revisions` 为唯一事实源，specs/README 数据契约、FR10.3 审计"知识库版本"字段来源）。同时登记本 feature 错误码（`DUPLICATE_CONTENT/NAME_CONFLICT/PRECHECK_STALE/CATEGORY_REQUIRED/CATEGORY_DEPTH_EXCEEDED/CATEGORY_FIXED/CATEGORY_IN_USE/DOCUMENT_HAS_REFERENCES`，plan §3.2）。
- **涉及文件/模块**：`apps/backend/app/modules/platform/audit/events.py`（F2 事件段追加）、`app/modules/kb/constants.py`（权限点/错误码）、`app/modules/kb/kb_version.py`（服务接口声明）、`app/modules/platform/workflow/configs.py`（F2 无注册项的显式注释）
- **完成标准**：事件/权限/错误码常量表与 spec §5、FR2.6.1、plan §2.4/§3.2 逐条对应并有单元断言；`kb_version_service` 接口契约测试（当前值读取、并发登记串行化语义，A5）；状态机无 F2 注册项的架构测试（防误加审批流）
- **依赖**：无（复用 F10 M1 已有 T01 常量骨架）
- **粒度**：0.5 天

### T02 F2 数据模型 + 迁移 + 种子数据

- **目标**：`documents` F2 增量可空列（`name/current_version/visibility/deleted_at/delisted_by/delist_reason`，FR10.1.4 只增不删）；新表 `document_versions`（UNIQUE(document_id,version)、sha256 非唯一索引、ingest_state，A9/C-Q3/C-Q4）、`categories`（depth≤3 CHECK、is_fixed）、`document_categories`/`document_projects`/`tags`/`document_tags`、`kb_revisions`（kb_version UNIQUE 严格递增、只追加，plan §2）。种子化 7 个固定顶级分类（FR2.2.1）。Alembic 迁移 + 注册 OBJECT_REGISTRY。
- **涉及文件/模块**：`app/modules/kb/models.py`（documents 扩展 + 新表）、`alembic/versions/*`、`app/modules/kb/seeds.py`、`app/modules/platform/objects/registry.py`
- **完成标准**：迁移可上下执行且仅新增可空列/新表（FR10.1.4 checklist）；种子后 7 顶级分类 `is_fixed=true` 断言；document_versions 并发插入版本号唯一约束生效；ER 集成测试（Document N—N Project、Document N—1 Product 可空、多分类多标签）通过
- **依赖**：T01
- **粒度**：1.5 天

### T03 可见性引擎：Casbin domain 判定 + 查询层谓词（F2.6）

- **目标**：pycasbin domain 模型（`sub, dom=project, obj=document, act`）接入 F10.5 `require_perm` 之下，策略数据源 = F10 `project_members`/`departments`（A6，不做第二套策略存储）；SQL 可见性谓词生成函数（`visibility='COMPANY' OR 项目成员 OR 部门规则 OR created_by=self`）与 Casbin 配置同源；`PUT /api/v1/documents/{id}/visibility`（PROJECT_INHERIT ⇄ COMPANY，emit `document.acl.changed` 含前后值）；直取无权限文档详情返回 403 统一错误体（AC2.6.1）。
- **涉及文件/模块**：`app/modules/kb/visibility/engine.py`、`predicate.py`、`app/modules/kb/api/visibility.py`
- **完成标准**：可见性谓词四分支单元测试；同一谓词函数的单测+集成双重覆盖断言 API 拒绝与查询过滤口径一致（plan A6、FR2.4.3）；COMPANY 覆盖后跨项目可见且审计含前后值（FR2.6.1）；无项目权限用户直取 403 而非 404（AC2.6.1）
- **依赖**：T02
- **粒度**：1.5 天

### T04 两阶段上传 + 去重 + 版本管理（F2.1）

- **目标**：`POST /documents/upload-check`（服务端 SHA-256 全库比对 + 同名检测 → 逐文件 `NEW/DUPLICATE/NAME_CONFLICT`，FR2.1.2/2.1.3）；`POST /documents`（per-file directives `create/link_existing/new_version/skip`，逐文件隔离、坏文件零记录，FR2.1.1，create 联动入 F1 parse 队列）；MinIO 内容寻址 `sha256/<hash>` 共享物理对象（C-Q3）；版本号行级锁分配 + `UNIQUE(document_id,version)`（A9）；`POST /documents/{id}/versions`、`GET /documents/{id}/versions/{v}` 历史查看、`GET /documents/{id}` 版本历史四要素（FR2.1.4）；执行阶段重算 SHA-256 防 directives 过期（`PRECHECK_STALE`，plan 风险表）；审计 `document.uploaded / version.created`。
- **涉及文件/模块**：`app/modules/kb/upload/precheck.py`、`ingest.py`、`app/modules/kb/versions/service.py`、`app/modules/kb/api/documents.py`、`app/modules/kb/api/versions.py`、`app/core/storage.py`
- **完成标准**：批量 50 文件含坏文件 → 逐文件汇总、坏文件零记录、余文件成功（FR2.1.1）；重复上传预检 DUPLICATE 且 existing 信息（文档名/版本/上传人）正确（AC2.1.2）；同名新版本路径版本 +1、v1 上传 v2 后仍可查看（AC2.1.1、FR2.1.4）；link_existing 仅建逻辑记录且 MinIO 对象数不增（C-Q3）；并发双上传同名版本号不重复（A9）；PRECHECK_STALE 用例通过
- **依赖**：T02
- **粒度**：2 天

### T05 分类体系与标签（F2.2）

- **目标**：分类树 service（固定 7 顶级只读、子分类增删仅 AI管理员、树深 ≤3 service+DB 双重校验，FR2.2.1/2.2.2）；文档多分类强制 ≥1（`CATEGORY_REQUIRED`，FR2.2.3）；`GET/POST /api/v1/kb/categories`、`DELETE /kb/categories/{id}`（非固定/无子/无文档才可删）；标签自由创建 + `GET /kb/tags?popular=true` 频次聚合（C-Q1）；审计 `category.updated / tag.created`。
- **涉及文件/模块**：`app/modules/kb/taxonomy/service.py`、`app/modules/kb/api/taxonomy.py`、`app/modules/kb/api/tags.py`
- **完成标准**：第 4 层子分类被拒（CATEGORY_DEPTH_EXCEEDED，FR2.2.2）；固定分类删除/改建被拒（CATEGORY_FIXED，FR2.2.1）；有文档关联分类删除被拒（CATEGORY_IN_USE）；无 ≥1 分类的文档入库被拒（FR2.2.3）；非 AI管理员调分类写接口 403（spec §5）；常用标签按频次排序返回（C-Q1）
- **依赖**：T02
- **粒度**：1 天

### T06 文档↔项目/产品/分类/标签关联管理（F2.3）

- **目标**：`PUT /api/v1/documents/{id}/links` 批量更新项目（M2M）/产品（N—1 可空）/分类/标签关联（FR2.3.1）；列表页"未关联项目"筛选（plan 风险表治理项）；关联变更联动可见性重算（T03 谓词）。
- **涉及文件/模块**：`app/modules/kb/links/service.py`、`app/modules/kb/api/links.py`
- **完成标准**：批量更新契约测试（部分失败整体回滚、统一错误体）；关联变更后可见性谓词即时生效（无权限文档立即从他人列表消失，FR2.3.2/FR2.6.1）；未关联项目筛选返回正确集合
- **依赖**：T02、T03
- **粒度**：0.5 天

### T07 生命周期：软删除/下架 + 事件发布 + kb_revision 登记（A4/A5）

- **目标**：`GET /documents/{id}/references`（实时查询 `object_source_link` + FMEA/报告外键，C-Q2 Assumptions）；`DELETE /documents/{id}`（`references_ack` 确认标记，无确认返回 `DOCUMENT_HAS_REFERENCES` + 引用方列表，FR2.1.5）；软删除 = 全通道下架（`deleted_at` 置位 → 搜索/推荐/RAG 召回排除，对象/版本/引用记录保留，C-Q2）；进程内 domain event `document.ingestable / superseded / delisted`（A5）+ `kb_revision_service.record()` 幂等回调（以 ingestion 任务 id 去重）+ 对账任务骨架（plan 风险表）；审计 `document.deleted / kb.revision_applied`。
- **涉及文件/模块**：`app/modules/kb/lifecycle/service.py`、`events.py`、`app/modules/kb/kb_version.py`（实现）、`app/modules/kb/api/lifecycle.py`、`app/worker/tasks/kb_reconcile.py`
- **完成标准**：有引用删除无确认被拒且列表完整（FR2.1.5）；确认后搜索/推荐/模拟 F3 召回三通道均不可见、详情与版本历史仍可查（AC2.1.1、C-Q2）；删除触发 kb_revision(DELIST) 且 kb_version+1（A5）；回调重放幂等（kb_version 不重复递增）；任何角色无物理删除入口（C-Q2，测试断言无物理删除代码路径）
- **依赖**：T04
- **粒度**：1.5 天

### T08 全文搜索与组合筛选（F2.4）

- **目标**：zhparser 扩展接入 + `zhcfg` text search configuration + 工程自定义词典随部署产物（C-Q1，F2.4 与 F3.1.3 共用，A7）；`GET /documents/search?q=`（中文分词全文检索 + 分类/项目/时间/标签/上传人组合筛选，FR2.4.1）；`ts_headline` 命中片段高亮 + 相关度/更新时间双排序（FR2.4.2）；查询层注入 T03 可见性谓词（FR2.4.3）；`GET /documents` 列表与 `GET /documents/recent`（FR2.5.1）；降级预案（default 配置 + 应用层分词，plan 风险表）以配置开关形式落地。
- **涉及文件/模块**：`app/modules/kb/search/service.py`、`app/modules/kb/api/search.py`、`deploy/pg/init_zhparser.sql`、`deploy/pg/dict/zhparser.custom_dict`
- **完成标准**：中文 query（含自定义词典词）命中断言；五维组合筛选 + 高亮 + 双排序集成测试（FR2.4.1/2.4.2）；无项目权限用户搜索结果不含该文档且直取 403（AC2.6.1、FR2.4.3——SQL 层过滤断言，非前端隐藏）；recent 仅返回可见范围变更（FR2.5.1）；分词冒烟用例纳入上线检查表（FR2.6.2）
- **依赖**：T03
- **粒度**：1.5 天

### T09 最近更新 + AI 推荐与金标评测（F2.5）

- **目标**：项目上下文向量聚合（current_version chunk 嵌入加权 + 时间衰减）+ 项目元信息关键词通道 → 候选池排除本项目/下架/权限过滤 → 向量+关键词 RRF 融合 top-N（A8，无生成式 LLM）；`GET /projects/{id}/recommendations` 返回 `{document, reason:{source_document_id, matched_snippet, shared_theme_terms, source_project}, evidence}`（FR2.5.2/2.5.3）；冷启动返回空列表 + 提示；推荐调用 emit `document.recommended`（含 kb_version、算法版本）；金标推荐集 `golden_set_rec_v1`（≥20 对，含密封结构→密封失效金标项）离线评测脚本 Recall@N/MRR，门槛 Recall@5 ≥ 60%（AC2.5.1）。
- **涉及文件/模块**：`app/modules/kb/recommend/context.py`、`fusion.py`、`service.py`、`app/modules/kb/api/recommend.py`、`app/modules/kb/recommend/eval/golden_set_rec_v1.json`、`eval/run_eval.py`、`app/modules/platform/audit/`（emit 接入）
- **完成标准**：金标场景抽验通过（密封结构项目推荐出其他项目密封失效案例，AC2.5.1）；候选池排除本项目与 `SUPERSEDED/DELISTED` 版本断言（C-Q2/C-Q4）；冷启动空列表不报错；reason 三要素与 evidence 一致性 100% 可核验（确定性生成，plan §4）；权限谓词在推荐结果生效（FR2.4.3）；离线评测脚本可重复运行并输出 Recall@5/MRR
- **依赖**：T03、T07、T08（复用分词配置与融合器桩；F3 真实嵌入到位前以嵌入桩跑通）
- **粒度**：2 天

### T10 ingestion 契约与权限矩阵集成测试（F2×F3×F10）

- **目标**：以 F3 ingestion 桩订阅 F2 事件：`document.ingestable → 桩完成 → kb_revision(INGEST)+1`；新版本 `PARSE_CONFIRMED → 桩置旧版 superseded → kb_revision(SUPERSEDE)`；断言事件/回调顺序与 kb_version 严格递增、下游可读 `GET /api/v1/kb/version`（A5、C-Q4、specs/README 契约）；5 角色 × 文档操作参数化权限矩阵测试（view/upload/edit_category/manage_taxonomy/delete/visibility，与 role_permissions 种子同源，spec §5）。
- **涉及文件/模块**：`apps/backend/tests/integration/test_kb_ingestion_contract.py`、`tests/integration/test_kb_permission_matrix.py`
- **完成标准**：ingestion 契约三场景（INGEST/SUPERSEDE/DELIST）全绿且 kb_version 单调（FR3.1.1/3.1.2 契约侧、C-Q4）；权限矩阵全绿且分类树管理仅 AI管理员（spec §5、FR2.6.1）；失败任务可重触发且 kb_revision 不重复（A5 幂等）
- **依赖**：T03、T04、T07
- **粒度**：1 天

### T11 前端 KB 页面（上传向导、详情、分类树、搜索、推荐卡片）

- **目标**：`pages/kb` 文档列表/组合筛选/未关联项目筛选；`features/uploader` 批量上传向导（逐文件进度与结果汇总、DUPLICATE 去重提示、NAME_CONFLICT 新版本/独立文档三选一对话框、项目关联留空警示）；详情页版本历史（四要素 + 历史版本查看）与删除二次确认（引用方列表展示）；`pages/kb/taxonomy` 分类树管理（固定顶级不可删/不可建，AI管理员可见）；`features/search` 高亮渲染；`features/recommend` "与当前项目相关的历史案例 N 个"卡片（理由三要素展示 + 点击进详情，UI 页面01/22）。
- **涉及文件/模块**：`apps/frontend/src/pages/kb/*`、`pages/kb/taxonomy/*`、`features/uploader/*`、`features/search/*`、`features/recommend/*`
- **完成标准**：组件测试——坏文件不阻断批次且逐文件结果正确（FR2.1.1）、去重提示与三选一对话框（AC2.1.2、FR2.1.3）、版本历史展示 v1/v2（AC2.1.1）、删除确认需展示引用列表（FR2.1.5）、固定分类无新建入口（FR2.2.1）、搜索高亮渲染（FR2.4.2）、推荐卡片展示推荐理由并可进详情（FR2.5.3）；无权限按钮仅隐藏不复制逻辑（A6）
- **依赖**：T04、T05、T06、T07、T08、T09
- **粒度**：2 天

### T12 端到端验收（覆盖 F2 全部 AC）

- **目标**：演示环境全链路验收：登录 → 批量上传（含坏文件/重复文件/同名不同文件三路径）→ 解析回读（F1 task SSE）→ 分类/标签/项目关联治理 → 中文搜索+高亮+组合筛选 → 权限矩阵回归（无权限 403 与搜索不可见，AC2.6.1）→ 删除引用确认与全通道下架 → kb_version 递增可查（`GET /kb/version`）→ 推荐金标抽验（AC2.5.1）→ 前端全流程走查 → 私有化检查：外呼清单=空自检报告（FR2.6.2，zhparser/词典/嵌入本地化项核对）。产出验收核对单逐项勾稽。
- **涉及文件/模块**：`apps/backend/tests/e2e/test_f2_acceptance.py`、F2 验收核对单（`specs/` 下 F2 验收记录）
- **完成标准**：以下 AC 全部通过——AC2.1.1（v1/v2 历史保留可查）、AC2.1.2（去重提示正确）、AC2.5.1（金标推荐抽验 Recall@5 ≥ 60%）、AC2.6.1（API 层 403 而非前端隐藏）；并以用例覆盖 FR2.1.1/2.1.4/2.1.5、FR2.2.1–2.2.3、FR2.3.1/2.3.2、FR2.4.1–2.4.3、FR2.5.1–2.5.3、FR2.6.2；新增模块行覆盖率 ≥80%（全局规则）
- **依赖**：T10、T11
- **粒度**：1 天

---

## 任务依赖图

```text
T01 → T02 ─┬→ T03 ─┬→ T06 ─┐
           │       ├→ T08 ─┼→ T09 ─┐
           ├→ T04 ─┴→ T07 ─┤       ├→ T10 ─┐
           ├→ T05 ─────────┘       │       ├→ T12
           └─────── T04/T05/T06 可并行 ┘       │
                        T11（依赖 T04–T09）────┴→ T12
```

并行建议：T04 / T05 / T06 互不依赖可并行；T08 与 T04–T06 后半段可并行（仅依赖 T03）；T09 与 T10 可并行。

---

## Breakdown 决策与假设（Clarifications / Assumptions）

- **[D1] F3 依赖边界（T09/T10）**：F2.5 推荐与 A5 ingestion 回调语义上依赖 F3 chunk/嵌入，但 F3 属同里程碑并行开发。决策：T09/T10 以**嵌入桩 + ingestion 桩**（实现同一进程内事件回调接口）完成 F2 侧全部逻辑与测试；F3 落地时以真实 ingestion 回归 T10 三场景与 AC2.5.1 金标评测。理由：解除 M2 内部阻塞，契约已由 `document.ingestable/superseded/delisted` 事件 + `kb_revision_service.record()` 回调接口钉死。
- **[D2] 金标评测样本采集（T09）**：`golden_set_rec_v1`（≥20 对）标注为上线前与业务方联合活动，任务内先以内部语料构造金标集跑通评测管线与门槛脚本；业务标注版作为 M2 Exit 前置检查项（沿用 F10 [D3] 模式）。
- **[D3] 私有化自检报告归属（T12）**：FR2.6.2 检查表跨 F1（OCR/解析）/F3（嵌入）/F2（zhparser+词典/存储），本清单仅在 T12 验收中核对 F2 范围项并汇总《外呼清单=空》报告；跨 feature 汇总版属发布流程，不单列任务。
- **[D4] `GET /documents/recent` 归属（T08 而非 T09）**：FR2.5.1 最近更新是纯查询（可见范围 + 时间排序），无 AI 依赖，归入 T08 搜索/列表查询同批实现；T09 专注 FR2.5.2/2.5.3 推荐。spec §4 未单列 recent 端点，按 plan §3.1 补充。
- **[D5] 任务粒度校验**：拆解结果 12 条 ≤ 15 条上限，plan 粒度合格，无需回改 plan。
