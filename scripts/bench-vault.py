#!/usr/bin/env python3
"""Builds a THROWAWAY PinTack vault for the benchmarks: N notes on disk, V of them open on the desk.

    scripts/bench-vault.py <total-notes> <open-notes> <folder> [image.png] [one-kind]

    scripts/bench-vault.py 1000 20 /tmp/bench-20 PinTack/Resources/Tutorial/pin.png
    scripts/bench-vault.py 1000 10 /tmp/bench-code . code      # every open note the same kind

The open ones cycle through the kinds of note people actually keep: plain, todo, table, fenced code
in several languages, an image, and a mixed one. `one-kind` prices a single kind on its own
(plain, todo, table, code, code1, image, mixed).

It writes the greeting and welcome markers so a measurement is never the first-run experience.
Point it only at a folder you are happy to lose: it fills it with a thousand files.
"""
import os, sys, random, shutil, datetime

TOTAL, VISIBLE, OUT = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
IMAGE_SOURCE = sys.argv[4] if len(sys.argv) > 4 else None
# Optional 5th argument: make every OPEN note the same kind, to price that kind on its own.
ONE_KIND = sys.argv[5] if len(sys.argv) > 5 else None
random.seed(7)

ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
def ulid(i):
    return "01M" + "".join(random.choice(ALPHABET) for _ in range(20)) + f"{i % 1000:03d}"[-3:]

COLOURS = ["#FFE9A8", "#D9F3C9", "#CFE6FF", "#F6D6E8", "#E7DFFA", "#FFD8B8", "#2C2C32", "#1B2A6B"]

def plain(i):
    return f"Standup {i}\n\nweb0{i%9} drained, ring {i%4} patched.\nNext wave Monday.\n"

def todo(i):
    ticks = "\n".join(f"- [{'x' if j <= i % 5 else ' '}] step {j}" for j in range(1, 8))
    return f"@Todo Release {i}\n\n{ticks}\n"

def table(i):
    return (f"Runbook {i}\n\n| host | role | owner |\n| --- | --- | --- |\n"
            + "".join(f"| web0{j} | front | ops |\n" for j in range(1, 5))
            + "\nCheck the load balancer first.\n")

def code(i, lang):
    bodies = {
        "bash": "ssh web01 'uptime'\nfor h in web01 web02; do ssh $h systemctl status api; done",
        "python": "import json\nwith open('hosts.json') as f:\n    hosts = json.load(f)\nprint(len(hosts))",
        "javascript": "const rows = data.filter(r => r.state === 'ready')\nconsole.log(rows.length)",
        "swift": "let notes = try VaultStore.shared.all()\nprint(notes.count)",
        "powershell": "Get-Process | Sort-Object CPU -Descending | Select-Object -First 5",
    }
    return f"Snippet {i}\n\n```{lang}\n{bodies[lang]}\n```\n"

def image(i):
    return f"Screenshot {i}\n\n![shot|320](attachments/shot.png)\n\nFiled for the ticket.\n"

def mixed(i):
    return (f"# Deploy {i}\n\n**Friday**, before the *freeze*:\n\n- drain `web01`\n- tag the build\n\n"
            "> Rollback is one command.\n\n```bash\ngit revert v4.2.1\n```\n\n"
            "| step | who |\n| --- | --- |\n| drain | ops |\n| deploy | me |\n")

KINDS = [plain, todo, table,
         lambda i: code(i, "bash"), lambda i: code(i, "python"), lambda i: code(i, "javascript"),
         lambda i: code(i, "swift"), lambda i: code(i, "powershell"), image, mixed]

os.makedirs(OUT, exist_ok=True)
meta = os.path.join(OUT, ".pintack")
os.makedirs(meta, exist_ok=True)
os.makedirs(os.path.join(OUT, "attachments"), exist_ok=True)
# The greeting card and the welcome note are "once" markers: neither belongs in a measurement.
open(os.path.join(meta, "onboarded"), "w").close()
open(os.path.join(meta, "welcomed"), "w").close()
if IMAGE_SOURCE:
    shutil.copy(IMAGE_SOURCE, os.path.join(OUT, "attachments", "shot.png"))

now = datetime.datetime(2026, 9, 20, 12, 0, 0)
for i in range(TOTAL):
    if i < VISIBLE and ONE_KIND:
        kind = {"plain": plain, "todo": todo, "table": table, "image": image, "mixed": mixed,
                "code": (lambda j: code(j, ["bash", "python", "javascript", "swift", "powershell"][j % 5])),
                "code1": (lambda j: code(j, "bash"))}[ONE_KIND]
    else:
        kind = KINDS[i % len(KINDS)] if i < VISIBLE else (plain if i % 3 else todo)
    body = kind(i)
    visible = i < VISIBLE
    stamp = (now + datetime.timedelta(minutes=i)).strftime("%Y-%m-%dT%H:%M:%SZ")
    x, y = 40 + (i % 10) * 90, 80 + ((i // 10) % 6) * 70
    tags = "[todo]" if "@Todo" in body else "[]"
    note = (f"---\nid: {ulid(i)}\ncreated: {stamp}\nmodified: {stamp}\ntags: {tags}\n"
            f"pinned: false\ncolor: \"{COLOURS[i % len(COLOURS)]}\"\ntheme: auto\nopacity: 1.00\n"
            f"collapsed: false\nfrozen: false\nvisible: {'true' if visible else 'false'}\n"
            f"frame:\n  x: {x}\n  y: {y}\n  w: 320\n  h: 260\n---\n{body}")
    open(os.path.join(OUT, f"2026-09-20-note-{i:04d}.md"), "w").write(note)

print(f"{TOTAL} notes in {OUT}, {VISIBLE} of them open")
