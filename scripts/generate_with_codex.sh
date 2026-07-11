#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --date YYYY-MM-DD --log-file /path/to/log --output /path/to/output.md --instructions /path/to/instructions.md [--dry-run] [--no-upload]
USAGE
}

DATE=""
LOG_FILE=""
OUTPUT_FILE=""
INSTRUCTIONS_FILE=""
DRY_RUN=0
NO_UPLOAD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)
      DATE="${2:-}"; shift 2 ;;
    --log-file)
      LOG_FILE="${2:-}"; shift 2 ;;
    --output)
      OUTPUT_FILE="${2:-}"; shift 2 ;;
    --instructions)
      INSTRUCTIONS_FILE="${2:-}"; shift 2 ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    --no-upload)
      NO_UPLOAD=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2 ;;
  esac
done

[[ -n "$DATE" && -n "$LOG_FILE" && -n "$OUTPUT_FILE" && -n "$INSTRUCTIONS_FILE" ]] || {
  usage
  exit 2
}

[[ -f "$LOG_FILE" ]] || { echo "Missing log file: $LOG_FILE" >&2; exit 1; }
[[ -f "$INSTRUCTIONS_FILE" ]] || { echo "Missing instructions file: $INSTRUCTIONS_FILE" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${NEWSLETTER_ENV:-$PROJECT_ROOT/config/newsletter.env}"
ENV_FILE_LOADED=0
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
  ENV_FILE_LOADED=1
fi

: "${CODEX_BIN:=codex}"
: "${CODEX_WORKDIR:=$PROJECT_ROOT}"
: "${PASTERS_IO_ENDPOINT:=https://pasters.io/}"
: "${PASTE_RS_ENDPOINT:=${PASTE_ENDPOINT:-https://paste.rs}}"
: "${DPASTE_ENDPOINT:=https://dpaste.com/api/v2/}"
: "${PASTE_UPLOAD_TIMEOUT:=20}"
: "${PASTE_CONNECT_TIMEOUT:=5}"
: "${PASTE_UPLOAD_RETRIES:=3}"
: "${DPASTE_SYNTAX:=md}"
: "${DPASTE_PREVIEW_SUFFIX:=-preview}"
: "${CODEX_MODEL:=gpt-5.6-terra}"
: "${CODEX_MODEL_REASONING_EFFORT:=high}"
: "${STATE_DIR:=$PROJECT_ROOT/data/state}"
: "${NEWSLETTER_RUNTIME_DIR:=$PROJECT_ROOT/data}"
: "${CODEX_HOME:=${NEWSLETTER_RUNTIME_DIR}/codex_home}"
: "${NEWSLETTER_HISTORY_COUNT:=3}"
: "${NEWSLETTER_HISTORY_MAX_CHARS_PER_FILE:=4000}"
: "${NEWSLETTER_HISTORY_MAX_TOTAL_CHARS:=10000}"
: "${NEWSLETTER_LEADERBOARD_FILE:=${STATE_DIR}/leaderboard.json}"
: "${NEWSLETTER_LEADERBOARD_LIMIT:=10}"

if [[ -z "${CODEX_DANGEROUS_BYPASS+x}" ]]; then
  if [[ "$ENV_FILE_LOADED" -eq 1 ]]; then
    CODEX_DANGEROUS_BYPASS=1
  else
    CODEX_DANGEROUS_BYPASS=0
  fi
fi

if [[ -z "${CODEX_NETWORK_ACCESS+x}" ]]; then
  if [[ "$ENV_FILE_LOADED" -eq 1 ]]; then
    CODEX_NETWORK_ACCESS=true
  else
    CODEX_NETWORK_ACCESS=false
  fi
fi

if [[ -z "${CODEX_WEB_SEARCH+x}" ]]; then
  if [[ "$ENV_FILE_LOADED" -eq 1 ]]; then
    CODEX_WEB_SEARCH=live
  else
    CODEX_WEB_SEARCH=
  fi
fi

: "${CODEX_SANDBOX_MODE:=workspace-write}"
: "${CODEX_EPHEMERAL:=0}"

to_nonnegative_int() {
  local value="$1"
  local fallback="$2"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

toml_bool() {
  if is_truthy "$1"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

NEWSLETTER_HISTORY_COUNT="$(to_nonnegative_int "$NEWSLETTER_HISTORY_COUNT" 3)"
NEWSLETTER_HISTORY_MAX_CHARS_PER_FILE="$(to_nonnegative_int "$NEWSLETTER_HISTORY_MAX_CHARS_PER_FILE" 4000)"
NEWSLETTER_HISTORY_MAX_TOTAL_CHARS="$(to_nonnegative_int "$NEWSLETTER_HISTORY_MAX_TOTAL_CHARS" 10000)"
NEWSLETTER_LEADERBOARD_LIMIT="$(to_nonnegative_int "$NEWSLETTER_LEADERBOARD_LIMIT" 10)"

# Ensure codex's companion `node` binary is discoverable when run from stripped
# service environments (eg, Limnoria with a minimal PATH).
if [[ "$CODEX_BIN" = /* ]]; then
  CODEX_BIN_DIR="$(dirname "$CODEX_BIN")"
  PATH="$CODEX_BIN_DIR:$PATH"
  export PATH
fi

pick_writable_codex_home() {
  local d=""
  for d in \
    "${CODEX_HOME:-}" \
    "${NEWSLETTER_RUNTIME_DIR}/codex_home" \
    "/dev/shm/newsletter_codex_home"
  do
    [[ -n "$d" ]] || continue
    mkdir -p "$d" 2>/dev/null || continue
    if touch "$d/.write_probe.$$" >/dev/null 2>&1; then
      rm -f "$d/.write_probe.$$" 2>/dev/null || true
      echo "$d"
      return 0
    fi
  done
  return 1
}

if CODEX_HOME="$(pick_writable_codex_home)"; then
  export CODEX_HOME
else
  echo "No writable CODEX_HOME available" >&2
  exit 1
fi

write_codex_config() {
  local network_access
  network_access="$(toml_bool "$CODEX_NETWORK_ACCESS")"

  cat > "$CODEX_HOME/config.toml" <<EOF
cli_auth_credentials_store = "file"
model = "${CODEX_MODEL}"
model_reasoning_effort = "${CODEX_MODEL_REASONING_EFFORT}"
network_access = ${network_access}
EOF

  if [[ -n "${CODEX_WEB_SEARCH:-}" ]]; then
    printf 'web_search = "%s"\n' "$CODEX_WEB_SEARCH" >> "$CODEX_HOME/config.toml"
  fi
}

write_codex_config

if [[ ! -s "$CODEX_HOME/auth.json" ]]; then
  echo "Codex auth unavailable. Bot owner needs to reauthenticate." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

make_tmpdir() {
  local d=""
  for d in \
    "${NEWSLETTER_TMP_DIR:-}" \
    "${STATE_DIR}/tmp" \
    "${NEWSLETTER_RUNTIME_DIR}/tmp" \
    "/dev/shm"
  do
    [[ -n "$d" ]] || continue
    mkdir -p "$d" 2>/dev/null || true
    if tmp="$(mktemp -d -p "$d" newsletter.XXXXXX 2>/dev/null)"; then
      echo "$tmp"
      return 0
    fi
  done
  mktemp -d
}

normalize_paste_url() {
  local url="$1"
  if [[ "$url" =~ ^https?://(pasters\.io|paste\.rs)/[^[:space:]]+$ ]] && [[ ! "$url" =~ \.md$ ]]; then
    printf '%s.md\n' "$url"
  else
    printf '%s\n' "$url"
  fi
}

upload_pasters_io() {
  local file="$1"
  local attempt=1
  local url=""
  local response_file=""
  local http_code=""

  while [[ "$attempt" -le "$PASTE_UPLOAD_RETRIES" ]]; do
    response_file="$(mktemp "$tmpdir/pasters_io_response.XXXXXX")"
    http_code="$(curl -sS \
      --connect-timeout "$PASTE_CONNECT_TIMEOUT" \
      --max-time "$PASTE_UPLOAD_TIMEOUT" \
      -o "$response_file" \
      -w '%{http_code}' \
      --data-binary @"$file" \
      "$PASTERS_IO_ENDPOINT" || true)"

    if [[ "$http_code" == "201" ]]; then
      url="$(tr -d '\r\n' < "$response_file")"
      rm -f "$response_file"
      if [[ "$url" =~ ^https?:// ]]; then
        normalize_paste_url "$url"
        return 0
      fi
      echo "pasters.io upload attempt ${attempt}/${PASTE_UPLOAD_RETRIES} returned an empty or invalid URL" >&2
    elif [[ "$http_code" == "206" ]]; then
      echo "pasters.io upload rejected: response was truncated (HTTP 206)" >&2
      rm -f "$response_file"
      return 1
    else
      echo "pasters.io upload attempt ${attempt}/${PASTE_UPLOAD_RETRIES} failed (HTTP ${http_code:-unknown})" >&2
    fi

    rm -f "$response_file"
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done

  return 1
}

upload_paste_rs() {
  local file="$1"
  local attempt=1
  local url=""

  while [[ "$attempt" -le "$PASTE_UPLOAD_RETRIES" ]]; do
    if url="$(curl -fsSL \
      --connect-timeout "$PASTE_CONNECT_TIMEOUT" \
      --max-time "$PASTE_UPLOAD_TIMEOUT" \
      --data-binary @"$file" \
      "$PASTE_RS_ENDPOINT")"; then
      url="$(printf '%s' "$url" | tr -d '\r\n')"
      if [[ -n "$url" ]]; then
        normalize_paste_url "$url"
        return 0
      fi
    fi
    echo "paste.rs upload attempt ${attempt}/${PASTE_UPLOAD_RETRIES} failed" >&2
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done

  return 1
}

upload_dpaste_preview() {
  local file="$1"
  local attempt=1
  local url=""
  local response_file=""
  local http_code=""

  while [[ "$attempt" -le "$PASTE_UPLOAD_RETRIES" ]]; do
    response_file="$(mktemp "$tmpdir/dpaste_response.XXXXXX")"
    http_code="$(curl -sS \
      -A "newsletter-automation/1.0" \
      --connect-timeout "$PASTE_CONNECT_TIMEOUT" \
      --max-time "$PASTE_UPLOAD_TIMEOUT" \
      -o "$response_file" \
      -w '%{http_code}' \
      -F "syntax=${DPASTE_SYNTAX}" \
      -F "content=<${file}" \
      "$DPASTE_ENDPOINT" || true)"

    if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
      url="$(tr -d '\r\n' < "$response_file")"
      rm -f "$response_file"
      if [[ "$url" =~ ^https?:// ]]; then
        if [[ "$url" != *"${DPASTE_PREVIEW_SUFFIX}" ]]; then
          url="${url}${DPASTE_PREVIEW_SUFFIX}"
        fi
        printf '%s\n' "$url"
        return 0
      fi
    else
      echo "dpaste upload attempt ${attempt}/${PASTE_UPLOAD_RETRIES} failed (HTTP ${http_code:-unknown})" >&2
    fi

    rm -f "$response_file"
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done

  return 1
}

build_history_context() {
  local target_date="$1"
  local history_dir="$2"
  local out_file="$3"
  local entries=()
  local selected=()
  local sorted=()
  local file=""
  local base=""
  local file_date=""
  local item=""
  local idx=0
  local total_chars=0
  local remaining_chars=0
  local allowed_chars=0
  local content=""
  local content_len=0
  local file_len=0

  : > "$out_file"

  if [[ "$NEWSLETTER_HISTORY_COUNT" -eq 0 ]]; then
    return 0
  fi
  if [[ "$NEWSLETTER_HISTORY_MAX_CHARS_PER_FILE" -eq 0 || "$NEWSLETTER_HISTORY_MAX_TOTAL_CHARS" -eq 0 ]]; then
    return 0
  fi
  if [[ ! -d "$history_dir" ]]; then
    return 0
  fi

  shopt -s nullglob
  for file in "$history_dir"/newsletter-*.md; do
    base="$(basename "$file")"
    if [[ "$base" =~ ^newsletter-([0-9]{4}-[0-9]{2}-[0-9]{2})\.md$ ]]; then
      file_date="${BASH_REMATCH[1]}"
      if [[ "$file_date" < "$target_date" ]]; then
        entries+=("${file_date}|${file}")
      fi
    fi
  done
  shopt -u nullglob

  if [[ "${#entries[@]}" -eq 0 ]]; then
    return 0
  fi

  mapfile -t sorted < <(printf '%s\n' "${entries[@]}" | sort -r)

  for ((idx = 0; idx < ${#sorted[@]} && idx < NEWSLETTER_HISTORY_COUNT; idx++)); do
    selected+=("${sorted[$idx]}")
  done

  for ((idx = ${#selected[@]} - 1; idx >= 0; idx--)); do
    item="${selected[$idx]}"
    file_date="${item%%|*}"
    file="${item#*|}"
    [[ -r "$file" ]] || continue

    remaining_chars=$((NEWSLETTER_HISTORY_MAX_TOTAL_CHARS - total_chars))
    if [[ "$remaining_chars" -le 0 ]]; then
      break
    fi

    allowed_chars="$NEWSLETTER_HISTORY_MAX_CHARS_PER_FILE"
    if [[ "$allowed_chars" -gt "$remaining_chars" ]]; then
      allowed_chars="$remaining_chars"
    fi
    if [[ "$allowed_chars" -le 0 ]]; then
      break
    fi

    content="$(head -c "$allowed_chars" "$file" 2>/dev/null || true)"
    [[ -n "$content" ]] || continue

    printf '### %s (%s)\n' "$(basename "$file")" "$file_date" >> "$out_file"
    printf '%s\n\n' "$content" >> "$out_file"

    content_len="${#content}"
    total_chars=$((total_chars + content_len))
    file_len="$(wc -c < "$file" 2>/dev/null || echo 0)"
    if [[ "$file_len" -gt "$allowed_chars" ]]; then
      printf '[truncated]\n\n' >> "$out_file"
    fi
  done
}

render_alias_context() {
  python3 - <<'PY'
import json
import os

raw = os.environ.get("NEWSLETTER_NICK_ALIASES_JSON", "").strip()
if not raw:
    print("None available.")
    raise SystemExit(0)

try:
    alias_map = json.loads(raw)
except Exception:
    print("Unavailable due to invalid alias data.")
    raise SystemExit(0)

if not isinstance(alias_map, dict) or not alias_map:
    print("None available.")
    raise SystemExit(0)

print("Treat these nick variants as the same person:")
for alias, primary in sorted(alias_map.items()):
    alias = str(alias or "").strip()
    primary = str(primary or "").strip()
    if alias and primary:
        print(f"- {alias} -> {primary}")
print("- Merge alias activity when judging chatter, quotes, awards, and recurring behavior.")
PY
}

log_alias_debug() {
  python3 - <<'PY'
import json
import os
import sys

raw = os.environ.get("NEWSLETTER_NICK_ALIASES_JSON", "")
if not raw.strip():
    print("alias_debug: env_present=0 count=0")
    raise SystemExit(0)

try:
    alias_map = json.loads(raw)
except Exception:
    print("alias_debug: env_present=1 count=invalid")
    raise SystemExit(0)

if not isinstance(alias_map, dict):
    print("alias_debug: env_present=1 count=invalid")
    raise SystemExit(0)

print(f"alias_debug: env_present=1 count={len(alias_map)}")
PY
}

render_alias_footer_instruction() {
  python3 - <<'PY'
import json
import os

raw = os.environ.get("NEWSLETTER_NICK_ALIASES_JSON", "").strip()
if not raw:
    print("Do not add a nick alias footer if no aliases were provided.")
    raise SystemExit(0)

try:
    alias_map = json.loads(raw)
except Exception:
    print("Do not add a nick alias footer if alias data is invalid.")
    raise SystemExit(0)

if not isinstance(alias_map, dict) or not alias_map:
    print("Do not add a nick alias footer if no aliases were provided.")
    raise SystemExit(0)

pairs = []
for alias, primary in sorted(alias_map.items()):
    alias = str(alias or "").strip()
    primary = str(primary or "").strip()
    if alias and primary:
        pairs.append(f"{alias} -> {primary}")

if not pairs:
    print("Do not add a nick alias footer if no aliases were provided.")
    raise SystemExit(0)

print(
    "After the closing line, append one final plain line exactly in this format: "
    f"`Nick aliases used: {', '.join(pairs)}`"
)
PY
}

update_leaderboard_artifacts() {
  local markdown_file="$1"
  local leaderboard_file="$2"
  local history_dir="$3"
  local target_date="$4"
  local top_n="$5"
  local dry_run="$6"

  if [[ "$top_n" -eq 0 ]]; then
    return 0
  fi

  python3 - "$markdown_file" "$leaderboard_file" "$history_dir" "$target_date" "$top_n" "$dry_run" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

markdown_path = Path(sys.argv[1])
leaderboard_path = Path(sys.argv[2])
history_dir = Path(sys.argv[3])
target_date = sys.argv[4]
top_n = int(sys.argv[5])
dry_run = sys.argv[6] == "1"


def load_alias_map():
    raw = os.environ.get("NEWSLETTER_NICK_ALIASES_JSON", "").strip()
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except Exception:
        return {}
    if not isinstance(parsed, dict):
        return {}
    alias_map = {}
    for alias, primary in parsed.items():
        alias = str(alias or "").strip().lower()
        primary = str(primary or "").strip().lower()
        if alias and primary:
            alias_map[alias] = primary
    return alias_map


ALIAS_MAP = load_alias_map()
CURRENT_SCHEMA_VERSION = 2
KNOWN_SECTION_HEADINGS = {
    "what happened",
    "best arguments",
    "quotes",
    "quotes (guess the fake)",
    "notable grabs and rq's",
    "stupidest bot interaction",
    "best chatter",
    "worst chatter",
    "honorable mentions",
    "best/worst awards",
    "closing",
    "all-time leaderboard",
}


def clean_winner_line(line: str) -> str:
    line = line.strip()
    line = re.sub(r"^[-*]\s*", "", line)

    backtick_match = re.match(r"^`([^`]+)`", line)
    if backtick_match:
        line = backtick_match.group(1)
    else:
        bold_match = re.match(r"^\*+\s*([^*]+?)\s*\*+", line)
        if bold_match:
            line = bold_match.group(1)
        else:
            split_match = re.match(r"^(.+?)(?:\s*[-–:]\s+.*)?$", line)
            if split_match:
                line = split_match.group(1)

    return line.strip().strip("*`").strip()


def normalize_nick(raw: str) -> str:
    nick = clean_winner_line(raw)
    nick = nick.rstrip("_").strip().lower()
    return ALIAS_MAP.get(nick, nick)


def normalize_heading(line: str) -> str:
    stripped = line.strip()
    if re.match(r"^#{2,6}\s+", stripped):
        stripped = re.sub(r"^#{2,6}\s+", "", stripped)
    elif re.match(r"^\*\*[^*].*[^*]\*\*$", stripped):
        stripped = stripped[2:-2].strip()
    return stripped.lower()


def is_section_heading(line: str, section_name: str) -> bool:
    return normalize_heading(line) == section_name.lower()


def is_any_heading(line: str) -> bool:
    return normalize_heading(line) in KNOWN_SECTION_HEADINGS


def parse_best_worst(text: str, source: str):
    lines = text.splitlines()

    def extract(section_name: str) -> str:
        in_section = False
        for line in lines:
            stripped = line.strip()
            if is_section_heading(line, section_name):
                in_section = True
                continue
            if in_section and is_any_heading(line):
                break
            if in_section and stripped:
                nick = normalize_nick(stripped)
                if nick:
                    return nick
                raise ValueError(f"Could not normalize {section_name} winner in {source}")
        raise ValueError(f"Missing {section_name} section in {source}")

    return {
        "best": extract("Best chatter"),
        "worst": extract("Worst chatter"),
    }


def scan_history(directory: Path):
    by_date = {}
    if not directory.is_dir():
        return by_date
    for path in sorted(directory.glob("newsletter-*.md")):
        match = re.fullmatch(r"newsletter-(\d{4}-\d{2}-\d{2})\.md", path.name)
        if not match:
            continue
        try:
            by_date[match.group(1)] = parse_best_worst(
                path.read_text(encoding="utf-8"), str(path)
            )
        except Exception as exc:
            print(f"leaderboard bootstrap warning: {exc}", file=sys.stderr)
    return by_date


def recompute_totals(by_date):
    totals = {"best": {}, "worst": {}}
    for winners in by_date.values():
        for key in ("best", "worst"):
            nick = winners[key]
            totals[key][nick] = totals[key].get(nick, 0) + 1
    return totals


def load_state():
    if leaderboard_path.is_file():
        try:
            data = json.loads(leaderboard_path.read_text(encoding="utf-8"))
            if data.get("schema_version") != CURRENT_SCHEMA_VERSION:
                raise ValueError("leaderboard schema version mismatch")
            by_date = data.get("by_date")
            if isinstance(by_date, dict):
                normalized = {}
                for date_key, winners in by_date.items():
                    if not isinstance(winners, dict):
                        continue
                    best = normalize_nick(str(winners.get("best", "")))
                    worst = normalize_nick(str(winners.get("worst", "")))
                    if best and worst:
                        normalized[str(date_key)] = {"best": best, "worst": worst}
                if normalized:
                    return {"schema_version": CURRENT_SCHEMA_VERSION, "by_date": normalized}
        except Exception:
            pass
    return {"schema_version": CURRENT_SCHEMA_VERSION, "by_date": scan_history(history_dir)}


def format_leaders(bucket):
    ordered = sorted(bucket.items(), key=lambda item: (-item[1], item[0]))
    if top_n > 0:
        ordered = ordered[:top_n]
    if not ordered:
        return "none yet."
    return ", ".join(f"`{nick}` ({count})" for nick, count in ordered)


def remove_existing_leaderboard(lines):
    out = []
    skipping = False
    for line in lines:
        stripped = line.strip().lower()
        if stripped == "### all-time leaderboard":
            skipping = True
            continue
        if skipping and line.startswith("### "):
            skipping = False
        if not skipping:
            out.append(line)
    while out and not out[-1].strip():
        out.pop()
    return out


def inject_leaderboard(text: str, section: str) -> str:
    lines = text.splitlines()
    alias_footer = None
    while lines and not lines[-1].strip():
        lines.pop()
    if lines and lines[-1].startswith("Nick aliases used:"):
        alias_footer = lines.pop()
        while lines and not lines[-1].strip():
            lines.pop()

    body_lines = remove_existing_leaderboard(lines)
    rebuilt = list(body_lines)
    if rebuilt:
        rebuilt.append("")
    rebuilt.extend(section.splitlines())
    if alias_footer:
        rebuilt.append("")
        rebuilt.append(alias_footer)
    return "\n".join(rebuilt) + "\n"


state = load_state()
current = parse_best_worst(markdown_path.read_text(encoding="utf-8"), str(markdown_path))
state["by_date"][target_date] = current
state["totals"] = recompute_totals(state["by_date"])

leaderboard_section = "\n".join(
    [
        "### All-time leaderboard",
        "",
        f"**Best chatter**: {format_leaders(state['totals']['best'])}",
        "",
        f"**Worst chatter**: {format_leaders(state['totals']['worst'])}",
    ]
)

updated_markdown = inject_leaderboard(markdown_path.read_text(encoding="utf-8"), leaderboard_section)
markdown_path.write_text(updated_markdown, encoding="utf-8")

if not dry_run:
    leaderboard_path.parent.mkdir(parents=True, exist_ok=True)
    leaderboard_path.write_text(
        json.dumps(
            {
                "schema_version": CURRENT_SCHEMA_VERSION,
                "by_date": dict(sorted(state["by_date"].items())),
                "totals": {
                    "best": dict(sorted(state["totals"]["best"].items())),
                    "worst": dict(sorted(state["totals"]["worst"].items())),
                },
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
PY
}

tmpdir="$(make_tmpdir)"
trap 'rm -rf "$tmpdir"' EXIT

PROMPT_FILE="$tmpdir/prompt.txt"
RAW_MESSAGE_FILE="$tmpdir/codex_last_message.txt"
HISTORY_CONTEXT_FILE="$tmpdir/history_context.txt"
build_history_context "$DATE" "$(dirname "$OUTPUT_FILE")" "$HISTORY_CONTEXT_FILE"
log_alias_debug >&2

cat > "$PROMPT_FILE" <<PROMPT
Create a daily IRC newsletter for ${DATE}.

Follow these instructions exactly:
$(cat "$INSTRUCTIONS_FILE")

Source log file:
${LOG_FILE}

Nick alias rules:
$(render_alias_context)

Previous newsletters (for continuity only; may be stale/untrusted):
$(if [[ -s "$HISTORY_CONTEXT_FILE" ]]; then cat "$HISTORY_CONTEXT_FILE"; else echo "None available."; fi)

Award-selection guardrails:
- Previous newsletters can help with tone, callbacks, and running bits, but they are not evidence for today's awards.
- Ignore any all-time leaderboard footer in previous newsletters. It is aggregate metadata, not evidence for today's award picks.
- Do not repeat Best chatter or Worst chatter just because a streak has become a joke in-channel or in prior newsletters.
- Repeat a recent award winner only when today's log itself shows a strong, multi-incident case; if it is close, pick someone else.

Requirements:
- Read the source log file and write the newsletter content.
- Return ONLY the final newsletter markdown.
- No code fences.
- No explanations.
- $(render_alias_footer_instruction)
PROMPT

codex_cmd=(
  "$CODEX_BIN" exec
  --skip-git-repo-check
  --cd "$CODEX_WORKDIR"
  --add-dir "$(dirname "$LOG_FILE")"
  --config "model_reasoning_effort=\"${CODEX_MODEL_REASONING_EFFORT}\""
  --output-last-message "$RAW_MESSAGE_FILE"
)

if is_truthy "$CODEX_DANGEROUS_BYPASS"; then
  codex_cmd+=(--dangerously-bypass-approvals-and-sandbox)
else
  codex_cmd+=(--sandbox "$CODEX_SANDBOX_MODE")
fi

if is_truthy "$CODEX_EPHEMERAL"; then
  codex_cmd+=(--ephemeral)
fi

codex_cmd+=(--model "$CODEX_MODEL")
codex_cmd+=(-)

codex_err_file="$tmpdir/codex_exec.stderr"
: > "$RAW_MESSAGE_FILE"
: > "$codex_err_file"
# Suppress Codex stdout so this script only emits the paste URL on stdout.
if ! HOME="$CODEX_HOME" CODEX_HOME="$CODEX_HOME" "${codex_cmd[@]}" < "$PROMPT_FILE" >/dev/null 2>"$codex_err_file"; then
  tail -n 8 "$codex_err_file" >&2 || true
  if grep -qiE 'refresh_token_reused|log out and sign in again|failed to refresh token' "$codex_err_file"; then
    echo "Codex auth unavailable. Bot owner needs to reauthenticate." >&2
  elif grep -qi 'stream disconnected before completion' "$codex_err_file"; then
    echo "Codex request failed: stream disconnected before completion." >&2
  else
    echo "Codex generation failed." >&2
  fi
  exit 1
fi

if [[ ! -s "$RAW_MESSAGE_FILE" ]]; then
  tail -n 8 "$codex_err_file" >&2 || true
  if grep -qi 'stream disconnected before completion' "$codex_err_file"; then
    echo "Codex request failed: stream disconnected before completion." >&2
  else
    echo "Codex produced no assistant message." >&2
  fi
  exit 1
fi

# Strip accidental fenced blocks if model includes them.
sed '/^```/d' "$RAW_MESSAGE_FILE" > "$OUTPUT_FILE"

update_leaderboard_artifacts \
  "$OUTPUT_FILE" \
  "$NEWSLETTER_LEADERBOARD_FILE" \
  "$(dirname "$OUTPUT_FILE")" \
  "$DATE" \
  "$NEWSLETTER_LEADERBOARD_LIMIT" \
  "$DRY_RUN"

if [[ "$NO_UPLOAD" -eq 1 ]]; then
  exit 0
fi

pasters_io_url=""
paste_rs_url=""
dpaste_url=""

if [[ -n "$PASTERS_IO_ENDPOINT" ]]; then
  pasters_io_url="$(upload_pasters_io "$OUTPUT_FILE" || true)"
fi

if [[ -n "$PASTE_RS_ENDPOINT" ]]; then
  paste_rs_url="$(upload_paste_rs "$OUTPUT_FILE" || true)"
fi

if [[ -n "$DPASTE_ENDPOINT" ]]; then
  dpaste_url="$(upload_dpaste_preview "$OUTPUT_FILE" || true)"
fi

urls=()
[[ -n "$pasters_io_url" ]] && urls+=("$pasters_io_url")
[[ -n "$paste_rs_url" ]] && urls+=("$paste_rs_url")
[[ -n "$dpaste_url" ]] && urls+=("$dpaste_url")

if [[ "${#urls[@]}" -gt 0 ]]; then
  output="${urls[0]}"
  for ((i = 1; i < ${#urls[@]}; i++)); do
    output+=" (${urls[$i]})"
  done
  echo "$output"
  exit 0
fi

echo "Failed to upload newsletter to configured paste hosts" >&2
exit 1
