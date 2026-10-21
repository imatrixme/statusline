# Reference status line in Python for the benchmark: same config file, same
# input, byte-identical output to omnitt-statusline for the segments below.
import json
import math
import os
import re
import sys

SEGMENTS = {
    "model": {"fact": "model.display_name", "kind": "text", "strip": True, "icon": "\U000F06A9", "color": 141},
    "effort": {"fact": "effort.level", "kind": "text", "icon": "\U000F09D1", "color": 214},
    "ctx-used-pct": {"fact": "context_window.used_percentage", "kind": "percent", "icon": "\U000F035B", "color": 78,
                     "rules": [(0, 78), (50, 220), (80, 203)]},
    "session-duration": {"fact": "cost.total_duration_ms", "kind": "duration", "icon": "\U000F0954", "color": 183},
    "tokens-in": {"fact": "context_window.total_input_tokens", "kind": "compact", "icon": "\U000F0045", "color": 81},
    "tokens-out": {"fact": "context_window.total_output_tokens", "kind": "compact", "icon": "\U000F005D", "color": 114},
    "cache-hit": {"fact": "prompt_cache.hit_ratio", "kind": "percent", "scale": 100, "icon": "\U000F0450", "color": 79},
    "cost": {"fact": "cost.total_cost_usd", "kind": "money", "icon": "\U000F01C1", "color": 220},
}


def get(obj, path):
    for k in path.split("."):
        if not isinstance(obj, dict):
            return None
        obj = obj.get(k)
    return obj


def compact(n):
    v, s = n, ""
    if n >= 1e9:
        v, s = n / 1e9, "G"
    elif n >= 1e6:
        v, s = n / 1e6, "M"
    elif n >= 1e3:
        v, s = n / 1e3, "k"
    if v >= 10 or not s:
        return f"{math.floor(v + 0.5)}{s}"
    t = f"{v:.1f}"
    return (t[:-2] if t.endswith(".0") else t) + s


def duration(ms):
    secs = max(0, math.floor(ms / 1000))
    m = secs // 60
    h = m // 60
    return f"{h}hr {m % 60}m" if h > 0 else f"{m}m"


def fmt(d, v):
    kind = d["kind"]
    if kind == "text":
        return re.sub(r" \([^)]*context\)$", "", str(v)) if d.get("strip") else str(v)
    if kind == "percent":
        return f"{v * d.get('scale', 1):.0f}%"
    if kind == "money":
        return f"${v:.2f}"
    if kind == "duration":
        return duration(v)
    return compact(v)


raw = sys.stdin.read()
tmp = os.path.join(os.environ.get("TMPDIR", "/tmp"), "omnitt-statusline-py")
os.makedirs(tmp, exist_ok=True)
with open(os.path.join(tmp, "last-input.json"), "w") as f:
    f.write(raw)

with open(os.path.join(os.environ["XDG_CONFIG_HOME"], "omnitt-statusline", "config.json")) as f:
    config = json.load(f)
data = json.loads(raw)
lines = []
for line in config["lines"]:
    parts = []
    for seg in line:
        d = SEGMENTS[seg["id"]]
        v = get(data, d["fact"])
        if v is None:
            continue
        color = d["color"]
        for lo, c in d.get("rules", []):
            if v >= lo:
                color = c
        parts.append(f"\x1b[38;5;{color}m{d['icon']} {fmt(d, v)}\x1b[0m")
    lines.append(" ".join(parts))
sys.stdout.write("\n".join(lines) + "\n")
