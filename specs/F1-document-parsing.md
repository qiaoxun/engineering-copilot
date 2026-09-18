# F1 文档解析引擎 — Feature Spec

| | |
| ---- | ---- |
| 编号 | F1 |
| 来源 | PRD §46.3；PHASE1_FEATURES F1.1–F1.6 |
| 依赖 | 无 |
| 被依赖 | F2（入库）、F3（ingestion）、F5/F6（比对输入）、F7/F8（生成输入） |
| 里程碑 | M1 |

## 1. 概述

将 PDF / Word / Excel / 图片（含扫描件）解析为统一结构化内容（F1.6），作为知识库、比对、生成类功能的唯一文档数据入口。解析质量直接决定 §5 KPI 是否可达成，是 Phase 1 的技术地基。

## 2. Feature Units

### F1.1 文件上传与格式校验

- **FR1.1.1** 支持格式：`pdf, docx, doc, xls, xlsx, csv, png, jpg, jpeg, tiff`；其余扩展名拒绝（错误码 `FILE_FORMAT_UNSUPPORTED`）。
- **FR1.1.2** 单文件大小上限默认 100MB（系统配置项），超限拒绝（`FILE_SIZE_EXCEEDED`）。
- **FR1.1.3** 加密/口令保护文件必须在上传时检测并拒绝（`FILE_ENCRYPTED`），不得进入解析队列后静默失败。
- **FR1.1.4** 所有校验失败返回机器可读错误码 + 人类可读原因；失败文件不产生任何业务记录。
- **FR1.1.5** 校验通过即创建 `Document` 记录（解析状态 `PENDING`）并自动触发解析任务。
- **AC1.1.1** 加密 PDF 上传被拒且提示"文件已加密，请提供解密后版本"。
- **AC1.1.2** 批量上传中单个文件校验失败不影响其余文件。

### F1.2 版面与表格结构还原

- **FR1.2.1** PDF 经版面分析输出：章节树、段落块、表格（含表头行识别），每个元素携带 `page / bbox / confidence`。
- **FR1.2.2** 跨页表格自动合并：续页列结构一致且无重复表头时合并为一张表，合并结果标记 `merged_from_pages[]`。
- **FR1.2.3** Word/Excel 走结构化读取（不经过 OCR/版面模型），保留原生层级与表格结构。
- **FR1.2.4** 版面判断存疑（置信度 < 阈值）的表格必须进入 F1.5 人工校对队列，不得静默输出。
- **AC1.2.1** 金标样本中含跨页参数表的文档，表格正确合并且行序保持。
- **AC1.2.2** 双栏排版的规格书正文顺序还原正确率可度量（金标集）。

### F1.3 扫描件 OCR

- **FR1.3.1** 自动判定扫描件（文本层字符密度低于阈值）→ 路由至 OCR 通道；图片类型默认 OCR。
- **FR1.3.2** OCR 输出块级置信度；`confidence < 0.85` 标记 `low_confidence=true`。
- **FR1.3.3** 支持中英文混排；OCR 结果与坐标一并写入解析模型（可定位原文）。

### F1.4 工程参数抽取

- **FR1.4.1** 参数字典驱动，Phase 1 内置 ≥30 类电池工程参数（容量/标称电压/内阻/工作温度/循环寿命/充电倍率/扭矩/公差等），字典可维护（增改参数、同义词）。
- **FR1.4.2** 输出 `fields[]`：`{key, value_raw, value_norm, unit, unit_si, source_block_id, confidence}`；每个字段必须能通过 `source_block_id` 定位到原文。
- **FR1.4.3** 抽取策略：表格键值匹配（规则）优先，段落语义抽取（LLM，结构化输出）兜底；仅当原文存在该值时才允许输出。
- **FR1.4.4** 单位归一（mAh→Ah、℃/K 等），同时保留 `value_raw` 原始表达。
- **AC1.4.1** 金标集（≥30 份真实电池规格书）字段准确率 ≥ 90%（值+单位均匹配计正确）。

### F1.5 解析结果人工校对视图

