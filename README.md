# Limnoria Newsletter

Opinionated daily newsletter generation for a Limnoria IRC channel.

This plugin was built for `##debate2016`: it reads one day of IRC logs, asks
Codex to produce a terse roast-style markdown newsletter, uploads the result to
paste hosts, and replies from Limnoria with the URL through `@newsletter`.

It is deliberately specific. Treat it as both a usable plugin and an example of
how to wire a Limnoria command to a deterministic shell workflow plus an
editable prompt file. The easiest way to adapt it is to change
`newsletter_instructions.md`, `NEWSLETTER_CHANNEL`, and `CHANNEL_LOG_DIR`.

## Features

- Limnoria command: `@newsletter [--force] [--dry-run] [YYYY-MM-DD]`
- Idempotent daily output under `data/output/`
- Machine-readable JSON from the shell runner for plugin parsing
- Locking to avoid overlapping runs
- Explicit date handling with configurable timezone
- Prompt/tone separated into `newsletter_instructions.md`
- Schema-constrained Codex output with validated award winners
- Optional prior-newsletter continuity context
- Deterministic all-time Best/Worst chatter leaderboard
- Upload attempts to `pasters.io`, `paste.rs`, and `dpaste`

## Repository Layout

- `plugin.py`, `config.py`, `__init__.py`: Limnoria plugin files
- `scripts/run_newsletter.sh`: idempotent runner and JSON status emitter
- `scripts/generate_with_codex.sh`: Codex generation and upload worker
- `scripts/process_newsletter_output.py`: deterministic validation and rendering
- `newsletter_instructions.md`: channel-specific voice and structure
- `config/newsletter-output.schema.json`: Codex structured-output contract
- `config/newsletter.env.example`: environment template
- `ops/cron.example`: scheduled-run example
- `data/`: ignored runtime state, output, logs, temp files, and Codex home

## Install

Clone or copy this directory into your Limnoria plugin path as `Newsletter`,
then load it:

```irc
@load Newsletter
```

Configure the runner path if Limnoria did not resolve it correctly:

```irc
@config plugins.Newsletter.scriptPath /path/to/Newsletter/scripts/run_newsletter.sh
```

For the original channel behavior:

```irc
@config plugins.Newsletter.allowedChannel ##debate2016
```

Set `allowedChannel` to an empty string if you want the command available
wherever the bot can receive it.

## Environment

Create a local env file:

```bash
cp config/newsletter.env.example config/newsletter.env
```

Edit at least:

```dotenv
CHANNEL_LOG_DIR=/path/to/limnoria/logs/ChannelLogger/libera/##debate2016
```

The runner supports these log filenames:

- `##debate2016.YYYY-MM-DD.log`
- `YYYY-MM-DD.log`
- `YYYY-MM-DD_LiberaZNC.txt`

Most runtime paths default to directories under `data/`, so they usually do
not need to be set.

## Codex Setup

The generator uses the Codex CLI. Install and authenticate Codex for the bot
host, then create a plugin-local auth store:

```bash
CODEX_HOME=/path/to/Newsletter/data/codex_home codex login --device-auth
```

The checked-in env example uses public-safe Codex execution settings:

```dotenv
CODEX_DANGEROUS_BYPASS=0
CODEX_SANDBOX_MODE=workspace-write
CODEX_NETWORK_ACCESS=false
CODEX_WEB_SEARCH=
CODEX_EPHEMERAL=1
```

Existing private installs that do not define those variables keep the previous
Codex behavior for compatibility. New public installs should keep the safer
example settings unless they understand the tradeoff.

## Usage

From IRC:

```irc
@newsletter
@newsletter 2026-02-08
@newsletter --dry-run 2026-02-08
@newsletter --force 2026-02-08
```

From the shell:

```bash
scripts/run_newsletter.sh --date 2026-02-08 --dry-run
scripts/run_newsletter.sh --date 2026-02-08
scripts/run_newsletter.sh --date 2026-02-08 --no-upload
```

Script stdout is always JSON. Successful generated, cached, and dry-run runs
include `date`, `markdown`, `message`, and usually `url`.

`--no-upload` writes markdown but skips paste hosts. In that mode `url` is
empty by design.

Codex returns a schema-constrained JSON envelope whose Markdown field remains
free-form and follows `newsletter_instructions.md`. Best/Worst chatter winners
and their model-written reasons are separate structured fields. Before anything
is published, the processor verifies that both winners spoke in the source log,
applies configured aliases, rejects excluded nicks, and inserts the award
sections and leaderboard deterministically. Validation failures publish nothing
and leave leaderboard state unchanged.

## Configuration Reference

Environment values come from `config/newsletter.env` unless overridden by the
process environment.

Required:

- `CHANNEL_LOG_DIR`: directory containing source channel logs

Date and input:

- `NEWSLETTER_TZ`: timezone used when no date is supplied, default `UTC`
- `NEWSLETTER_CHANNEL`: channel name used for log discovery, default `##debate2016`
- `INSTRUCTIONS_FILE`: prompt/style file, default `newsletter_instructions.md`

Codex:

- `CODEX_BIN`: Codex CLI path, default `codex`
- `CODEX_MODEL`: model passed to `codex exec --model`, default `gpt-5.6-terra`
- `CODEX_MODEL_REASONING_EFFORT`: default `high`
- `CODEX_WORKDIR`: Codex working directory, default project root
- `CODEX_HOME`: plugin-local Codex home, default `data/codex_home`
- `CODEX_DANGEROUS_BYPASS`: set `1` to pass `--dangerously-bypass-approvals-and-sandbox`
- `CODEX_SANDBOX_MODE`: sandbox mode when bypass is disabled, default `workspace-write`
- `CODEX_NETWORK_ACCESS`: `true` or `false` in Codex config
- `CODEX_WEB_SEARCH`: optional Codex `web_search` config value, for example `live`
- `CODEX_EPHEMERAL`: set `1` to avoid persisting Codex session files

Output and runtime:

- `OUTPUT_DIR`: generated markdown and URL files, default `data/output`
- `STATE_DIR`: lock and state files, default `data/state`
- `NEWSLETTER_RUNTIME_DIR`: runtime parent, default `data`
- `NEWSLETTER_LOG_DIR`: run JSON and stderr traces, default `data/logs`
- `NEWSLETTER_TMP_DIR`: temp workspace, default `data/tmp`
- `NEWSLETTER_LOCK_FILE`: optional explicit lock file

Continuity:

- `NEWSLETTER_HISTORY_COUNT`: prior newsletters to include, default `3`
- `NEWSLETTER_HISTORY_MAX_CHARS_PER_FILE`: default `4000`
- `NEWSLETTER_HISTORY_MAX_TOTAL_CHARS`: default `10000`

Leaderboard:

- `NEWSLETTER_LEADERBOARD_FILE`: default `data/state/leaderboard.json`
- `NEWSLETTER_LEADERBOARD_LIMIT`: rendered entries per bucket, default `10`; set `0` to disable
- `NEWSLETTER_OUTPUT_SCHEMA_FILE`: default `config/newsletter-output.schema.json`
- `NEWSLETTER_AWARD_EXCLUDED_NICKS`: comma-separated nicks that cannot win; default `ne2,HenryClay`

`leaderboard.json` stores the authoritative per-date winners. Display totals are
recomputed from those records on every run. State is never reconstructed by
parsing old newsletter prose; missing or invalid historical state fails closed.

Run structured-output regression tests with:

```bash
python3 -m unittest discover -s tests -v
```

Upload:

- `PASTERS_IO_ENDPOINT`: default `https://pasters.io/`; empty disables pasters.io
- `PASTE_RS_ENDPOINT`: default `https://paste.rs`; empty disables paste.rs
- `DPASTE_ENDPOINT`: default `https://dpaste.com/api/v2/`; empty disables dpaste
- `PASTE_UPLOAD_TIMEOUT`: default `20`
- `PASTE_CONNECT_TIMEOUT`: default `5`
- `PASTE_UPLOAD_RETRIES`: default `3`
- `DPASTE_SYNTAX`: default `md`
- `DPASTE_PREVIEW_SUFFIX`: default `-preview`

Limnoria registry values:

- `plugins.Newsletter.scriptPath`: runner script path
- `plugins.Newsletter.timeoutSeconds`: max runner runtime, default `900`
- `plugins.Newsletter.allowForce`: owner-only force toggle, default `True`
- `plugins.Newsletter.allowedChannel`: channel restriction, default `##debate2016`
- `plugins.Newsletter.announceStart`: send a working message for longer runs
- `plugins.Newsletter.startMessage`: working message text

## Publishing From A Private Checkout

For a clean public release, prefer a fresh repository history instead of
pushing a private repo directly:

```bash
git clone --no-local /path/to/private/Newsletter /tmp/newsletter-public
cd /tmp/newsletter-public
rm -rf .git data config/newsletter.env __pycache__
git init
git add .
git commit -m "Initial public release"
```

Review ignored files before publishing. `data/` can contain generated
newsletters, logs, Codex sessions, and `auth.json`; it must stay out of the
public repository.

## License

MIT. See `LICENSE`.
