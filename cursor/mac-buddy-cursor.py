#!/usr/bin/env python3
"""Mac Buddy <-> Cursor bridge.

Makes Mac Buddy react to Cursor's AI agent, the same way it reacts to Claude Code.

    python3 mac-buddy-cursor.py install     # adds hooks to ~/.cursor/hooks.json
    python3 mac-buddy-cursor.py uninstall   # removes only these hooks
    python3 mac-buddy-cursor.py status      # shows whether it's installed

How it works: Cursor runs this script on a few agent events. The script writes a tiny JSON
file into ~/.mac-buddy/sessions/ (the same folder Mac Buddy's Claude Code hook uses), and the
running Mac Buddy app picks it up. Nothing is sent over the network.

Safety: it only uses Cursor's "observe" events, never its permission events
(preToolUse, beforeShellExecution, ...), so it can never approve or block anything the
agent does. It always exits 0 and never prints anything that changes Cursor's behaviour.
"""
import json
import os
import re
import shutil
import sys

HOME = os.path.expanduser("~")
CURSOR_DIR = os.path.join(HOME, ".cursor")
HOOKS_JSON = os.path.join(CURSOR_DIR, "hooks.json")
BACKUP = HOOKS_JSON + ".bak-macbuddy"
INSTALLED_SCRIPT = os.path.join(CURSOR_DIR, "hooks", "mac-buddy-cursor.py")
SESSIONS_DIR = os.path.join(HOME, ".mac-buddy", "sessions")

# Cursor event -> Mac Buddy event (Mac Buddy uses Claude Code's event names).
EVENT_MAP = {
    "beforeSubmitPrompt": "UserPromptSubmit",   # you sent a message -> working
    "afterAgentThought": "UserPromptSubmit",    # agent is thinking -> working
    "postToolUse": "PostToolUse",               # agent used a tool -> working
    "afterFileEdit": "PostToolUse",             # agent edited a file -> working
    "afterShellExecution": "PostToolUse",       # agent ran a command -> working
    "postToolUseFailure": "PostToolUseFailure", # a tool failed -> still working
    "stop": "Stop",                             # agent finished -> celebrate
    "sessionEnd": "SessionEnd",                 # chat closed -> forget it
}

MARKER = "mac-buddy-cursor.py"


def hook_command():
    return '/usr/bin/python3 "%s" hook' % INSTALLED_SCRIPT


# ---------------------------------------------------------------- hook mode

def handle_event(raw):
    try:
        event = json.loads(raw or "{}")
    except ValueError:
        return
    if not isinstance(event, dict):
        return
    cursor_name = event.get("hook_event_name", "")
    name = EVENT_MAP.get(cursor_name)
    if not name:
        return

    conv = str(event.get("conversation_id") or event.get("session_id") or "default")
    sid = "cursor-" + re.sub(r"[^A-Za-z0-9_-]", "_", conv)[:80]
    path = os.path.join(SESSIONS_DIR, sid + ".json")

    if name == "SessionEnd":
        try:
            os.remove(path)
        except OSError:
            pass
        return

    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    target = ""
    for key in ("file_path", "path", "command", "pattern", "url", "query", "description"):
        value = tool_input.get(key) if key in tool_input else event.get(key)
        if isinstance(value, str) and value:
            target = value
            break

    tool = event.get("tool_name") or {
        "afterFileEdit": "Edit",
        "afterShellExecution": "Bash",
    }.get(cursor_name, "")

    roots = event.get("workspace_roots")
    cwd = event.get("cwd") or (roots[0] if isinstance(roots, list) and roots else "")

    record = {
        "event": name,
        "tool": str(tool),
        "target": target[:120],
        "desc": str(tool_input.get("description", ""))[:80],
        "cwd": str(cwd),
        "sid": sid,
    }
    try:
        os.makedirs(SESSIONS_DIR, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(record, f)
        os.replace(tmp, path)  # atomic, so the app never reads half a file
    except OSError:
        pass


def run_hook():
    try:
        raw = sys.stdin.read()
    except Exception:
        raw = ""
    try:
        handle_event(raw)
    except Exception:
        pass  # never get in Cursor's way
    try:
        if json.loads(raw or "{}").get("hook_event_name") == "beforeSubmitPrompt":
            print('{"continue": true}')  # explicit "let the prompt through"
    except Exception:
        pass
    sys.exit(0)


# ------------------------------------------------------- install / uninstall

def load_hooks():
    if not os.path.exists(HOOKS_JSON):
        return {"version": 1, "hooks": {}}
    with open(HOOKS_JSON) as f:
        text = f.read()
    if not text.strip():
        return {"version": 1, "hooks": {}}
    try:
        data = json.loads(text)
    except ValueError:
        sys.exit("%s isn't valid JSON. Fix it (or move it aside) and try again." % HOOKS_JSON)
    if not isinstance(data, dict):
        sys.exit("%s has an unexpected format; not touching it." % HOOKS_JSON)
    data.setdefault("version", 1)
    if not isinstance(data.get("hooks"), dict):
        data["hooks"] = {}
    return data


def save_hooks(data):
    os.makedirs(CURSOR_DIR, exist_ok=True)
    if os.path.exists(HOOKS_JSON):
        shutil.copy2(HOOKS_JSON, BACKUP)
    tmp = HOOKS_JSON + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, HOOKS_JSON)


def is_ours(entry):
    return isinstance(entry, dict) and MARKER in str(entry.get("command", ""))


def install():
    if not os.path.isdir(os.path.join(HOME, ".mac-buddy")):
        print("Note: Mac Buddy doesn't seem to be installed yet (no ~/.mac-buddy folder).")
        print("      The bridge will still be set up; install Mac Buddy to see the buddy react.")

    os.makedirs(os.path.dirname(INSTALLED_SCRIPT), exist_ok=True)
    src = os.path.abspath(__file__)
    if src != INSTALLED_SCRIPT:
        shutil.copy2(src, INSTALLED_SCRIPT)
    os.chmod(INSTALLED_SCRIPT, 0o755)

    data = load_hooks()
    hooks = data["hooks"]
    for cursor_event in EVENT_MAP:
        entries = [e for e in hooks.get(cursor_event, []) if not is_ours(e)]
        entries.append({"command": hook_command(), "timeout": 5})
        hooks[cursor_event] = entries
    save_hooks(data)
    print("Mac Buddy is connected to Cursor (%s)." % HOOKS_JSON)
    print("Restart Cursor (or reload its window) so it picks up the hooks.")


def uninstall():
    if os.path.exists(HOOKS_JSON):
        data = load_hooks()
        hooks = data["hooks"]
        for cursor_event in list(hooks):
            entries = hooks[cursor_event]
            if not isinstance(entries, list):
                continue
            kept = [e for e in entries if not is_ours(e)]
            if kept:
                hooks[cursor_event] = kept
            else:
                del hooks[cursor_event]
        save_hooks(data)
    try:
        os.remove(INSTALLED_SCRIPT)
    except OSError:
        pass
    if os.path.isdir(SESSIONS_DIR):
        for name in os.listdir(SESSIONS_DIR):
            if name.startswith("cursor-"):
                try:
                    os.remove(os.path.join(SESSIONS_DIR, name))
                except OSError:
                    pass
    print("Mac Buddy's Cursor hooks were removed. Restart Cursor to finish.")


def status():
    data = load_hooks() if os.path.exists(HOOKS_JSON) else {"hooks": {}}
    found = [ev for ev, entries in data["hooks"].items()
             if isinstance(entries, list) and any(is_ours(e) for e in entries)]
    if found and os.path.exists(INSTALLED_SCRIPT):
        print("Installed. Hooked events: " + ", ".join(sorted(found)))
    else:
        print("Not installed.")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "hook":
        run_hook()
    elif cmd == "install":
        install()
    elif cmd == "uninstall":
        uninstall()
    elif cmd == "status":
        status()
    else:
        print(__doc__)
        sys.exit(1)
