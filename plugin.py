"""Newsletter Limnoria plugin."""

import json
import os
import re
import subprocess
from datetime import datetime, timedelta

import supybot.callbacks as callbacks
import supybot.ircdb as ircdb
from supybot.commands import getopts, optional, wrap


DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
PASTE_URL_RE = re.compile(
    r"(https?://(?:pasters\.io|paste\.rs|dpaste\.com)/[^\s)]+)"
)
DATE_IN_PATH_RE = re.compile(r"newsletter-(\d{4}-\d{2}-\d{2})\.md$")
START_ANNOUNCE_DELAY_SECONDS = 1.0


class Newsletter(callbacks.Plugin):
    """Generate or fetch a daily newsletter URL."""

    threaded = True

    def _parse_payload(self, text):
        text = (text or "").strip()
        if not text:
            return None
        for line in reversed(text.splitlines()):
            line = line.strip()
            if not line:
                continue
            try:
                return json.loads(line)
            except Exception:
                continue
        return None

    def _normalize_url(self, url):
        url = (url or "").strip()
        if not url:
            return ""
        if (
            re.match(r"^https?://(?:pasters\.io|paste\.rs)/[^\s]+$", url)
            and not url.endswith(".md")
        ):
            return f"{url}.md"
        return url

    def _extract_url(self, text):
        text = (text or "").strip()
        if not text:
            return ""
        for line in reversed(text.splitlines()):
            match = PASTE_URL_RE.search(line.strip())
            if match:
                return self._normalize_url(match.group(1))
        return ""

    def _effective_date(self, payload, date_str):
        payload_date = payload.get("date") or date_str
        if payload_date and DATE_RE.match(payload_date):
            return payload_date

        md_path = payload.get("markdown", "")
        md_base = os.path.basename(md_path or "")
        match = DATE_IN_PATH_RE.search(md_base)
        if match:
            return match.group(1)

        return "requested date"

    def _display_markdown_path(self, md_path):
        md_path = (md_path or "").strip()
        if not md_path:
            return ""

        marker = "plugins/"
        idx = md_path.find(marker)
        if idx != -1:
            return md_path[idx:]
        return md_path

    def _load_env_values(self, script_path):
        project_root = os.path.dirname(os.path.dirname(script_path))
        env_file = os.environ.get(
            "NEWSLETTER_ENV", os.path.join(project_root, "config", "newsletter.env")
        )
        values = {}
        if not os.path.isfile(env_file):
            return values
        try:
            with open(env_file, "r", encoding="utf-8") as handle:
                for raw in handle:
                    line = raw.strip()
                    if not line or line.startswith("#"):
                        continue
                    if line.startswith("export "):
                        line = line[len("export ") :].strip()
                    if "=" not in line:
                        continue
                    key, value = line.split("=", 1)
                    key = key.strip()
                    value = value.strip()
                    if (
                        len(value) >= 2
                        and value[0] == value[-1]
                        and value[0] in ('"', "'")
                    ):
                        value = value[1:-1]
                    if key:
                        values[key] = value
        except Exception:
            return {}
        return values

    def _default_target_date(self, tz_name):
        tz_name = tz_name or "UTC"
        try:
            from zoneinfo import ZoneInfo

            return (datetime.now(ZoneInfo(tz_name)) - timedelta(days=1)).strftime(
                "%Y-%m-%d"
            )
        except Exception:
            return (datetime.utcnow() - timedelta(days=1)).strftime("%Y-%m-%d")

    def _preflight_has_log(self, script_path, date_str):
        values = self._load_env_values(script_path)
        log_dir = (values.get("CHANNEL_LOG_DIR") or "").strip()
        if not log_dir:
            return None

        channel = (values.get("NEWSLETTER_CHANNEL") or "##debate2016").strip()
        tz_name = (values.get("NEWSLETTER_TZ") or "UTC").strip()
        target_date = date_str or self._default_target_date(tz_name)
        if not DATE_RE.match(target_date):
            return None

        candidates = [
            os.path.join(log_dir, f"{channel}.{target_date}.log"),
            os.path.join(log_dir, f"{target_date}.log"),
            os.path.join(log_dir, f"{target_date}_LiberaZNC.txt"),
        ]
        return any(os.path.isfile(path) for path in candidates)

    def _get_repostcount_alias_map(self, irc):
        try:
            repostcount = irc.getCallback("RepostCount")
        except Exception:
            return {}

        if repostcount is None:
            return {}

        alias_map = getattr(repostcount, "alias_map", {})
        if not isinstance(alias_map, dict):
            return {}

        normalized = {}
        for alias, primary in alias_map.items():
            alias = str(alias or "").strip().lower()
            primary = str(primary or "").strip().lower()
            if alias and primary:
                normalized[alias] = primary
        return normalized

    def _run_script(
        self,
        force=False,
        dry_run=False,
        date_str=None,
        alias_map=None,
        announce_start=False,
        start_message="",
        announce_callback=None,
    ):
        script_path = self.registryValue("scriptPath")
        timeout = self.registryValue("timeoutSeconds")

        cmd = [script_path]
        if date_str:
            cmd.extend(["--date", date_str])
        if force:
            cmd.append("--force")
        if dry_run:
            cmd.append("--dry-run")

        env = os.environ.copy()
        if alias_map:
            env["NEWSLETTER_NICK_ALIASES_JSON"] = json.dumps(
                alias_map, sort_keys=True
            )
        else:
            env.pop("NEWSLETTER_NICK_ALIASES_JSON", None)

        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        stdout = ""
        stderr = ""

        try:
            if announce_start and timeout > START_ANNOUNCE_DELAY_SECONDS:
                try:
                    stdout, stderr = proc.communicate(timeout=START_ANNOUNCE_DELAY_SECONDS)
                except subprocess.TimeoutExpired:
                    if announce_callback and start_message:
                        announce_callback(start_message)
                    remaining_timeout = max(timeout - START_ANNOUNCE_DELAY_SECONDS, 1.0)
                    stdout, stderr = proc.communicate(timeout=remaining_timeout)
            else:
                stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            raise

        stdout = (stdout or "").strip()
        stderr = (stderr or "").strip()

        payload = self._parse_payload(stdout) or self._parse_payload(stderr)

        # The runner returns JSON payloads for non-zero statuses like "busy".
        if payload is not None:
            url = self._normalize_url(payload.get("url", ""))
            if url:
                payload["url"] = url
            return payload

        # Compatibility path: older runner variants may emit only a URL on stdout.
        if proc.returncode == 0:
            url = self._extract_url(stdout) or self._extract_url(stderr)
            if url:
                return {
                    "status": "generated",
                    "date": date_str or "",
                    "url": url,
                    "markdown": "",
                    "message": "Generated and posted",
                }

        if proc.returncode != 0:
            detail = stderr or stdout or f"exit code {proc.returncode}"
            raise RuntimeError(detail)

        raise RuntimeError(f"invalid script output: {stdout}")

    def newsletter(self, irc, msg, args, opts, date_str):
        """[--force] [--dry-run] [<YYYY-MM-DD>]

        Returns cached newsletter URL for date, or generates and posts a new one.
        Default date is handled by runner script (usually yesterday in configured TZ).
        """

        allowed_channel = self.registryValue("allowedChannel")
        if allowed_channel and irc.isChannel(msg.args[0]) and msg.args[0] != allowed_channel:
            irc.reply(f"Command restricted to {allowed_channel}")
            return

        flags = {key for (key, _) in opts}
        force = "force" in flags
        dry_run = "dry-run" in flags

        if force and not ircdb.checkCapability(msg.prefix, "owner"):
            irc.error("The --force option is limited to the bot owner.", Raise=True)

        if force and not self.registryValue("allowForce"):
            irc.reply("force mode disabled")
            return

        if date_str and not DATE_RE.match(date_str):
            irc.reply("Date must be YYYY-MM-DD")
            return

        script_path = self.registryValue("scriptPath")
        if not os.path.isfile(script_path):
            irc.reply("newsletter runner script not found")
            return

        has_log = self._preflight_has_log(script_path, date_str)
        if has_log is False:
            irc.reply("newsletter error: Log file not found in CHANNEL_LOG_DIR")
            return

        alias_map = self._get_repostcount_alias_map(irc)

        try:
            payload = self._run_script(
                force=force,
                dry_run=dry_run,
                date_str=date_str,
                alias_map=alias_map,
                announce_start=self.registryValue("announceStart"),
                start_message=self.registryValue("startMessage"),
                announce_callback=irc.reply,
            )
        except subprocess.TimeoutExpired:
            irc.reply("newsletter generation timed out")
            return
        except Exception as exc:
            # If runner JSON leaked through exception text, still return a clean status.
            payload = self._parse_payload(str(exc))
            if payload and payload.get("status") == "busy":
                irc.reply("newsletter busy: Another newsletter job is running")
                return
            irc.reply(f"newsletter error: {exc}")
            return

        status = payload.get("status", "")
        url = self._normalize_url(payload.get("url", ""))
        md_path = payload.get("markdown", "")
        display_md_path = self._display_markdown_path(md_path)
        payload_date = self._effective_date(payload, date_str)

        if status in ("cached", "generated") and url:
            irc.reply(f"Here is the channel newsletter for {payload_date}: {url}")
            return

        if status == "dry-run":
            if url:
                irc.reply(
                    f"dry-run complete for {payload_date}: {url} ({display_md_path})"
                )
            else:
                irc.reply(f"dry-run complete: {display_md_path}")
            return

        if status == "busy":
            irc.reply("newsletter busy: Another newsletter job is running")
            return

        message = payload.get("message", "unknown error")
        irc.reply(f"newsletter {status}: {message}")

    newsletter = wrap(
        newsletter,
        [
            getopts({"force": "", "dry-run": ""}),
            optional("something"),
        ],
    )


Class = Newsletter

# vim:set shiftwidth=4 softtabstop=4 expandtab textwidth=79:
