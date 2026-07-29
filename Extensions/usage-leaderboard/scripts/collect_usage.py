#!/usr/bin/env python3
"""Collect aggregate token usage from local Claude Code, Codex, and Pi logs.

Only date/provider token totals are printed. Conversation text, prompts, project paths,
session ids, model names, and costs never enter the output.
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import os
import pathlib
from typing import Any, DefaultDict, Iterable

Totals = list[int]
Aggregate = DefaultDict[tuple[str, str], Totals]


def new_totals() -> Totals:
    return [0, 0, 0, 0]  # input, output, cache read, cache write


def parse_timestamp(value: Any) -> dt.datetime | None:
    if isinstance(value, (int, float)):
        # Pi message timestamps may be epoch milliseconds.
        seconds = value / 1000 if value > 10_000_000_000 else value
        try:
            return dt.datetime.fromtimestamp(seconds, tz=dt.timezone.utc).astimezone()
        except (OverflowError, OSError, ValueError):
            return None
    if not isinstance(value, str):
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return None


def integer(value: Any) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0


def add(aggregate: Aggregate, timestamp: dt.datetime, provider: str, values: Iterable[int]) -> None:
    target = aggregate[(timestamp.date().isoformat(), provider)]
    for index, value in enumerate(values):
        target[index] += max(0, int(value))


def recent_jsonl(root: pathlib.Path, cutoff: dt.datetime) -> Iterable[pathlib.Path]:
    if not root.is_dir():
        return
    for path in root.rglob("*.jsonl"):
        try:
            modified = dt.datetime.fromtimestamp(path.stat().st_mtime).astimezone()
        except OSError:
            continue
        if modified >= cutoff:
            yield path


def rows(path: pathlib.Path) -> Iterable[dict[str, Any]]:
    try:
        with path.open(errors="replace") as handle:
            for line in handle:
                try:
                    value = json.loads(line)
                except (ValueError, TypeError):
                    continue
                if isinstance(value, dict):
                    yield value
    except OSError:
        return


def collect_claude(root: pathlib.Path, cutoff: dt.datetime, aggregate: Aggregate) -> int:
    seen: set[tuple[Any, Any]] = set()
    turns = 0
    for path in recent_jsonl(root, cutoff):
        for row in rows(path):
            if row.get("type") != "assistant":
                continue
            message = row.get("message")
            if not isinstance(message, dict) or message.get("model") == "<synthetic>":
                continue
            usage = message.get("usage")
            timestamp = parse_timestamp(row.get("timestamp"))
            if not isinstance(usage, dict) or timestamp is None or timestamp < cutoff:
                continue
            identity = (message.get("id") or row.get("uuid"), row.get("requestId"))
            if identity[0] is not None:
                if identity in seen:
                    continue
                seen.add(identity)
            add(
                aggregate,
                timestamp,
                "claude",
                (
                    integer(usage.get("input_tokens")),
                    integer(usage.get("output_tokens")),
                    integer(usage.get("cache_read_input_tokens")),
                    integer(usage.get("cache_creation_input_tokens")),
                ),
            )
            turns += 1
    return turns


def collect_pi(root: pathlib.Path, cutoff: dt.datetime, aggregate: Aggregate) -> int:
    seen: set[Any] = set()
    turns = 0
    for path in recent_jsonl(root, cutoff):
        for row in rows(path):
            message = row.get("message")
            if row.get("type") != "message" or not isinstance(message, dict):
                continue
            if message.get("role") != "assistant":
                continue
            usage = message.get("usage")
            timestamp = parse_timestamp(row.get("timestamp") or message.get("timestamp"))
            if not isinstance(usage, dict) or timestamp is None or timestamp < cutoff:
                continue
            identity = row.get("id") or message.get("responseId")
            if identity is not None:
                if identity in seen:
                    continue
                seen.add(identity)
            add(
                aggregate,
                timestamp,
                "pi",
                (
                    integer(usage.get("input")),
                    integer(usage.get("output")),
                    integer(usage.get("cacheRead")),
                    integer(usage.get("cacheWrite")),
                ),
            )
            turns += 1
    return turns


def collect_codex(root: pathlib.Path, cutoff: dt.datetime, aggregate: Aggregate) -> int:
    events = 0
    for path in recent_jsonl(root, cutoff):
        previous = new_totals()
        for row in rows(path):
            payload = row.get("payload")
            if row.get("type") != "event_msg" or not isinstance(payload, dict):
                continue
            if payload.get("type") != "token_count":
                continue
            info = payload.get("info")
            usage = info.get("total_token_usage") if isinstance(info, dict) else None
            timestamp = parse_timestamp(row.get("timestamp"))
            if not isinstance(usage, dict) or timestamp is None:
                continue
            input_tokens = integer(usage.get("input_tokens"))
            cached_input_tokens = integer(usage.get("cached_input_tokens"))
            current = [
                max(0, input_tokens - cached_input_tokens),
                integer(usage.get("output_tokens")),
                cached_input_tokens,
                integer(usage.get("cache_write_input_tokens")),
            ]
            delta = [
                value - previous[index] if value >= previous[index] else value
                for index, value in enumerate(current)
            ]
            previous = current
            if timestamp >= cutoff and any(delta):
                add(aggregate, timestamp, "codex", delta)
                events += 1
    return events


def collect(days: int) -> dict[str, Any]:
    now = dt.datetime.now().astimezone()
    start_date = now.date() - dt.timedelta(days=days - 1)
    cutoff = dt.datetime.combine(start_date, dt.time.min, tzinfo=now.tzinfo)
    home = pathlib.Path.home()
    roots = {
        "claude": pathlib.Path(
            os.environ.get("PASS_USAGE_CLAUDE_ROOT", home / ".claude/projects")
        ).expanduser(),
        "codex": pathlib.Path(
            os.environ.get("PASS_USAGE_CODEX_ROOT", home / ".codex/sessions")
        ).expanduser(),
        "pi": pathlib.Path(
            os.environ.get("PASS_USAGE_PI_ROOT", home / ".pi/agent/sessions")
        ).expanduser(),
    }
    aggregate: Aggregate = collections.defaultdict(new_totals)
    observations = {
        "claude": collect_claude(roots["claude"], cutoff, aggregate),
        "codex": collect_codex(roots["codex"], cutoff, aggregate),
        "pi": collect_pi(roots["pi"], cutoff, aggregate),
    }

    daily = []
    total = new_totals()
    providers: dict[str, Totals] = {
        "claude": new_totals(),
        "codex": new_totals(),
        "pi": new_totals(),
    }
    for (date, provider), values in sorted(aggregate.items()):
        if not any(values):
            continue
        for index, value in enumerate(values):
            total[index] += value
            providers[provider][index] += value
        daily.append(
            {
                "date": date,
                "provider": provider,
                "inputTokens": values[0],
                "outputTokens": values[1],
                "cacheReadTokens": values[2],
                "cacheWriteTokens": values[3],
                "totalTokens": sum(values),
            }
        )

    def payload(values: Totals) -> dict[str, int]:
        return {
            "inputTokens": values[0],
            "outputTokens": values[1],
            "cacheReadTokens": values[2],
            "cacheWriteTokens": values[3],
            "totalTokens": sum(values),
        }

    return {
        "schemaVersion": 1,
        "generatedAt": now.isoformat(),
        "periodDays": days,
        "daily": daily,
        "totals": payload(total),
        "providers": {name: payload(values) for name, values in providers.items()},
        "observations": observations,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=30)
    args = parser.parse_args()
    if not 1 <= args.days <= 45:
        parser.error("--days must be between 1 and 45")
    print(json.dumps(collect(args.days), ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
