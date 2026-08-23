# Changelog

Written for someone deciding whether to accept an update: what changed for you,
what you have to do, and what breaks.

`omarchy plugin update` fast-forwards you to whatever is on `main`, so the
version numbers below are a description of that history rather than something
you can install selectively.

**Any release touching the QML needs `omarchy restart shell` afterwards.**
`omarchy plugin update` refreshes the plugin on disk but does not rebuild a bar
widget that is already mounted.

## Unreleased

Nothing published yet — the plugin has not had its first release.

### Added

- Set and replace the StatusCake API token from the bar. Clicking the widget
  with no token stored opens the panel on its settings; the cog turns the panel
  to them any other time, and `Esc` turns it back.
- Settings in the panel for the refresh interval, tag filter, match-any switch
  and notification switch, so none of them need a hand-edited `shell.json`.
- Settings are grouped: filters, polling, notifications, and the API token
  last. On a first run the token form is all that shows — the rest configures a
  fetch that cannot happen yet, and its defaults are fine to start with.
- Tags are picked from the ones your account uses, with a search box and a
  checkbox each, rather than typed into a field. The API matches tags
  literally, so a typo used to mean a pill reading `0 up, 0 down` and nothing
  saying why.
- **Match any tag** and **Notify on state changes** are on by default. Checks
  carrying one tag each can never match two at once, so matching *all* of a
  two-tag selection would return nothing.

### Removed

- **`hideWhenAllUp`.** It hid the widget while everything was up — and with it
  the only route to the panel and the settings, so turning it back off meant
  editing `shell.json` by hand. If you had it set, the key is now ignored and
  the widget always shows; you can delete it from your entry.
