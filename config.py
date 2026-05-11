"""Configuration for Newsletter plugin."""

import os

import supybot.conf as conf
import supybot.registry as registry


def configure(advanced):
    from supybot.questions import expect, anything, something, yn  # noqa: F401
    conf.registerPlugin("Newsletter", True)


Newsletter = conf.registerPlugin("Newsletter")
DEFAULT_SCRIPT_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "scripts",
    "run_newsletter.sh",
)

conf.registerGlobalValue(
    Newsletter,
    "scriptPath",
    registry.String(
        DEFAULT_SCRIPT_PATH,
        """Absolute path to run_newsletter.sh.""",
    ),
)

conf.registerGlobalValue(
    Newsletter,
    "timeoutSeconds",
    registry.PositiveInteger(
        900,
        """Maximum time allowed for newsletter generation script.""",
    ),
)

conf.registerGlobalValue(
    Newsletter,
    "allowForce",
    registry.Boolean(
        True,
        """Whether users can request force regeneration.""",
    ),
)

conf.registerGlobalValue(
    Newsletter,
    "allowedChannel",
    registry.String(
        "##debate2016",
        """Channel where command is allowed. Empty string allows all channels.""",
    ),
)

conf.registerGlobalValue(
    Newsletter,
    "announceStart",
    registry.Boolean(
        True,
        """Whether to send a short 'working' message for long-running newsletter requests.""",
    ),
)

conf.registerGlobalValue(
    Newsletter,
    "startMessage",
    registry.String(
        "Generating newsletter... this will take a few seconds.",
        """Message sent before long-running newsletter generation starts.""",
    ),
)

# vim:set shiftwidth=4 tabstop=4 expandtab textwidth=79:
