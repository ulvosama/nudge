#!/usr/bin/env python3
"""Suite A: the real nudge-hook binary against fake PermissionRequest payloads, in a sandbox."""
import json, os, subprocess, sys, tempfile, threading, time

HELPER = os.path.join(os.path.dirname(__file__), "..", "build/Nudge.app/Contents/MacOS/nudge-hook")
# The first run of a freshly built binary waits on macOS's code scan; keep that out of the timings.
subprocess.run([HELPER, "warmup"], input="", text=True, timeout=60, env={**os.environ, "NUDGE_HOME": tempfile.mkdtemp()})
results = []

def check(name, ok, detail=""):
    results.append((name, ok))
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail and not ok else ""))

def payload(tool="Bash", tool_input=None, sid="test-session"):
    return json.dumps({"session_id": sid, "tool_name": tool, "tool_input": tool_input or {"command": "echo hi"},
                       "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "echo:*"}],
                                                   "behavior": "allow", "destination": "localSettings"}]})

class Sandbox:
    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="nudge-a-")
        self.env = dict(os.environ, NUDGE_HOME=self.root)
        self.alive = True
        self._stop = False
        threading.Thread(target=self._toucher, daemon=True).start()
    def _toucher(self):
        path = os.path.join(self.root, "alive")
        while not self._stop:
            if self.alive:
                with open(path, "a"): os.utime(path, None)
            time.sleep(0.3)
    def requests(self):
        d = os.path.join(self.root, "requests")
        return [f for f in os.listdir(d) if f.endswith(".json")] if os.path.isdir(d) else []
    def respond(self, response, timeout=3):
        t0 = time.time()
        while time.time() - t0 < timeout:
            reqs = self.requests()
            if reqs:
                rid = reqs[0][:-5]
                os.makedirs(os.path.join(self.root, "responses"), exist_ok=True)
                tmp = os.path.join(self.root, "responses", rid + ".tmp")
                with open(tmp, "w") as f: json.dump(response, f)
                os.rename(tmp, os.path.join(self.root, "responses", rid + ".json"))
                return time.time() - t0
            time.sleep(0.02)
        return None
    def close(self): self._stop = True

def run_helper(sb, event="perm", body=None, respond=None, wait_first=0.0):
    p = subprocess.Popen([HELPER, event], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=sb.env, text=True)
    p.stdin.write(body or payload()); p.stdin.close()
    seen = None
    if respond is not None:
        time.sleep(wait_first)
        seen = sb.respond(respond)
    t0 = time.time()
    out = p.stdout.read(); p.wait(timeout=10)
    return out.strip(), seen, time.time() - t0

def decision(out):
    return json.loads(out)["hookSpecificOutput"]["decision"] if out else None

sb = Sandbox(); time.sleep(0.5)

# 1 + 2: request appears fast, allow
out, seen, _ = run_helper(sb, respond={"action": "allow"})
# Includes process start-up; under load this has measured up to ~0.4 s. The card must feel instant.
check("A1 request file appears within 0.75 s", seen is not None and seen < 0.75, f"seen={seen}")
check("A2 allow -> behavior allow", decision(out) == {"behavior": "allow"} and
      json.loads(out)["hookSpecificOutput"]["hookEventName"] == "PermissionRequest", out)

# 3: allow + updatedPermissions, deny + message, allow + updatedInput
perms = [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "echo:*"}], "behavior": "allow", "destination": "localSettings"}]
out, _, _ = run_helper(sb, respond={"action": "allow", "updatedPermissions": perms})
check("A3a allow + updatedPermissions", decision(out) == {"behavior": "allow", "updatedPermissions": perms}, out)
out, _, _ = run_helper(sb, respond={"action": "deny", "message": "use pnpm"})
check("A3b deny + message", decision(out) == {"behavior": "deny", "message": "use pnpm"}, out)
ui = {"questions": [{"question": "Q?"}], "answers": {"Q?": "A"}}
out, _, _ = run_helper(sb, respond={"action": "allow", "updatedInput": ui})
check("A3c allow + updatedInput", decision(out) == {"behavior": "allow", "updatedInput": ui}, out)

# 4: handoff
out, _, _ = run_helper(sb, respond={"action": "handoff"})
check("A4 handoff -> empty stdout", out == "", out)

# 5: app not alive at start
sb.alive = False; time.sleep(3.2)
t0 = time.time(); out, _, _ = run_helper(sb); dt = time.time() - t0
check("A5 stale alive -> returns at once, empty", out == "" and dt < 0.5 and not sb.requests(), f"dt={dt:.2f}")

# 6: app dies mid-hold
sb.alive = True; time.sleep(0.5)
p = subprocess.Popen([HELPER, "perm"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=sb.env, text=True)
p.stdin.write(payload()); p.stdin.close()
time.sleep(0.5); held = bool(sb.requests()); sb.alive = False; t0 = time.time()
out = p.stdout.read(); p.wait(timeout=10); dt = time.time() - t0
check("A6 app dies mid-hold -> releases within ~4 s", held and out.strip() == "" and dt < 4.5, f"held={held} dt={dt:.2f}")

# 7: hold-off
sb.alive = True; time.sleep(0.5)
open(os.path.join(sb.root, "hold-off"), "w").close()
t0 = time.time(); out, _, _ = run_helper(sb); dt = time.time() - t0
check("A7 hold-off -> never holds", out == "" and dt < 0.5, f"dt={dt:.2f}")
os.remove(os.path.join(sb.root, "hold-off"))

# 8: files cleaned
left = [f for d in ("requests", "responses") for f in (os.listdir(os.path.join(sb.root, d)) if os.path.isdir(os.path.join(sb.root, d)) else [])]
check("A8 request/response files cleaned up", not left, str(left))

# extra: detail capture for pre (AskUserQuestion text) and end removes it
q = payload("AskUserQuestion", {"questions": [{"question": "Pick a color?", "options": [{"label": "Red"}]}]})
subprocess.run([HELPER, "pre"], input=q, text=True, env=sb.env, timeout=5)
d = json.load(open(os.path.join(sb.root, "sessions", "test-session.json")))
check("A9 pre records question text", d["asks"][0]["text"] == "Pick a color?", str(d))
subprocess.run([HELPER, "end"], input=payload(), text=True, env=sb.env, timeout=5)
check("A10 end removes session detail", not os.path.exists(os.path.join(sb.root, "sessions", "test-session.json")))

sb.close()

# ---- permission log (fresh sandbox)
sb = Sandbox(); time.sleep(0.5)
def events():
    path = os.path.join(sb.root, "permissions.jsonl")
    return [json.loads(l) for l in open(path)] if os.path.exists(path) else []
def last_decision():
    return [e for e in events() if e["type"] == "decision"][-1]
def pending():
    d = os.path.join(sb.root, "perm-pending", "test-session")
    return os.listdir(d) if os.path.isdir(d) else []

run_helper(sb, body=payload("Bash", {"command": "rm -rf build, \"dist\""}), respond={"action": "allow"})
req = [e for e in events() if e["type"] == "request"][-1]
check("L1 request logged with exact input + suggested rule",
      json.loads(req["input"]) == {"command": "rm -rf build, \"dist\""} and req["summary"] == "rm -rf build, \"dist\""
      and req["suggested_rule"] == "Bash(echo:*)" and req["tool"] == "Bash", str(req))
check("L2 allow -> decision allowed by nudge", last_decision()["decision"] == "allowed" and last_decision()["by"] == "nudge", str(last_decision()))
run_helper(sb, respond={"action": "allow", "updatedPermissions": perms})
check("L3 always -> allowed_always + remembered rule", last_decision()["decision"] == "allowed_always" and last_decision()["remembered_rule"] == "Bash(echo:*)", str(last_decision()))
run_helper(sb, respond={"action": "deny", "message": "use pnpm"})
check("L4 deny -> denied + message", last_decision()["decision"] == "denied" and last_decision()["message"] == "use pnpm", str(last_decision()))
run_helper(sb, body=payload("AskUserQuestion", {"questions": [{"question": "Q?"}]}), respond={"action": "allow", "updatedInput": ui})
check("L5 question -> answered + answers JSON", last_decision()["decision"] == "answered" and json.loads(last_decision()["answers"]) == {"Q?": "A"}, str(last_decision()))

term = payload("Bash", {"command": "make deploy"})
run_helper(sb, body=term, respond={"action": "handoff", "reason": "esc_in_nudge"})
check("L6 handoff -> handed_to_terminal with reason + pending file",
      last_decision()["decision"] == "handed_to_terminal" and last_decision()["reason"] == "esc_in_nudge" and len(pending()) == 1, str(last_decision()))
n = len(events())
subprocess.run([HELPER, "ran"], input=payload("Bash", {"command": "something else"}), text=True, env=sb.env, timeout=5)
check("L7 ran for an unrelated tool call -> nothing logged", len(events()) == n and len(pending()) == 1)
subprocess.run([HELPER, "ran"], input=term, text=True, env=sb.env, timeout=5)
ran = [e for e in events() if e["type"] == "ran"]
check("L8 ran for the handed-off call -> ran event, pending cleared",
      len(ran) == 1 and ran[0]["id"] == last_decision()["id"] and not pending(), str(ran))
t0 = time.time(); subprocess.run([HELPER, "ran"], input=payload(sid="other-session"), text=True, env=sb.env, timeout=5)
check("L9 ran with nothing pending returns fast", time.time() - t0 < 0.3, f"{time.time() - t0:.2f}s")

run_helper(sb, respond={"action": "allow", "auto": True, "auto_delay": 0.37})
check("L13 auto response -> auto_allowed by nudge_auto with its delay",
      last_decision()["decision"] == "auto_allowed" and last_decision()["by"] == "nudge_auto" and last_decision()["auto_delay"] == 0.37, str(last_decision()))
run_helper(sb, body=payload("AskUserQuestion", {"questions": [{"question": "Q?"}]}), respond={"action": "allow", "auto": True, "auto_delay": 5, "updatedInput": ui})
check("L14 auto answer -> auto_answered with answers", last_decision()["decision"] == "auto_answered" and json.loads(last_decision()["answers"]) == {"Q?": "A"}, str(last_decision()))

def last_request():
    return [e for e in events() if e["type"] == "request"][-1]
check("L15 request stamped auto_mode off by default", req.get("auto_mode") == "off", str(req))
amf = os.path.join(sb.root, "auto-mode")
json.dump({"mode": "quick", "until": time.time() + 600}, open(amf, "w"))
run_helper(sb, respond={"action": "allow", "auto": True, "auto_delay": 0.2, "auto_mode": "quick"})
check("L16 auto-mode file -> request stamped quick, decision carries quick",
      last_request().get("auto_mode") == "quick" and last_decision().get("auto_mode") == "quick", f"{last_request()} {last_decision()}")
json.dump({"mode": "normal", "until": time.time() - 1}, open(amf, "w"))
run_helper(sb, respond={"action": "allow"})
check("L17 expired auto-mode -> off", last_request().get("auto_mode") == "off", str(last_request()))
os.remove(amf)

open(os.path.join(sb.root, "record-off"), "w").close()
n = len(events())
run_helper(sb, respond={"action": "allow"})
check("L10 record-off -> nothing logged", len(events()) == n)
os.remove(os.path.join(sb.root, "record-off"))
sb.alive = False; time.sleep(3.2)
run_helper(sb)
check("L11 Nudge not running -> logged as handed_to_terminal (nudge_not_running)",
      last_decision()["reason"] == "nudge_not_running", str(last_decision()))
mode = oct(os.stat(os.path.join(sb.root, "permissions.jsonl")).st_mode & 0o777)
check("L12 log is private (0600)", mode == "0o600", mode)
sb.close()

# ---- update.sh git logic, against a throwaway origin (no build: these paths all stop before it)
import shutil
UPD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "update.sh")
def git(cwd, *a):
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *a], cwd=cwd, capture_output=True, text=True).stdout.strip()
u = tempfile.mkdtemp(prefix="nudge-u-")
origin, work, other = (os.path.join(u, n) for n in ("origin.git", "work", "other"))
subprocess.run(["git", "init", "-q", "--bare", "-b", "main", origin])
os.makedirs(work); git(work, "init", "-q", "-b", "main"); shutil.copy(UPD, work)
open(os.path.join(work, "f"), "w").write("1"); git(work, "add", "-A"); git(work, "commit", "-qm", "one")
git(work, "remote", "add", "origin", origin); git(work, "push", "-q", "origin", "main")
def upd(installed):
    return subprocess.run(["/bin/zsh", os.path.join(work, "update.sh"), "check", installed], capture_output=True, text=True, timeout=60).stdout.strip()
head = lambda: git(work, "rev-parse", "--short", "HEAD")
check("U1 installed == HEAD -> UPTODATE", upd(head()) == f"UPTODATE {head()}", upd(head()))
open(os.path.join(work, "f"), "w").write("editing")
check("U2 uncommitted edits -> SKIP, nothing pulled", upd("x").startswith("SKIP uncommitted"))
git(work, "checkout", "-q", "f")
subprocess.run(["git", "clone", "-q", origin, other])
open(os.path.join(other, "f"), "w").write("2"); git(other, "commit", "-qam", "two"); git(other, "push", "-q")
new = git(other, "rev-parse", "--short", "HEAD")
check("U3 behind origin -> fast-forwarded", upd(new) == f"UPTODATE {new}" and head() == new, f"{upd(new)} head={head()}")
open(os.path.join(work, "f"), "w").write("3a"); git(work, "commit", "-qam", "3a")
open(os.path.join(other, "f"), "w").write("3b"); git(other, "commit", "-qam", "3b"); git(other, "push", "-q")
mine = head()
check("U4 diverged -> SKIP, local commit kept", upd("x").startswith("SKIP this folder and GitHub have diverged") and head() == mine, upd("x"))
shutil.rmtree(u, ignore_errors=True)

failed = [n for n, ok in results if not ok]
print(f"\nSuite A: {len(results) - len(failed)}/{len(results)} passed")
sys.exit(1 if failed else 0)
