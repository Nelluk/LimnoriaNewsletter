"""Newsletter plugin package."""

import supybot
import supybot.world as world

__version__ = "0.1.0"
__author__ = "Newsletter contributors"
__contributors__ = {}
__url__ = "https://github.com/Nelluk/LimnoriaNewsletter"

from . import config
from . import plugin

if world.testing:
    from . import test

Class = plugin.Class
configure = config.configure

# vim:set shiftwidth=4 softtabstop=4 expandtab textwidth=79:
