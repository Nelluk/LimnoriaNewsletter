#!/usr/bin/env python3
"""Regression tests for structured newsletter generation and state handling."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PROCESSOR = PROJECT_ROOT / "scripts/process_newsletter_output.py"
GENERATOR = PROJECT_ROOT / "scripts/generate_with_codex.sh"
INSTRUCTIONS = PROJECT_ROOT / "newsletter_instructions.md"


class StructuredOutputTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.raw = self.root / "response.json"
        self.log = self.root / "channel.log"
        self.output = self.root / "output/newsletter-2099-01-01.md"
        self.state = self.root / "state/leaderboard.json"
        self.history = self.output.parent
        self.log.write_text(
            "2099-01-01T10:00:00  <Ash-> useful post\n"
            "2099-01-01T10:01:00  <thero_> terrible post\n"
            "2099-01-01T10:02:00  <HenryClay> bot output\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def response(self, **overrides: object) -> dict:
        value = {
            "newsletter_markdown": (
                "##debate2016 - 2099-01-01\n\n"
                "Quiet channel. Loud mistakes.\n\n"
                "### What happened\n\n- Something happened. Regrettably.\n\n"
                "<!-- CHATTER_AWARDS -->\n\n"
                "### Honorable mentions\n\n- Nobody earned one.\n\n"
                "End of log. End of patience."
            ),
            "best_chatter": {"nick": "Ash-", "reason": "was briefly useful."},
            "worst_chatter": {"nick": "thero_", "reason": "kept posting anyway."},
        }
        value.update(overrides)
        return value

    def run_processor(
        self, response: dict | str, *, dry_run: bool = False, env: dict | None = None
    ) -> subprocess.CompletedProcess[str]:
        if isinstance(response, str):
            self.raw.write_text(response, encoding="utf-8")
        else:
            self.raw.write_text(json.dumps(response), encoding="utf-8")
        command = [
            "python3",
            str(PROCESSOR),
            "--raw-response",
            str(self.raw),
            "--log-file",
            str(self.log),
            "--output",
            str(self.output),
            "--leaderboard-file",
            str(self.state),
            "--history-dir",
            str(self.history),
            "--date",
            "2099-01-01",
            "--channel",
            "##debate2016",
            "--top-n",
            "10",
        ]
        if dry_run:
            command.append("--dry-run")
        run_env = os.environ.copy()
        run_env.pop("NEWSLETTER_NICK_ALIASES_JSON", None)
        run_env.pop("NEWSLETTER_AWARD_EXCLUDED_NICKS", None)
        if env:
            run_env.update(env)
        return subprocess.run(
            command, text=True, capture_output=True, env=run_env, check=False
        )

    def test_renders_free_markdown_and_structured_awards(self) -> None:
        result = self.run_processor(self.response())
        self.assertEqual(result.returncode, 0, result.stderr)
        rendered = self.output.read_text(encoding="utf-8")
        self.assertIn("Quiet channel. Loud mistakes.", rendered)
        self.assertIn("### Best chatter\n\n`Ash-` — was briefly useful.", rendered)
        self.assertIn("### Worst chatter\n\n`thero_` — kept posting anyway.", rendered)
        self.assertNotIn("CHATTER_AWARDS", rendered)
        state = json.loads(self.state.read_text(encoding="utf-8"))
        self.assertEqual(state["schema_version"], 3)
        self.assertNotIn("totals", state)
        self.assertEqual(
            state["by_date"]["2099-01-01"],
            {"best": "ash-", "worst": "thero"},
        )

    def test_aliases_are_validated_and_rendered_deterministically(self) -> None:
        response = self.response(
            best_chatter={"nick": "berkchops", "reason": "managed competence."}
        )
        self.log.write_text(
            self.log.read_text(encoding="utf-8")
            + "2099-01-01T10:03:00  <iChops> alias post\n",
            encoding="utf-8",
        )
        result = self.run_processor(
            response,
            env={"NEWSLETTER_NICK_ALIASES_JSON": '{"ichops":"berkchops"}'},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        rendered = self.output.read_text(encoding="utf-8")
        self.assertIn("`berkchops` — managed competence.", rendered)
        self.assertTrue(rendered.rstrip().endswith("Nick aliases used: ichops -> berkchops"))

    def test_schema_v2_state_is_backed_up_and_migrated(self) -> None:
        self.state.parent.mkdir(parents=True)
        original = {
            "schema_version": 2,
            "by_date": {"2098-12-31": {"best": "ash-", "worst": "thero"}},
            "totals": {"best": {"ash-": 1}, "worst": {"thero": 1}},
        }
        self.state.write_text(json.dumps(original), encoding="utf-8")
        result = self.run_processor(self.response())
        self.assertEqual(result.returncode, 0, result.stderr)
        backup = self.state.with_name("leaderboard.json.schema-v2.bak")
        self.assertEqual(json.loads(backup.read_text(encoding="utf-8")), original)
        migrated = json.loads(self.state.read_text(encoding="utf-8"))
        self.assertEqual(migrated["schema_version"], 3)
        self.assertEqual(len(migrated["by_date"]), 2)

    def test_dry_run_does_not_write_state(self) -> None:
        result = self.run_processor(self.response(), dry_run=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.output.is_file())
        self.assertFalse(self.state.exists())

    def test_validation_failures_leave_artifacts_untouched(self) -> None:
        self.output.parent.mkdir(parents=True)
        self.state.parent.mkdir(parents=True)
        self.output.write_text("old output\n", encoding="utf-8")
        self.state.write_text("old state\n", encoding="utf-8")
        cases = [
            "not json",
            self.response(newsletter_markdown="##debate2016 - 2099-01-01\nNo marker."),
            self.response(
                newsletter_markdown=(
                    "##debate2016 - 2099-01-01\n"
                    "<!-- CHATTER_AWARDS -->\n<!-- CHATTER_AWARDS -->"
                )
            ),
            self.response(
                newsletter_markdown=(
                    "##debate2016 - 2099-01-01\n<!-- CHATTER_AWARDS -->\n"
                    "### Best chatter\nduplicate"
                )
            ),
            self.response(best_chatter={"nick": "HenryClay", "reason": "bot."}),
            self.response(best_chatter={"nick": "missing", "reason": "not here."}),
            self.response(worst_chatter={"nick": "Ash-", "reason": "same person."}),
            self.response(extra="field"),
            {
                "newsletter_markdown": self.response()["newsletter_markdown"],
                "best_chatter": self.response()["best_chatter"],
            },
        ]
        for case in cases:
            with self.subTest(case=case):
                result = self.run_processor(case)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.output.read_text(encoding="utf-8"), "old output\n")
                self.assertEqual(self.state.read_text(encoding="utf-8"), "old state\n")

    def test_missing_state_with_history_refuses_prose_bootstrap(self) -> None:
        self.output.parent.mkdir(parents=True)
        historical = self.output.parent / "newsletter-2098-12-31.md"
        historical.write_text("### Best chatter\n\n`fake`\n", encoding="utf-8")
        result = self.run_processor(self.response())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to rebuild from prose", result.stderr)
        self.assertFalse(self.state.exists())

    def test_invalid_alias_or_state_fails_closed(self) -> None:
        result = self.run_processor(
            self.response(), env={"NEWSLETTER_NICK_ALIASES_JSON": "not-json"}
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

        self.state.parent.mkdir(parents=True)
        self.state.write_text("not-json", encoding="utf-8")
        result = self.run_processor(self.response())
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.state.read_text(encoding="utf-8"), "not-json")

    def test_generator_uses_structured_output_end_to_end(self) -> None:
        fake_codex = self.root / "fake-codex"
        fake_codex.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "output=''\n"
            "while [[ $# -gt 0 ]]; do\n"
            "  if [[ $1 == --output-last-message ]]; then output=$2; shift 2; else shift; fi\n"
            "done\n"
            "printf '%s\\n' \"$FAKE_CODEX_MESSAGE\" > \"$output\"\n",
            encoding="utf-8",
        )
        fake_codex.chmod(0o755)
        codex_home = self.root / "codex-home"
        codex_home.mkdir()
        (codex_home / "auth.json").write_text('{"test":true}\n', encoding="utf-8")
        output = self.root / "generated/newsletter-2099-01-01.md"
        env = os.environ.copy()
        env.update(
            {
                "NEWSLETTER_ENV": str(self.root / "missing.env"),
                "CODEX_BIN": str(fake_codex),
                "CODEX_HOME": str(codex_home),
                "NEWSLETTER_RUNTIME_DIR": str(self.root / "runtime"),
                "STATE_DIR": str(self.root / "generator-state"),
                "NEWSLETTER_LEADERBOARD_FILE": str(
                    self.root / "generator-state/leaderboard.json"
                ),
                "NEWSLETTER_HISTORY_COUNT": "0",
                "FAKE_CODEX_MESSAGE": json.dumps(self.response()),
            }
        )
        result = subprocess.run(
            [
                str(GENERATOR),
                "--date",
                "2099-01-01",
                "--log-file",
                str(self.log),
                "--output",
                str(output),
                "--instructions",
                str(INSTRUCTIONS),
                "--no-upload",
            ],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("### Best chatter", output.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
