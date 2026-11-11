# Security and privacy

Nudge runs entirely on your Mac. It makes no network requests except checking GitHub Releases for
updates, and you can turn that off in the menu ("Update automatically").

## What it touches

| Where | What |
|---|---|
| `~/.claude/settings.json` | Nudge adds its hooks, **only after you agree** in the Welcome window. Your other settings are kept, and a copy of the file as it was before is saved as `settings.json.before-nudge`. "Remove Claude Code hooks" in the menu takes them out again, and they stay out. |
| `~/.claude/sessions/` | Read only: Claude Code's own status for each running session. |
| `~/.nudge/` (owner-only, `0700`) | Hand-off files between the hooks and the app, the hook script, the 24 h permission log (`permissions.jsonl`, `0600`) and `update.log`. |

The permission log contains the commands Claude asked to run. That text can include secrets, so it
is kept for 24 h only. Turn it off with "Record permissions" in the menu.

## Auto-approve

Auto-approve says yes to Claude Code's permission requests for you, for up to 24 h. That is as
powerful as it sounds. It can only be turned on after Touch ID or your login password; a
`nudge://auto/on` link just opens the confirmation. It switches off by itself when the time runs
out, and you can stop it any time from the menu.

## If Nudge isn't running

The hook script does nothing when the app isn't running or has been deleted. Claude Code then asks
in the terminal as usual. A request is never held for more than 5 minutes.

## Updates

Release builds are signed with a Developer ID and notarized by Apple. An update is installed only if:
- its zip matches the SHA-256 published with the release,
- its code signature is valid and it is signed by the **same Developer ID team** as the copy you're running,
- and it passes Gatekeeper.

A copy you built from source updates from git only if you turn that on. It then builds and tests
whatever is on `main`, so only enable it for a repository you trust.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting (Security → Report a vulnerability) rather than
a public issue.
