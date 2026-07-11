# AGENTS.md - Newsletter Automation Project

## Scope
This AGENTS file applies to everything under `IRCBot/plugins/Newsletter/`.

## Purpose
This project exists to generate and publish `##debate2016` daily newsletters and expose that flow through Limnoria via `@newsletter`.

## Runtime Rules
- Keep the Limnoria plugin thin. It should orchestrate, not generate content.
- Keep generation logic in shell scripts.
- Keep voice/tone in `newsletter_instructions.md` so edits do not require code changes.
- Prefer deterministic behavior: idempotency, lockfile, explicit date handling.

## Inputs / Outputs
- Input log source should be configured via env (`CHANNEL_LOG_DIR`, `NEWSLETTER_CHANNEL`).
- Output markdown goes to `data/output/newsletter-YYYY-MM-DD.md`.
- Output URL goes to `data/output/newsletter-YYYY-MM-DD.url`.

## Safety / Operations
- Do not post duplicate newsletters for the same day unless `--force` is used.
- Any automation command must return machine-readable JSON for plugin parsing.
- Fail fast with explicit errors when log file is missing.
- Runtime writes live under `data/` (`data/output`, `data/state`, `data/logs`, `data/tmp`, `data/codex_home`).
- Newsletter uses a plugin-local Codex auth home, not Nelluk's normal `~/.codex` login. Refresh auth with:
  `CODEX_HOME=/home/nelluk/IRCBot/plugins/Newsletter/data/codex_home /home/nelluk/.nvm/versions/node/v20.20.0/bin/codex login --device-auth`
- Treat `data/codex_home/auth.json` like a password; do not paste it into chat, logs, commits, or tickets.
- Operational run artifacts live under `data/logs` (`*.json` status payloads and `*.stderr.log` generation traces).
- `@reload Newsletter` updates plugin/module state, but if behavior appears stale after interpreter/package upgrades, verify process executable mappings; a full bot restart may be required.
- Prefer PM testing (`@newsletter` in private message) until behavior is validated, then test channel invocation.
- Posting should attempt `pasters.io`, `paste.rs`, and `dpaste`; if one host fails, still return the surviving URL and only fail the run when all configured uploads fail.
