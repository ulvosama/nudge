#!/usr/bin/env python3
"""Suite C: a real interactive Claude Code session (driven through a pty) asks for permission,
a question set and a plan; a fake Nudge app answers each through the real nudge-hook helper.
Everything lives in a sandbox NUDGE_HOME; the project folder carries its own hooks."""
import glob, json, os, pty, re, select, shutil, signal, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.realpath(os.path.join(HERE, "..", "build/Nudge.app/Contents/MacOS/nudge-hook"))
BASE = sys.argv[1]                      # scratch folder for this run
PROJ = os.path.join(BASE, "nudge-e2e")
SB = os.path.join(BASE, "nudge-e2e-home")
shutil.rmtree(PROJ, ignore_errors=True); shutil.rmtree(SB, ignore_errors=True)
os.makedirs(os.path.join(PROJ, ".claude")); os.makedirs(SB)
cmd = lambda ev: f'NUDGE_HOME="{SB}" "{HELPER}" {ev}'
json.dump({"hooks": {
    "PermissionRequest": [{"matcher": "", "hooks": [{"type": "command", "command": cmd("perm"), "timeout": 330}]}],
    "PreToolUse": [{"matcher": "AskUserQuestion|ExitPlanMode", "hooks": [{"type": "command", "command": cmd("pre"), "timeout": 10}]}],
}}, open(os.path.join(PROJ, ".claude", "settings.local.json"), "w"), indent=1)

T0 = time.time()
log_lines = []
def log(msg):
    line = f"{time.time() - T0:7.2f}s  {msg}"
    log_lines.append(line); print(line, flush=True)

# ---------------- fake Nudge app ----------------
state = {"stop": False, "pass_handed": None, "requests": []}
def fake_app():
    alive = os.path.join(SB, "alive")
    reqdir, resdir = os.path.join(SB, "requests"), os.path.join(SB, "responses")
    seen = set()
    while not state["stop"]:
        with open(alive, "a"): os.utime(alive, None)
        for f in (os.listdir(reqdir) if os.path.isdir(reqdir) else []):
            if not f.endswith(".json") or f in seen: continue
            seen.add(f)
            try: r = json.load(open(os.path.join(reqdir, f)))
            except Exception: seen.discard(f); continue
            tool, ti = r.get("tool_name"), r.get("tool_input") or {}
            c = ti.get("command", "") if isinstance(ti, dict) else ""
            if tool == "Bash" and ("ALLOW1" in c or "RACE" in c or "nudge-P1" in c or "nudge-P2" in c): resp = {"action": "allow"}
            elif tool == "Bash" and "ALLOW2" in c: resp = {"action": "allow", "updatedPermissions": r.get("permission_suggestions") or []}
            elif tool == "Bash" and "DENY" in c: resp = {"action": "deny", "message": "NUDGE-TEST: denied from the widget"}
            elif tool == "Bash" and "PASS" in c: resp = {"action": "handoff"}; state["pass_handed"] = time.time()
            elif tool == "AskUserQuestion":
                answers = {}
                for q in ti.get("questions", []):
                    labels = [o.get("label") for o in q.get("options", [])]
                    answers[q["question"]] = ", ".join(labels[:2]) if q.get("multiSelect") else labels[0]
                resp = {"action": "allow", "updatedInput": {**ti, "answers": answers}}
                state["answers"] = answers
                state["answered_q_at"] = time.time()
            elif tool == "ExitPlanMode":
                variant = os.environ.get("PLAN_VARIANT", "setmode")
                resp = {"action": "allow"}
                if variant == "setmode":
                    resp["updatedPermissions"] = [{"type": "setMode", "mode": "acceptEdits", "destination": "session"}]
                elif variant == "input":
                    resp["updatedInput"] = ti
            else: resp = {"action": "allow"}
            age = time.time() - r.get("nudge_created", time.time())
            state["requests"].append((tool, c or "", resp["action"]))
            if r.get("permission_suggestions"): log(f"APP  suggestions: {json.dumps(r['permission_suggestions'])[:300]}")
            log(f"APP  request {tool} {c[:40]!r} (seen {age:.2f}s after hold) -> {resp['action']}")
            os.makedirs(resdir, exist_ok=True)
            tmp = os.path.join(resdir, f[:-5] + ".tmp")
            json.dump(resp, open(tmp, "w")); os.rename(tmp, os.path.join(resdir, f))
        time.sleep(0.05)
threading.Thread(target=fake_app, daemon=True).start()

# ---------------- drive claude in a pty ----------------
RACE = ("This is an automated test. Run exactly this one command once: `echo run >> nudge-RACE.log` "
        "then reply with the single word done and stop.")
PARALLEL = ("This is an automated test. In ONE message, make two Bash tool calls in parallel: "
            "`echo a >> nudge-P1.log` and `echo b >> nudge-P2.log`. Then reply with the single word done and stop.")
PLAN_ONLY = ("This is an automated test. Call EnterPlanMode, then call ExitPlanMode with the one-line plan "
             "\"Say done.\", then state the current permission mode, then stop.")
PROMPT = ("This is an automated test of a permission widget. Do these steps strictly one at a time (never in parallel) "
          "and at the end report the outcome of each step: "
          "1) run `touch nudge-ALLOW1` "
          "2) run `mkdir nudge-ALLOW2` and then `mkdir nudge-ALLOW2b` "
          "3) run `cp /dev/null nudge-DENY` (if it is denied, do not retry; quote the denial reason exactly) "
          "4) run `ln -s /dev/null nudge-PASS` "
          "5) use AskUserQuestion with two questions: \"Pick a color\" (single choice, options Red and Blue) and "
          "\"Pick fruits\" (multiSelect true, options Apple, Pear, Plum); quote exactly the answers you received "
          "6) call EnterPlanMode, then call ExitPlanMode with the one-line plan \"Say done.\", then state the current permission mode. "
          "Then stop.")

pid, fd = pty.fork()
if pid == 0:
    os.chdir(PROJ)
    os.environ["TERM"] = "xterm-256color"
    # Started from inside a Claude session, the child would inherit its "child session" marker
    # and run without a transcript or status file. Make it an ordinary top-level session.
    for k in list(os.environ):
        if k.startswith("CLAUDE_CODE") or k == "CLAUDECODE":
            del os.environ[k]
    # Keep the real Nudge (global hooks) out of this session; only the sandbox hook answers.
    os.environ["NUDGE_TEST_SESSION"] = "1"
    os.execvp("claude", ["claude", "--permission-mode", "default"])

import fcntl, struct, termios
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
screen = ""
def pump(t=0.2):
    global screen
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: data = os.read(fd, 65536).decode("utf8", "replace")
            except OSError: return False
            screen = (screen + re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b.", "", data))[-40000:]
    return True
def send(s): os.write(fd, s.encode())

def claude_status():
    f = os.path.join(os.path.expanduser("~/.claude/sessions"), f"{pid}.json")
    try: return json.load(open(f))
    except Exception: return None

log(f"spawned claude pid {pid}")
trusted = sent = False
t_ready = time.time() + 25
while time.time() - T0 < 60:
    pump(0.3)
    low = screen.lower()
    if not trusted and "itrustthisfolder" in low.replace(" ", ""):
        # The default row is "No, exit": move down to "Yes, I trust this folder" first.
        time.sleep(0.5); send("\x1b[B"); time.sleep(0.3); send("\r"); trusted = True
        log("accepted folder trust"); screen = ""
    if ("for shortcuts" in low or "bypass" in low or "? for" in low) or time.time() > t_ready:
        break
time.sleep(1.5); pump(0.5)
send({"plan": PLAN_ONLY, "race": RACE, "parallel": PARALLEL}.get(os.environ.get("SCENARIO"), PROMPT)); time.sleep(0.8); send("\r"); sent = True
log("prompt sent")

# watch status + handle the PASS terminal dialog
last_status, waiting_seen_at, pressed = None, None, False
last_dump_status = None
deadline = time.time() + 480
idle_since = None
while time.time() < deadline:
    if not pump(0.2): break
    st = claude_status()
    s = (st or {}).get("status")
    if s != last_status:
        log(f"CLAUDE status -> {s} {(st or {}).get('waitingFor') or ''}")
        last_status = s
    if s == "waiting" and state["pass_handed"] and not pressed:
        waiting_seen_at = time.time()
        log(f"terminal dialog showing {waiting_seen_at - state['pass_handed']:.2f}s after hand-off; pressing Enter")
        time.sleep(0.6); send("\r"); pressed = True
        state["pressed_at"] = time.time()
    if pressed and "left_waiting" not in state and s != "waiting":
        state["left_waiting"] = time.time() - state["pressed_at"]
        log(f"status left 'waiting' {state['left_waiting']:.2f}s after Enter")
    if s == "waiting" and last_dump_status != s:
        time.sleep(0.4); pump(0.3)
        log("SCREEN at dialog:\n      " + screen[-900:].replace("\n", " "))
    last_dump_status = s
    flat = screen[-3000:].replace(" ", "").lower()
    if s == "waiting" and "readytocode" in flat and "plan_seen" not in state:
        # Claude's own plan dialog (Nudge never holds plans): approve it here, option 1.
        state["plan_seen"] = time.time()
        log("plan dialog detected via Claude status; approving in the terminal (option 1)")
        time.sleep(0.6); send("\r")
    elif s == "waiting" and (st or {}).get("waitingFor") == "input needed" and state.get("answered_q_at") \
            and "q_flash" not in state:
        # Right after Nudge answered the questions: does Claude still show its question dialog?
        t_wait = time.time()
        while time.time() - t_wait < 4:
            pump(0.2)
            if (claude_status() or {}).get("status") != "waiting": break
        state["q_flash"] = time.time() - t_wait
        still = (claude_status() or {}).get("status") == "waiting"
        log(f"'input needed' after Nudge's answer lasted {state['q_flash']:.2f}s; still waiting={still}")
        if still: state["q_stuck"] = True; send("\x1b")
    elif s == "waiting" and os.environ.get("SCENARIO") in ("race", "parallel") and "race_done" not in state:
        # Leave the stale dialog alone: does it clear by itself?
        t_wait = time.time()
        while time.time() - t_wait < 6:
            pump(0.2)
            if (claude_status() or {}).get("status") != "waiting": break
        cleared = (claude_status() or {}).get("status") != "waiting"
        log(f"RACE dialog after hook allow: cleared by itself={cleared} after {time.time() - t_wait:.2f}s")
        state["race_cleared"] = cleared
        if not cleared:
            log("RACE pressing Enter (Yes) on it"); send("\r"); time.sleep(3); pump(0.5)
        state["race_done"] = True
    elif s == "waiting" and not state["pass_handed"] and not state.get("pass_handed"):
        # Claude 2.1.300 shows "waiting" for a moment while it hands a request to the hooks:
        # give it time to clear by itself before treating it as a real dialog.
        t_wait = time.time()
        while time.time() - t_wait < 5:
            pump(0.2)
            if (claude_status() or {}).get("status") != "waiting": break
        if (claude_status() or {}).get("status") != "waiting":
            log(f"brief 'waiting' cleared by itself after {time.time() - t_wait:.2f}s")
            last_status = None
            continue
        # a real unexpected dialog: note it
        log("unexpected terminal dialog; pressing Esc"); time.sleep(0.6); send("\x1b"); time.sleep(1)
    if s == "idle" and ("plan_seen" in state or os.environ.get("SCENARIO") in ("plan", "race", "parallel")) and time.time() - T0 > 35:
        idle_since = idle_since or time.time()
        if time.time() - idle_since > 4: break
    else:
        idle_since = None

sid = (claude_status() or {}).get("sessionId")
state["stop"] = True
try:
    send("\x03"); time.sleep(0.3); send("\x03"); time.sleep(1)
    os.kill(pid, signal.SIGTERM)
except Exception: pass

# ---------------- verify from the transcript ----------------
results = []
if os.environ.get("SCENARIO") == "parallel":
    n = [open(os.path.join(PROJ, f)).read().count(x) if os.path.exists(os.path.join(PROJ, f)) else 0
         for f, x in (("nudge-P1.log", "a"), ("nudge-P2.log", "b"))]
    log(f"PARALLEL result: runs P1={n[0]} P2={n[1]}; requests seen={[c for _, c, _ in state['requests']]}; "
        f"dialog seen={'race_done' in state} cleared_alone={state.get('race_cleared')}")
    sys.exit(0)
if os.environ.get("SCENARIO") == "race":
    log_path = os.path.join(PROJ, "nudge-RACE.log")
    runs = open(log_path).read().count("run") if os.path.exists(log_path) else 0
    log(f"RACE result: command ran {runs} time(s); stale dialog seen={'race_done' in state} cleared_alone={state.get('race_cleared')}")
    sys.exit(0)
def check(name, ok, detail=""):
    results.append((name, ok)); print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail and not ok else ""))