- **FR1.5.1** 低置信度元素（表格/字段/OCR 块）在解析详情页红色高亮，左侧原文、右侧结构化结果对照。
- **FR1.5.2** 支持人工修正：值、单位、归属章节、表格单元格；修正保存为 `override`，**原始解析结果与修正结果双留存**。
- **FR1.5.3** 校对完成操作将文档置为 `PARSE_CONFIRMED`；校对动作写审计（谁、何时、改了什么）。
- **FR1.5.4** 下游消费方（知识库 ingestion、比对）读取的是修正后结果。
- **AC1.5.1** 修正某字段后，知识库检索命中该文档时展示的是修正值。

### F1.6 统一解析输出模型

- **FR1.6.1** 模型结构（JSON Schema，带 `parse_schema_version`）：

```jsonc
{
  "parse_schema_version": "1.0",
  "document": { "filename": "", "file_type": "pdf", "pages": 12,
                "parser_versions": {...}, "status": "SUCCESS" },
  "sections": [ { "id": "sec-1", "title": "技术参数", "level": 2, "parent": null, "order": 3 } ],
  "blocks":   [ { "id": "blk-1", "type": "paragraph|table", "section_id": "sec-1",
                  "page": 4, "bbox": [x0,y0,x1,y1], "confidence": 0.97,
                  "low_confidence": false, "content": {...} } ],
  "tables":   [ { "id": "tbl-1", "caption": "", "headers": ["项目","参数值"],
                  "rows": [["额定容量","100 Ah"]], "merged_from_pages": [4,5] } ],
  "fields":   [ { "key": "rated_capacity", "value_raw": "100Ah", "value_norm": 100,
                  "unit": "Ah", "unit_si": "A·h", "source_block_id": "blk-7",
                  "confidence": 0.95 } ],
  "warnings": [ { "code": "TABLE_LOW_CONF", "message": "第5页表格置信度低", "location": "blk-9" } ]
}
```

- **FR1.6.2** 所有下游功能只允许消费该模型，禁止绕过解析引擎自行读取原始文件内容。
- **FR1.6.3** 解析失败必须产生终态 `FAILED` + 原因码：`PARSE_ERR_FORMAT / PARSE_ERR_ENCRYPTED / PARSE_ERR_SIZE / PARSE_ERR_CORRUPT / PARSE_ERR_TIMEOUT / PARSE_ERR_OCR_FAIL / PARSE_ERR_UNKNOWN`，并附人类可读描述。
- **FR1.6.4** 支持对同一文档重新解析（生成新解析版本，旧版本保留）。
- **AC1.6.1** F5/F6/F2 仅依赖解析模型即可完成各自功能（集成测试证明）。
- **AC1.6.2** 任意失败文档在文档列表可见失败原因码。

## 3. 数据模型（核心）

| 实体 | 关键字段 |
| ---- | ---- |
| `parse_result` | doc_id, schema_version, result(JSONB), status(PENDING/RUNNING/SUCCESS/FAILED/PARSE_CONFIRMED), reason_code?, parser_version, started_at, finished_at |
| `parse_override` | parse_result_id, target_block_id/field_key, old_value, new_value, edited_by, edited_at |
| `param_dict` | key, display_name, synonyms[], unit_candidates[], safety_level |

## 4. API 概要

```
POST /api/v1/documents                # 上传（multipart），返回 Document
POST /api/v1/documents/{id}/reparse   # 触发重解析（新解析版本）
GET  /api/v1/documents/{id}/parse     # 当前解析模型（含 overrides）
GET  /api/v1/params/dictionary        # 参数字典 CRUD
```

## 5. 横切接入（F10）

- **审计**：`parse.completed` / `parse.failed` / `parse.corrected`（校对）。
- **KPI**：`parse.duration`（提交→SUCCESS）；金标准确率评测脚本独立于线上埋点。
- **权限**：解析结果可见性随文档（项目/部门继承）。
- **异步**：解析走 Celery `parse` 队列，进度经 SSE 推送（页数级粗粒度即可）。

## 6. 非目标

CAD/3D 格式、手写体识别、公式还原与重排、EPUB 等 [PHASE1_SPEC §4]。

## 7. 开放问题

- **Q1** 金标集构成：多少份、谁标注、覆盖哪些模板类型（建议 ≥30 份，含扫描件 5 份）。
- **Q2** `.doc`/`.xls` 老格式是否必须原生支持，还是要求上传方转换。
- **Q3** OCR 算力预算（是否配 GPU 节点，影响并发与耗时承诺）。
- **Q4** 参数字典初始清单由哪位业务专家评审签字。
