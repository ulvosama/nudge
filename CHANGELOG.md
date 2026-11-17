# Changelog

## 1.0.1

- First run: the pill starts bottom-right and says hello ("Can you see me?", ⌘↩ Yes!) with the
  screen dimmed, then the Welcome window opens. Drag it anywhere and it stays there.
- Welcome: the eye looks around and blinks, and the bolt turns into the check.
- Nudge keeps itself a login item on every launch unless you turn "Open at login" off; if macOS
  needs your approval, the Welcome window links to Login Items.

## 1.0.0

First public release.

- Floating pill for Claude Code: WORKING / ASKS / APPROVING / YOUR TURN, across every session.
- Answer permission requests and questions from the card (⌘↩, ⌘1–9, Esc hands off to the terminal).
- Stay awake while Claude works (on power).
- Auto-approve, normal (1–15 s) or quick (under 1 s), up to 24 h, turned on only with Touch ID or your password.
- 24 h permission log with CSV export.
- `nudge://` links to switch modes from a script or a Claude session.
- Welcome window: Nudge asks before adding its hooks to Claude Code's settings.
- Signed and notarized universal app (Apple silicon and Intel), with verified updates from GitHub Releases.
- Menu: install/remove hooks (removal sticks), uninstall Nudge.
