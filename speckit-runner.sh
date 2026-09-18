#!/usr/bin/env bash
# speckit-runner.sh — engineering-copilot Phase 1 规格驱动开发流水线执行器
#
# 对 specs/ 下 10 个 feature spec（F1–F10）依次驱动 AI CLI（kiro/claude/codex/qwen）执行：
#   clarify → plan → tasks → (analyze) → implement
# 产出文件与 specs/ 内的 spec 平铺存放：
#   specs/<F>.clarifications.md       clarify 阶段：自动解答 spec 中的「开放问题 Q*」
#   specs/<F>.plan.md                 plan 阶段
#   specs/<F>.tasks.md                tasks 阶段
#   specs/<F>.analysis.md             analyze 阶段
#   .speckit-run/state/<F>.impl-done  implement 完成标记（内容为完成摘要）
# 断点续跑：已存在的产出文件/标记对应阶段自动跳过。
#
# 用法:
#   ./speckit-runner.sh --status                    # 查看各 feature 进度
#   ./speckit-runner.sh --dry-run                   # 只打印将执行的动作
#   ./speckit-runner.sh                             # 从第一个未完成的 feature 跑到 F9
#   ./speckit-runner.sh --from F2 --stages plan,tasks
#   ./speckit-runner.sh --stages clarify,plan,tasks --from 2   # clarify=自动解答开放问题
#   ./speckit-runner.sh --only F10,F1 --jobs 3      # --jobs=同一阶段内并行 N 个 feature（implement 恒串行）
#   ./speckit-runner.sh --agent codex               # 或 claude / qwen / kiro；或 --cmd '自定义模板 {PROMPT}'
# 兼容 macOS 自带 bash 3.2。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

LOG_DIR="$ROOT/.speckit-run/logs"
STATE_DIR="$ROOT/.speckit-run/state"
mkdir -p "$LOG_DIR" "$STATE_DIR"

# implement 执行顺序 = 依赖顺序：
#   F10 平台对象模型/状态机/审计/RBAC 是其余功能的地基；
#   F1→F2→F3→F4 为知识主线（F5/F6 仅依赖 F1，可与 M2 并行规划）；
#   F7/F8/F9 为生成层（F9 依赖 F8，F7 依赖 F2/F3）。
FEATURES=(
  F10-platform-governance
  F1-document-parsing
  F2-knowledge-base
  F3-rag-retrieval
  F4-ai-chat
  F5-spec-comparison
  F6-bom-comparison
  F7-fmea-generation
  F8-test-case-generation
  F9-test-report
)

FROM="" ONLY="" STAGES="plan,tasks,implement" AGENT="auto" CMD="" JOBS=1 DRY=0 STATUS_ONLY=0

usage() { sed -n '2,22p' "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --stages) STAGES="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --cmd) CMD="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --status) STATUS_ONLY=1; shift ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1"; usage ;;
  esac
done

IFS=',' read -r -a STAGE_LIST <<< "$STAGES"

# 各阶段产出文件（spec 平铺布局：specs/<F>.md 为输入，<F>.<stage>.md 为产出）
stage_file() {  # stage_file <feature> <stage>
  case "$2" in
    clarify)   echo "specs/$1.clarifications.md" ;;
    plan)      echo "specs/$1.plan.md" ;;
    tasks)     echo "specs/$1.tasks.md" ;;
    analyze)   echo "specs/$1.analysis.md" ;;
    implement) echo "$STATE_DIR/$1.impl-done" ;;
  esac
}

stage_done() {  # stage_done <feature> <stage>
  [[ -f "$(stage_file "$1" "$2")" ]]
}

feat_num() {  # feat_num <feature> → 去掉 F 前缀的编号，如 F10-platform-governance → 10
  local n="${1%%-*}"
  echo "${n#[fF]}"
}

