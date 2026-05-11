"""Basic Limnoria test harness for Newsletter."""

from supybot.test import PluginTestCase


class NewsletterTestCase(PluginTestCase):
    plugins = ("Newsletter",)


# vim:set shiftwidth=4 softtabstop=4 expandtab textwidth=79:
