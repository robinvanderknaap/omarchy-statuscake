# Changelog

Written for someone deciding whether to accept an update: what changed for you,
what you have to do, and what breaks.

`omarchy plugin update` fast-forwards you to whatever is on `main`, so the
version numbers below are a description of that history rather than something
you can install selectively.

**Any release touching the QML needs `omarchy restart shell` afterwards.**
`omarchy plugin update` refreshes the plugin on disk but does not rebuild a bar
widget that is already mounted.

## 0.1.0 — 2026-08-24

First release.

A bar widget for the Omarchy shell showing the state of your StatusCake uptime
checks: a pill counting what is up and what is down, and a panel listing every
check with its uptime percentage.

### Getting started

Install, then click the widget and paste a StatusCake API token. It is verified
against the API before anything is stored, and it goes to your keyring — never
to `shell.json`, a command line, or a log. Read access to uptime tests is all
it needs.

### What you get

- **A pill in the bar** — the number of checks up, or `N/M` in your theme's
  urgent colour when something is down. Middle-click forces a refresh,
  right-click opens app.statuscake.com.
- **A panel listing every check** with its uptime percentage: down first, then
  up, then paused. Clicking one opens its URL.
- **Notifications on state changes**, on by default. They fire only on a
  change, and only for checks seen in both the previous and current poll — so a
  shell restart never replays a backlog, pausing a down check is not a
  recovery, and twenty checks failing at once is one notification rather than
  twenty.
- **Settings behind the cog**: refresh interval, tag filter, match-any switch,
  notification switch. Every control writes on the click; there is nothing to
  save.
- **Tags picked from your account** rather than typed, because the API matches
  tags literally — a typo would otherwise show up as a pill reading
  `0 up, 0 down` with nothing to say why.
- **Remove token** in the settings view. Omarchy has no uninstall hook, so
  removing the plugin would otherwise leave the credential sitting in your
  keyring.