files = glob.glob(os.path.expanduser(f"~/.claude/projects/*/{sid}.jsonl")) if sid else []
entries = [json.loads(l) for l in open(files[0])] if files else []
uses, results_by_id, texts, modes = {}, {}, [], []
for e in entries:
    if e.get("type") == "permission-mode": modes.append(e.get("permissionMode") or e.get("mode"))
    m = e.get("message") or {}
    for b in (m.get("content") if isinstance(m.get("content"), list) else []):
        if b.get("type") == "tool_use": uses[b["id"]] = b
        if b.get("type") == "tool_result":
            c = b.get("content")
            c = c if isinstance(c, str) else " ".join(x.get("text", "") for x in (c or []) if isinstance(x, dict))
            results_by_id[b["tool_use_id"]] = (c, b.get("is_error", False))
        if b.get("type") == "text" and m.get("role") == "assistant": texts.append(b["text"])
def result_for(pred):
    for i, u in uses.items():
        if pred(u): return results_by_id.get(i, (None, None))
    return (None, None)
bash = lambda word: (lambda u: u.get("name") == "Bash" and word in json.dumps(u.get("input")))

check("C0 transcript found", bool(entries), f"sid={sid}")
check("C1 ALLOW1: allowed by Nudge, command ran", os.path.exists(os.path.join(PROJ, "nudge-ALLOW1")) and result_for(bash("ALLOW1"))[1] is False)
local = open(os.path.join(PROJ, ".claude", "settings.local.json")).read()
check("C2 ALLOW2: allowed with Claude's suggested rule, ran", os.path.isdir(os.path.join(PROJ, "nudge-ALLOW2")))
asked2b = any("ALLOW2b" in c for _, c, _ in state["requests"])
check("C2b 'don't ask again' honoured: 2nd mkdir not asked", os.path.isdir(os.path.join(PROJ, "nudge-ALLOW2b")) and not asked2b,
      f"asked2b={asked2b}")
dc, derr = result_for(bash("DENY"))
check("C3 DENY: blocked, Claude sees our reason", not os.path.exists(os.path.join(PROJ, "nudge-DENY")) and derr and "NUDGE-TEST" in (dc or ""), str(dc)[:200])
check("C4 PASS: handed off -> terminal dialog -> approved there, ran", os.path.exists(os.path.join(PROJ, "nudge-PASS")) and bool(waiting_seen_at))
if waiting_seen_at:
    check("C4b terminal dialog detected via Claude status ≤ 2 s after hand-off", waiting_seen_at - state["pass_handed"] <= 2.0,
          f"{waiting_seen_at - state['pass_handed']:.2f}s")
    check("C4c status leaves 'waiting' ≤ 1 s after answering in terminal", state.get("left_waiting", 99) <= 1.0, str(state.get("left_waiting")))
ac, aerr = result_for(lambda u: u.get("name") == "AskUserQuestion")
check("C5 AskUserQuestion answered from Nudge (Red; Apple, Pear)", ac is not None and "Red" in ac and "Apple" in ac and "Pear" in ac and not aerr, str(ac)[:300])
ec, eerr = result_for(lambda u: u.get("name") == "ExitPlanMode")
if "q_flash" in state:
    check("C5b no lasting question dialog after Nudge answered", not state.get("q_stuck"), f"{state['q_flash']:.2f}s")
check("C6 plan is not held by Nudge (Claude's own dialog)", not any(t == "ExitPlanMode" for t, _, _ in state["requests"]))
check("C6b plan dialog detected via Claude status", "plan_seen" in state)
check("C6c plan approved in the terminal -> plan mode left", ec is not None and not eerr and modes and modes[-1] != "plan",
      f"result={str(ec)[:120]} modes={modes[-3:]}")
print("\nFINAL CLAUDE REPORT:\n" + (texts[-1] if texts else "(none)"))
open(os.path.join(BASE, "e2e.log"), "w").write("\n".join(log_lines))
print(f"\nSuite C: {sum(bool(ok) for _, ok in results)}/{len(results)} passed")
sys.exit(0 if all(ok for _, ok in results) else 1)
