#!/bin/bash
# Agent Usage — Claude Code 토큰 사용량 리포트 (pass 번들 익스텐션 예제).
#
# ~/.claude/projects/**/*.jsonl 트랜스크립트에서 assistant 턴의 usage를 집계한다.
# 달러 비용은 일부러 계산하지 않는다 — 모델 단가는 금방 낡고, 토큰 수는 낡지 않는다.
# 의존성: python3 (macOS 기본 포함).
set -euo pipefail

DAYS="${1:-7}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3가 필요합니다 (xcode-select --install)."
  read -n 1 -s -r -p "아무 키나 누르면 닫힙니다…"
  exit 1
fi

python3 - "$DAYS" <<'PY'
import collections
import datetime
import glob
import json
import os
import sys

days = int(sys.argv[1]) if len(sys.argv) > 1 else 7
root = os.path.expanduser("~/.claude/projects")
now = datetime.datetime.now().astimezone()
cutoff = now - datetime.timedelta(days=days)


def parse_ts(s):
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone()
    except (ValueError, TypeError):
        return None


def totals():
    return [0, 0, 0, 0]  # input, output, cache read, cache write


by_day = collections.defaultdict(totals)
by_model = collections.defaultdict(totals)
by_project = collections.defaultdict(totals)
seen = set()   # (message.id, requestId) — 스트리밍/재시도로 중복 기록된 턴 제거
files = 0
turns = 0

if not os.path.isdir(root):
    print("~/.claude/projects 가 없습니다 — 이 머신에서 Claude Code 기록을 찾지 못했어요.")
    sys.exit(0)

for path in glob.glob(os.path.join(root, "*", "*.jsonl")):
    try:
        mtime = datetime.datetime.fromtimestamp(os.path.getmtime(path)).astimezone()
    except OSError:
        continue
    if mtime < cutoff:
        continue  # 기간 밖 트랜스크립트는 파일째 건너뛴다 (속도)
    files += 1
    # 프로젝트 폴더명은 경로 인코딩("-Users-…-repo")이라 복원이 불가능하다. 각 행이 갖고
    # 있는 cwd에서 이름을 얻고, 없을 때만 폴더명 마지막 토큰으로 근사한다.
    tokens = [t for t in os.path.basename(os.path.dirname(path)).split("-") if t]
    fallback = tokens[-1] if tokens else "?"
    with open(path, errors="replace") as f:
        for line in f:
            if '"assistant"' not in line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("type") != "assistant":
                continue
            msg = row.get("message") or {}
            usage = msg.get("usage")
            if not usage:
                continue
            ts = parse_ts(row.get("timestamp", ""))
            if ts is None or ts < cutoff:
                continue
            mid = msg.get("id")
            if mid:
                key = (mid, row.get("requestId"))
                if key in seen:
                    continue
                seen.add(key)
            model = msg.get("model") or "?"
            if model == "<synthetic>":
                continue
            vals = (usage.get("input_tokens", 0) or 0,
                    usage.get("output_tokens", 0) or 0,
                    usage.get("cache_read_input_tokens", 0) or 0,
                    usage.get("cache_creation_input_tokens", 0) or 0)
            cwd = row.get("cwd")
            project = os.path.basename(cwd.rstrip("/")) if cwd else fallback
            turns += 1
            for agg, key in ((by_day, ts.strftime("%Y-%m-%d")),
                             (by_model, model), (by_project, project)):
                row_totals = agg[key]
                for i, v in enumerate(vals):
                    row_totals[i] += v


def fmt(n):
    return f"{n:,}"


def table(title, agg, by_key=False, top=None):
    if not agg:
        return
    print(title)
    print(f"  {'':<28}{'input':>12}{'output':>12}{'cache read':>14}{'cache write':>14}{'total':>14}")
    items = sorted(agg.items()) if by_key else sorted(agg.items(), key=lambda kv: -sum(kv[1]))
    for k, v in (items[:top] if top else items):
        label = (k[:26] + "…") if len(k) > 27 else k
        print(f"  {label:<28}{fmt(v[0]):>12}{fmt(v[1]):>12}{fmt(v[2]):>14}{fmt(v[3]):>14}{fmt(sum(v)):>14}")
    print()


print(f"Agent 사용량 — 최근 {days}일 · assistant 턴 {fmt(turns)}개 · 트랜스크립트 {files}개\n")
if turns == 0:
    print("기간 내 사용 기록이 없습니다.")
else:
    table("일자별", by_day, by_key=True)
    table("모델별", by_model)
    table("프로젝트별 (상위 10)", by_project, top=10)
    grand = totals()
    for v in by_day.values():
        for i in range(4):
            grand[i] += v[i]
    print(f"합계  input {fmt(grand[0])} · output {fmt(grand[1])}"
          f" · cache read {fmt(grand[2])} · cache write {fmt(grand[3])}")
PY

echo
read -n 1 -s -r -p "아무 키나 누르면 닫힙니다…"
echo