# ---------- --status ----------
if [[ $STATUS_ONLY -eq 1 ]]; then
  order=""
  for f in "${FEATURES[@]}"; do order="${order:+$order → }${f%%-*}"; done
  echo ">> 执行顺序 = 依赖序（implement 恒按此串行）：$order"
  echo "   （F10 是平台地基：对象模型/状态机/审计/RBAC，其余功能都构建在其上）"
  echo
  printf "%-26s %-8s %-6s %-6s %-8s %-6s\n" FEATURE CLARIFY PLAN TASKS ANALYZE IMPL
  for f in "${FEATURES[@]}"; do
    printf "%-26s %-8s %-6s %-6s %-8s %-6s\n" "$f" \
      "$(stage_done "$f" clarify && echo ✓ || echo ·)" \
      "$(stage_done "$f" plan && echo ✓ || echo ·)" \
      "$(stage_done "$f" tasks && echo ✓ || echo ·)" \
      "$(stage_done "$f" analyze && echo ✓ || echo ·)" \
      "$(stage_done "$f" implement && echo ✓ || echo ·)"
  done
  exit 0
fi

# ---------- 选择 agent 命令 ----------
if [[ -n "$CMD" ]]; then
  AGENT_BIN="__custom__"
else
  case "$AGENT" in
    kiro|claude|codex|qwen) AGENT_BIN="$AGENT" ;;
    auto)
      if command -v kiro-cli >/dev/null 2>&1; then AGENT_BIN=kiro
      elif command -v claude >/dev/null 2>&1; then AGENT_BIN=claude
      elif command -v codex >/dev/null 2>&1; then AGENT_BIN=codex
      elif command -v qwen >/dev/null 2>&1; then AGENT_BIN=qwen
      else echo "错误: 未找到 kiro-cli/claude/codex/qwen，请用 --cmd 指定调用模板" >&2; exit 1; fi ;;
    *) echo "错误: --agent 仅支持 kiro|claude|codex|qwen|auto" >&2; exit 1 ;;
  esac
fi

invoke_agent() {  # invoke_agent <prompt>
  local prompt="$1"
  case "$AGENT_BIN" in
    kiro)      kiro-cli chat --no-interactive --trust-all-tools "$prompt" ;;
    claude)    claude -p "$prompt" --dangerously-skip-permissions --max-turns 300 ;;
    codex)     codex exec --full-auto "$prompt" ;;
    qwen)      qwen -p "$prompt" --yolo ;;
    __custom__) ${CMD//\{PROMPT\}/$prompt} ;;
  esac
}

# ---------- 阶段提示词 ----------
# 优先使用已安装的 speckit 技能（.zcode/skills/speckit-<stage>/SKILL.md）；
# 不存在则使用下面的内置流程，保证本脚本自带完整阶段定义、不依赖外部技能。
prompt_for() {  # prompt_for <feature> <stage>
  local f="$1" s="$2" skill extra="" skill_path how flow=""
  case "$s" in
    clarify)   skill="speckit-clarify" ;;
    plan)      skill="speckit-plan" ;;
    tasks)     skill="speckit-tasks" ;;
    analyze)   skill="speckit-analyze" ;;
    implement) skill="speckit-implement" ;;
  esac
  skill_path=".zcode/skills/${skill}/SKILL.md"
  if [[ -f "$skill_path" ]]; then
    how="阅读 ${skill_path}，严格按照其中的流程"
  else
    how="按以下内置流程"
  fi
  case "$s" in
    clarify) flow="目标：解决该 feature spec 中遗留的开放问题。
