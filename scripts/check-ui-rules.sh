#!/bin/sh
# The iPhone app's UI rules that a compiler can't check (scripts/test-ios-ui.sh
# runs this first; run it on its own any time). The owner's rule: the UI
# updates immediately, everywhere.
#  1. A switch bound to something that isn't local state (a connection, an
#     AudioNet stream, the Monitor) is a LiveToggle: a plain Toggle shows the
#     source's value, which changes only after a round trip, so it flips
#     back and VoiceOver says the old state.
#  2. Sliders are NamedSliders (they show the value chosen at once, say it,
#     and step for VoiceOver); never a bare Slider.
#  3. ServerConnection calls the core through run() (which refreshes when
#     done) or refreshes itself: a call that does neither leaves screens
#     showing the old state whenever the core sends no event.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
exec python3 - "$root/apps/ios/TeamTalkNG" <<'PY'
import os, re, sys
src = sys.argv[1]
problems = []
for name in sorted(os.listdir(src)):
    if not name.endswith(".swift"):
        continue
    text = open(os.path.join(src, name)).read()
    lines = text.split("\n")
    def line_of(i):
        return text.count("\n", 0, i) + 1
    # 1. Plain Toggles bound to a connection, AudioNet or the Monitor.
    for m in re.finditer(r"(?<!Live)\bToggle\(", text):
        chunk = text[m.start():m.start() + 400]
        # The Toggle's own arguments (to its closing parenthesis).
        depth, end = 0, len(chunk)
        for k, ch in enumerate(chunk):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    end = k
                    break
        args = chunk[:end]
        if re.search(r"set:.*\b(connection|net|audioNet|monitor)\.", args, re.S):
            problems.append(f"{name}:{line_of(m.start())}: a Toggle bound to a connection, AudioNet or the Monitor: use LiveToggle")
    # 2. Bare Sliders (NamedSlider's own is the one allowed).
    for m in re.finditer(r"(?<![A-Za-z])Slider\(", text):
        if name == "AccessibleControls.swift":
            continue
        problems.append(f"{name}:{line_of(m.start())}: a bare Slider: use NamedSlider")
    # 3. Core calls in ServerConnection that neither use run() nor refresh.
    if name == "ServerConnection.swift":
        for m in re.finditer(r"\n    (?:private )?func (\w+)\([^\n]*\{\n", text):
            body_start = m.end()
            nxt = re.search(r"\n    (?:@\w+ )*(?:private |fileprivate |static |nonisolated )*(?:func|var|let|init|// MARK)", text[body_start:])
            body = text[body_start: body_start + (nxt.start() if nxt else len(text))]
            if "Task.detached" in body and "try client." in body or re.search(r"try \w+\.(set|toggle|join|leave|kick|move|mute)", body):
                if "Task.detached" in body and "refresh()" not in body and "run(" not in body and "-> " not in m.group(0):
                    problems.append(f"{name}:{line_of(m.start()+1)}: {m.group(1)} calls the core without run() or refresh()")
if problems:
    print("UI rules broken (see scripts/check-ui-rules.sh):")
    print("\n".join(problems))
    sys.exit(1)
print("UI rules: ok")
PY
