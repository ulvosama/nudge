#!/bin/sh
# Suite D: the real app in a sandbox with one fake held question. Screenshots only, no input.
# Your screens dim for a few seconds while the fake question is open.
set -u
OUT="$1"; SB="$OUT/nudge-d-home"; CS="$SB/claude-sessions"
APP="$(cd "$(dirname "$0")/.." && pwd)/build/Nudge.app/Contents/MacOS/Nudge"
rm -rf "$SB"; mkdir -p "$SB/requests" "$CS"
sleep 60 & HOLDER=$!
NOW=$(python3 -c 'import time;print(int(time.time()*1000))')
cat > "$CS/$HOLDER.json" <<J
{"pid":$HOLDER,"sessionId":"smoke-1","cwd":"/tmp/smoke-project","kind":"interactive","name":"screen-smoke-test","status":"busy","statusUpdatedAt":$NOW}
J
python3 - "$SB" "$HOLDER" <<'P'
import json, sys, time, uuid
sb, holder = sys.argv[1], int(sys.argv[2])
rid = str(uuid.uuid4())
json.dump({"session_id": "smoke-1", "tool_name": "Bash", "tool_input": {"command": "npm run build && npm test"},
           "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "npm run build:*"}], "behavior": "allow", "destination": "localSettings"}],
           "nudge_request_id": rid, "nudge_created": time.time(), "nudge_helper_pid": holder},
          open(f"{sb}/requests/{rid}.json", "w"))
P
NUDGE_HOME="$SB" NUDGE_CLAUDE_SESSIONS="$CS" "$APP" & APPPID=$!
sleep 2.5
wins() { swift -e 'import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let pid = Int(CommandLine.arguments[1])!
print(l.filter { ($0["kCGWindowOwnerPID"] as? Int) == pid }.count)' "$1" 2>/dev/null; }
SCREENS=$(swift -e 'import AppKit; print(NSScreen.screens.count)' 2>/dev/null)
LOCKED=$(wins $APPPID)
screencapture -x "$OUT/d-locked-1.png" "$OUT/d-locked-2.png" 2>/dev/null
CPU=$(ps -o %cpu= -p $APPPID | tr -d ' ')
kill $HOLDER 2>/dev/null          # Claude "cancelled" the hook: the request must drop, the lock lift
sleep 1.5
UNLOCKED=$(wins $APPPID)
LEFT=$(ls "$SB/requests" | wc -l | tr -d ' ')
screencapture -x "$OUT/d-unlocked.png" 2>/dev/null
kill $APPPID 2>/dev/null
echo "screens=$SCREENS windows_locked=$LOCKED windows_after=$UNLOCKED requests_left=$LEFT cpu=$CPU"
P=0; F=0
t() { if [ "$2" = "1" ]; then echo "PASS $1"; P=$((P+1)); else echo "FAIL $1 [$3]"; F=$((F+1)); fi; }
t "D1 lock covers every screen (panel + one dim window per screen)" $([ "$LOCKED" -ge $((SCREENS + 1)) ] && echo 1 || echo 0) "windows=$LOCKED screens=$SCREENS"
t "D2 cancelled request dropped" $([ "$LEFT" = "0" ] && echo 1 || echo 0) "left=$LEFT"
t "D3 lock lifts (only the widget window remains)" $([ "$UNLOCKED" = "1" ] && echo 1 || echo 0) "windows=$UNLOCKED"
echo; echo "Suite D: $P/$((P+F)) passed"