1. 通读 specs/${f}.md，定位「开放问题」小节（Q1、Q2…；若小节缺失，扫描全文 Q 标记）。
2. 对每个开放问题：结合 PRD.md、UI_GUIDE.md、PHASE1_SPEC.md、PHASE1_FEATURES.md 的上下文，选出最合理的推荐方案并直接采纳为决策；不得留下未回答的问题。
3. 产出 specs/${f}.clarifications.md：每条一行，格式 \`- Q<n>: <问题> → 决策：<最终答案>（理由一句话；影响的需求编号 FR*）\`。
4. 决策与 spec 原文冲突时，不要修改 spec 原文，在 clarifications 中注明「覆盖 FRx.y.z」，plan 阶段会以 clarifications 为准。" ;;
    plan) flow="目标：产出该 feature 的技术方案（不写代码）。
1. 输入：specs/${f}.md、specs/${f}.clarifications.md（若存在，且与 spec 冲突时以其为准）、PHASE1_SPEC.md、PHASE1_FEATURES.md、specs/README.md（编号/API/状态机/kb_version 等全文约定）。
2. 产出 specs/${f}.plan.md，必须包含：架构与模块落点（对齐既定技术栈：后端 FastAPI 模块化单体+Celery+PostgreSQL/pgvector+MinIO，前端 React/TS/AntD）；数据模型（表/字段，含与 F10 对象模型/状态机/审计的接入）；API 设计（遵循 specs/README.md 约定：REST /api/v1、统一错误体、异步任务 SSE）；AI/LLM 使用点（模型、Prompt 策略、结构化输出 schema、评测方式）；测试策略；风险与非目标。
3. plan 中每个设计决策需能回溯到 spec 的 FR/AC 编号。" ;;
    tasks) flow="目标：把 plan 拆成可执行任务清单。
1. 输入：specs/${f}.plan.md（及其 spec、clarifications）。
2. 产出 specs/${f}.tasks.md：有序任务列表，每条包含 任务目标 / 涉及文件或模块 / 完成标准（引用 spec 的 AC 编号）/ 依赖的任务号 / 粒度（半天~两天）。
3. 首个任务必须是 F10 接入点：审计事件定义、状态机接线、权限点、KPI 埋点；最后一个任务必须是端到端验收（覆盖该 feature 全部 AC）。
4. 任务总数控制在 15 条以内，超出说明 plan 粒度过粗，应先细化 plan。" ;;
    analyze) flow="目标：三件套一致性审查 + 规格-实现交叉审计。
1. 核对 specs/${f}.md / plan / tasks 三者口径一致（FR、AC、API、数据模型无矛盾）。
2. 规格-实现交叉审计：a) tasks.md 各任务是否有对应实现与测试文件；b) 从 Functional Requirements（FR*）抽样核对代码中有对应处理逻辑；c) 实际运行该 feature 相关测试（backend/tests 的 pytest、frontend 的 vitest，按文件名/内容含该 feature 关键词筛选）并记录通过/失败。
3. 产出 specs/${f}.analysis.md，必须含「SPEC-IMPLEMENTATION COVERAGE」小节：已实现 / 部分实现 / 缺失 三类清单，每条附证据（文件路径或测试名）。" ;;
    implement) flow="目标：按 tasks.md 完成该 feature 的编码与测试。
1. 输入：specs/${f}.tasks.md（及 plan、spec、clarifications）；严格遵守 specs/README.md 全局约定（AI 生成物 DRAFT 态、定版人工闸门、审计事件、[AI] 标识、错误码规范）。
2. 代码库布局：backend/（Python/FastAPI/SQLAlchemy/Celery，测试 pytest）、frontend/（React/TS/AntD，测试 vitest）；目录尚不存在时按此创建。
3. 按任务顺序实现；每完成一个任务跑对应测试；全部完成后跑该 feature 全量测试。
4. extra 占位" ;;
  esac
  case "$s" in
    clarify)   extra="完成后确认 specs/${f}.clarifications.md 已写入全部问题的决策。" ;;
    plan)      extra="完成后确认 specs/${f}.plan.md 存在且涵盖第 2 条要求的全部小节。" ;;
    tasks)     extra="完成后确认 specs/${f}.tasks.md 存在且每条任务含完成标准。" ;;
    analyze)   extra="完成后确认 specs/${f}.analysis.md 存在且含 SPEC-IMPLEMENTATION COVERAGE 小节。" ;;
    implement) extra="全部任务完成且测试通过后，创建标记文件 $(stage_file "$f" implement)（内容为一句完成摘要）。若测试失败必须修复后重试，不得带病标记。" ;;
  esac
  flow="${flow//extra 占位/$extra}"
  cat <<EOF
你在 engineering-copilot（工程智能副驾 Phase 1）仓库中执行规格驱动开发的一个阶段，全程无人值守，绝对不要向用户提问。

任务：${how}，对 feature ${f} 执行 ${skill} 阶段。

${flow}

规则：
1. 本次只处理 feature ${f}（规格文件 specs/${f}.md，以此为准）。不要修改其他 feature 的任何文件，也不要修改共享文档（specs/README.md、PHASE1_SPEC.md、PHASE1_FEATURES.md、PRD.md、UI_GUIDE.md）。
2. 遵循 specs/README.md 的全局约定（FR/AC 编号、REST /api/v1、统一错误体、异步任务 SSE、UUIDv7、AI 生成物 DRAFT→APPROVED 人工确认、审计事件命名 <domain>.<verb>）。
3. 凡流程中需要用户澄清/决策之处：直接采用最合理的默认或推荐选项，并把决策记入产出文件的相应小节（Clarifications / Assumptions），不要停下来等待输入。
4. 产出文件路径：clarify→specs/${f}.clarifications.md，plan→specs/${f}.plan.md，tasks→specs/${f}.tasks.md，analyze→specs/${f}.analysis.md，implement→修改代码库。
5. ${extra}
EOF
}

# ---------- 组装待跑清单 ----------
run_list=()
# --from 归一化：数字/F<n> → F<n>；完整名保持原样。
# FEATURES 按依赖序排列（F10 在最前），因此 --from 解析为"数组中该 feature 的位置"，
# 从该位置起执行（含依赖它的后续 feature），不做数值比较——否则 --from 8 会误命中排最前的 F10。
FROM_KEY=""
if [[ -n "$FROM" ]]; then
  if [[ "$FROM" =~ ^[0-9]+$ ]]; then FROM_KEY="F$((10#$FROM))"
  elif [[ "$FROM" =~ ^[fF][0-9]+$ ]]; then FROM_KEY="F${FROM#[fF]}"
  else FROM_KEY="$FROM"; fi
fi
FROM_IDX=""
if [[ -n "$FROM" ]]; then
  for i in "${!FEATURES[@]}"; do
    num="F$(feat_num "${FEATURES[$i]}")"
    # F<n> 形式必须精确匹配编号（前缀匹配会撞上 F10/F1x）；名称片段才用前缀匹配
    if [[ "$FROM_KEY" =~ ^F[0-9]+$ ]]; then
      [[ "$num" == "$FROM_KEY" ]] && { FROM_IDX=$i; break; }
    else
      [[ "${FEATURES[$i]}" == "$FROM_KEY"* ]] && { FROM_IDX=$i; break; }
    fi
  done
  if [[ -z "$FROM_IDX" ]]; then echo "错误: --from $FROM 未匹配任何 feature" >&2; exit 1; fi
fi
# --only 归一化：数字 → F<n>；f3/F3 → F3；完整名保持原样
ONLY_N=""
if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a _only_tokens <<< "$ONLY"
  for t in "${_only_tokens[@]}"; do
    if [[ "$t" =~ ^[0-9]+$ ]]; then t="F$((10#$t))"
    elif [[ "$t" =~ ^[fF][0-9]+$ ]]; then t="F${t#[fF]}"; fi
    ONLY_N="${ONLY_N:+${ONLY_N},}${t}"
  done
fi
for i in "${!FEATURES[@]}"; do
  f="${FEATURES[$i]}"
  [[ -n "$FROM" && $i -lt ${FROM_IDX:-0} ]] && continue
  num="F$(feat_num "$f")"
  if [[ -n "$ONLY_N" && ",$ONLY_N," != *",$num,"* && ",$ONLY_N," != *",$f,"* ]]; then continue; fi
  run_list+=("$f")
done

echo ">> Agent: $AGENT_BIN | Stages: $STAGES | Jobs(plan/tasks): $JOBS"
order=""
for f in "${FEATURES[@]}"; do order="${order:+$order → }${f%%-*}"; done
echo ">> 执行顺序 = 依赖序（implement 恒按此串行）：$order"
echo ">> 待处理 feature: ${#run_list[@]} 个"
[[ ${#run_list[@]} -eq 0 ]] && { echo ">> 没有匹配的 feature。"; exit 0; }

failed=0
# 看门狗：log 无增长 且 仓库(backend/frontend/specs)无文件改动 持续 N 秒 → 判定挂死并终止该次调用
# claude -p 的输出要到结束才落盘，静默挂死只能靠文件活动判断。可用 STALL_SECONDS 覆盖（默认 1800）。
STALL_SECONDS="${STALL_SECONDS:-1800}"
run_stage() {  # run_stage <feature> <stage>  （返回 0 成功/跳过，1 失败）
  local f="$1" s="$2" log rc="" size last_size=0 recent stamp out
  out="$(stage_file "$f" "$s")"
  if stage_done "$f" "$s"; then echo "   跳过 ${f}/${s} (已完成)"; return 0; fi
  log="$LOG_DIR/${f}-${s}-$(date +%Y%m%d-%H%M%S).log"
  echo "   ▶ ${f}/${s}  (log: $log)"
  if [[ $DRY -eq 1 ]]; then return 0; fi
  stamp="$LOG_DIR/.watchdog-stamp"
  invoke_agent "$(prompt_for "$f" "$s")" >"$log" 2>&1 &
  local apid=$!
  touch "$stamp"
  local last_change
  last_change=$(date +%s)
  while kill -0 $apid 2>/dev/null; do
    sleep 60
    kill -0 $apid 2>/dev/null || break
    size=$(stat -f%z "$log" 2>/dev/null || echo 0)
    recent=$(find "$ROOT/backend" "$ROOT/frontend" "$ROOT/specs" -type f -not -path "*/node_modules/*" -newer "$stamp" 2>/dev/null | head -1)
    if [[ -n "$recent" || $size -gt $last_size ]]; then last_change=$(date +%s); fi
    last_size=$size
    touch "$stamp"
    if (( $(date +%s) - last_change >= STALL_SECONDS )); then
      echo "   ⚠ ${f}/${s} 无进展超过 ${STALL_SECONDS}s，判定挂死并终止该次调用"
      kill $apid 2>/dev/null; sleep 2; kill -9 $apid 2>/dev/null
      rc=1
      break
    fi
  done
  wait $apid 2>/dev/null
  [[ -z "$rc" ]] && rc=$?
  if [[ $rc -ne 0 || ! -f "$out" ]]; then
    echo "   ✖ ${f}/${s} 失败 (exit=${rc})，日志末尾："
    tail -5 "$log" | sed 's/^/     /'
    return 1
  fi
  echo "   ✔ ${f}/${s} 完成"
}

# 阶段屏障模式：每个阶段内跨 feature 并行（最多 JOBS 个），阶段全部完成才进入下一阶段。
# 同一 feature 内严格保持 clarify→plan→tasks→implement 顺序（tasks 依赖 plan 的产物）。
# implement 写同一个代码库：恒为全局串行，按依赖顺序（F10 → F1 → … → F9）。
for s in "${STAGE_LIST[@]}"; do
  echo ">> 阶段: $s"
  if [[ "$s" == "implement" || $JOBS -le 1 || $DRY -eq 1 ]]; then
    for f in "${run_list[@]}"; do
      run_stage "$f" "$s" || failed=$((failed+1))
    done
  else
    # 非实现阶段：跨 feature 并行池
    for f in "${run_list[@]}"; do
      while [[ $(jobs -rp | wc -l | tr -d ' ') -ge $JOBS ]]; do sleep 2; done
      run_stage "$f" "$s" &
    done
    wait
    for f in "${run_list[@]}"; do
      stage_done "$f" "$s" || { echo "   ✖ ${f}/${s} 并行执行未通过"; failed=$((failed+1)); }
    done
  fi
done

echo
if [[ $DRY -eq 1 ]]; then
  echo ">> dry-run 结束，未实际执行。"
else
  echo ">> 全部结束：失败 $failed 个阶段。日志在 .speckit-run/logs/，进度查看：./speckit-runner.sh --status"
fi
exit $failed
