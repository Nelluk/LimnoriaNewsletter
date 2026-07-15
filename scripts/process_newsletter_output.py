#!/usr/bin/env python3
"""Validate structured Codex output and commit deterministic artifacts."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import tempfile
from collections import Counter
from pathlib import Path


AWARD_MARKER = "<!-- CHATTER_AWARDS -->"
CURRENT_STATE_SCHEMA = 3
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
SPEAKER_RE = re.compile(r"^\S+\s+<([^>]+)>")
FORBIDDEN_HEADING_RE = re.compile(
    r"^#{2,6}\s+(?:best chatter|worst chatter|all-time leaderboard)\s*$",
    re.IGNORECASE | re.MULTILINE,
)
RESERVED_NICKS = {
    "best chatter",
    "worst chatter",
    "all-time leaderboard",
    "honorable mentions",
    "best/worst awards",
}


class ValidationError(ValueError):
    """The generated response or persisted state is unsafe to consume."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw-response", required=True, type=Path)
    parser.add_argument("--log-file", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--leaderboard-file", required=True, type=Path)
    parser.add_argument("--history-dir", required=True, type=Path)
    parser.add_argument("--date", required=True)
    parser.add_argument("--channel", required=True)
    parser.add_argument("--top-n", required=True, type=int)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def load_alias_map() -> dict[str, str]:
    raw = os.environ.get("NEWSLETTER_NICK_ALIASES_JSON", "").strip()
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValidationError(f"Invalid NEWSLETTER_NICK_ALIASES_JSON: {exc}") from exc
    if not isinstance(parsed, dict):
        raise ValidationError("NEWSLETTER_NICK_ALIASES_JSON must be a JSON object")

    aliases: dict[str, str] = {}
    for raw_alias, raw_primary in parsed.items():
        alias = str(raw_alias).strip().lower()
        primary = str(raw_primary).strip().lower()
        if not alias or not primary:
            raise ValidationError("Nick aliases cannot contain empty names")
        aliases[alias] = primary
    return aliases


def load_excluded_nicks(alias_map: dict[str, str]) -> set[str]:
    raw = os.environ.get(
        "NEWSLETTER_AWARD_EXCLUDED_NICKS", "ne2,HenryClay"
    )
    return {
        normalize_nick(item, alias_map)
        for item in raw.split(",")
        if item.strip()
    }


def normalize_nick(raw: str, alias_map: dict[str, str]) -> str:
    nick = raw.strip().lower()
    nick = alias_map.get(nick, nick)
    # Preserve the project's legacy treatment of reconnect suffixes.
    nick = nick.rstrip("_")
    return alias_map.get(nick, nick)


def validate_plain_nick(raw: object, label: str) -> str:
    if not isinstance(raw, str):
        raise ValidationError(f"{label} nick must be a string")
    nick = raw.strip()
    if not nick or len(nick) > 64:
        raise ValidationError(f"{label} nick has an invalid length")
    if any(char.isspace() or ord(char) < 32 for char in nick):
        raise ValidationError(f"{label} nick contains whitespace or control characters")
    if any(char in nick for char in "`<>"):
        raise ValidationError(f"{label} nick contains unsafe Markdown characters")
    if nick.lower() in RESERVED_NICKS:
        raise ValidationError(f"{label} nick is a reserved newsletter label")
    return nick


def validate_reason(raw: object, label: str) -> str:
    if not isinstance(raw, str):
        raise ValidationError(f"{label} reason must be a string")
    reason = raw.strip()
    if not reason or len(reason) > 1000:
        raise ValidationError(f"{label} reason has an invalid length")
    if "\n" in reason or "\r" in reason:
        raise ValidationError(f"{label} reason must be one line")
    if AWARD_MARKER in reason:
        raise ValidationError(f"{label} reason contains the reserved award marker")
    return reason


def require_exact_keys(value: object, keys: set[str], label: str) -> dict:
    if not isinstance(value, dict):
        raise ValidationError(f"{label} must be a JSON object")
    actual = set(value)
    if actual != keys:
        missing = sorted(keys - actual)
        extra = sorted(actual - keys)
        raise ValidationError(
            f"{label} fields mismatch (missing={missing}, extra={extra})"
        )
    return value


def load_response(
    path: Path, target_date: str, channel: str
) -> tuple[str, dict, dict]:
    try:
        response = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError(f"Invalid structured Codex response: {exc}") from exc

    response = require_exact_keys(
        response,
        {"newsletter_markdown", "best_chatter", "worst_chatter"},
        "Codex response",
    )
    markdown = response["newsletter_markdown"]
    if not isinstance(markdown, str) or not markdown.strip():
        raise ValidationError("newsletter_markdown must be a non-empty string")
    markdown = markdown.strip()
    if markdown.count(AWARD_MARKER) != 1:
        raise ValidationError("newsletter_markdown must contain exactly one award marker")
    if FORBIDDEN_HEADING_RE.search(markdown):
        raise ValidationError("newsletter_markdown contains a script-owned section")
    if re.search(r"^Nick aliases used:", markdown, re.IGNORECASE | re.MULTILINE):
        raise ValidationError("newsletter_markdown contains a script-owned alias footer")
    if markdown.splitlines()[0].strip() != f"{channel} - {target_date}":
        raise ValidationError("newsletter title does not match the requested date")

    best = require_exact_keys(response["best_chatter"], {"nick", "reason"}, "best_chatter")
    worst = require_exact_keys(response["worst_chatter"], {"nick", "reason"}, "worst_chatter")
    best = {
        "display": validate_plain_nick(best["nick"], "Best chatter"),
        "reason": validate_reason(best["reason"], "Best chatter"),
    }
    worst = {
        "display": validate_plain_nick(worst["nick"], "Worst chatter"),
        "reason": validate_reason(worst["reason"], "Worst chatter"),
    }
    return markdown, best, worst


def log_participants(path: Path, alias_map: dict[str, str]) -> set[str]:
    participants: set[str] = set()
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = SPEAKER_RE.match(line)
                if match:
                    participants.add(normalize_nick(match.group(1), alias_map))
    except OSError as exc:
        raise ValidationError(f"Could not read source log: {exc}") from exc
    if not participants:
        raise ValidationError("Source log contains no recognizable IRC speakers")
    return participants


def validate_awards(
    best: dict,
    worst: dict,
    participants: set[str],
    alias_map: dict[str, str],
    excluded: set[str],
) -> dict[str, dict[str, str]]:
    for label, award in (("Best chatter", best), ("Worst chatter", worst)):
        canonical = normalize_nick(award["display"], alias_map)
        if not canonical or canonical in RESERVED_NICKS:
            raise ValidationError(f"{label} resolves to an invalid nickname")
        if canonical in excluded:
            raise ValidationError(f"{label} winner {award['display']} is excluded")
        if canonical not in participants:
            raise ValidationError(
                f"{label} winner {award['display']} did not speak in the source log"
            )
        award["canonical"] = canonical
    if best["canonical"] == worst["canonical"]:
        raise ValidationError("Best and Worst chatter must be different people")
    return {"best": best, "worst": worst}


def validate_state_nick(raw: object, label: str, alias_map: dict[str, str]) -> str:
    nick = validate_plain_nick(raw, label)
    canonical = normalize_nick(nick, alias_map)
    if canonical in RESERVED_NICKS:
        raise ValidationError(f"{label} resolves to a reserved label")
    return canonical


def load_state(
    path: Path, history_dir: Path, alias_map: dict[str, str]
) -> tuple[dict[str, dict[str, str]], bool]:
    if not path.is_file():
        historical = list(history_dir.glob("newsletter-????-??-??.md"))
        if historical:
            raise ValidationError(
                "Leaderboard state is missing while historical newsletters exist; "
                "refusing to rebuild from prose"
            )
        return {}, False

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError(f"Invalid leaderboard state: {exc}") from exc
    if not isinstance(data, dict) or data.get("schema_version") not in (2, 3):
        raise ValidationError("Unsupported leaderboard state schema")
    by_date = data.get("by_date")
    if not isinstance(by_date, dict):
        raise ValidationError("Leaderboard state by_date must be an object")

    normalized: dict[str, dict[str, str]] = {}
    for date_key, winners in by_date.items():
        if not isinstance(date_key, str) or not DATE_RE.fullmatch(date_key):
            raise ValidationError(f"Invalid leaderboard date: {date_key!r}")
        winners = require_exact_keys(winners, {"best", "worst"}, f"state record {date_key}")
        best = validate_state_nick(winners["best"], f"{date_key} best", alias_map)
        worst = validate_state_nick(winners["worst"], f"{date_key} worst", alias_map)
        if best == worst:
            raise ValidationError(f"Leaderboard state has identical winners on {date_key}")
        normalized[date_key] = {"best": best, "worst": worst}
    return normalized, data["schema_version"] == 2


def recompute_totals(by_date: dict[str, dict[str, str]]) -> dict[str, Counter]:
    return {
        kind: Counter(winners[kind] for winners in by_date.values())
        for kind in ("best", "worst")
    }


def format_leaders(bucket: Counter, top_n: int) -> str:
    ordered = sorted(bucket.items(), key=lambda item: (-item[1], item[0]))
    if top_n > 0:
        ordered = ordered[:top_n]
    if not ordered:
        return "none yet."
    return ", ".join(f"`{nick}` ({count})" for nick, count in ordered)


def render_markdown(
    markdown: str,
    awards: dict[str, dict[str, str]],
    totals: dict[str, Counter],
    top_n: int,
    alias_map: dict[str, str],
) -> str:
    award_section = "\n".join(
        [
            "### Best chatter",
            "",
            f"`{awards['best']['display']}` — {awards['best']['reason']}",
            "",
            "### Worst chatter",
            "",
            f"`{awards['worst']['display']}` — {awards['worst']['reason']}",
        ]
    )
    rendered = markdown.replace(AWARD_MARKER, award_section).rstrip()
    if top_n > 0:
        rendered += "\n\n" + "\n".join(
            [
                "### All-time leaderboard",
                "",
                f"**Best chatter**: {format_leaders(totals['best'], top_n)}",
                "",
                f"**Worst chatter**: {format_leaders(totals['worst'], top_n)}",
            ]
        )
    if alias_map:
        pairs = ", ".join(
            f"{alias} -> {primary}" for alias, primary in sorted(alias_map.items())
        )
        rendered += f"\n\nNick aliases used: {pairs}"
    return rendered + "\n"


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_path, 0o644)
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    if not DATE_RE.fullmatch(args.date):
        raise ValidationError("Invalid target date")
    if args.top_n < 0:
        raise ValidationError("Leaderboard limit cannot be negative")

    alias_map = load_alias_map()
    excluded = load_excluded_nicks(alias_map)
    markdown, best, worst = load_response(args.raw_response, args.date, args.channel)
    participants = log_participants(args.log_file, alias_map)
    awards = validate_awards(best, worst, participants, alias_map, excluded)
    by_date, needs_migration = load_state(
        args.leaderboard_file, args.history_dir, alias_map
    )
    by_date[args.date] = {
        "best": awards["best"]["canonical"],
        "worst": awards["worst"]["canonical"],
    }
    totals = recompute_totals(by_date)
    rendered = render_markdown(markdown, awards, totals, args.top_n, alias_map)
    state_json = json.dumps(
        {
            "schema_version": CURRENT_STATE_SCHEMA,
            "by_date": dict(sorted(by_date.items())),
        },
        indent=2,
        sort_keys=True,
    ) + "\n"

    atomic_write(args.output, rendered)
    if not args.dry_run:
        if needs_migration:
            backup = args.leaderboard_file.with_name(
                args.leaderboard_file.name + ".schema-v2.bak"
            )
            if not backup.exists():
                shutil.copy2(args.leaderboard_file, backup)
        atomic_write(args.leaderboard_file, state_json)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as exc:
        print(f"Newsletter validation failed: {exc}", file=os.sys.stderr)
        raise SystemExit(1)
