#!/bin/sh
# Status line benchmark: the same config and Claude Code input rendered by
# omnitt-statusline (Zig), Node.js, Bun and Python. Checks the outputs are
# byte-identical first, then times each with hyperfine (2.0+, which also records peak RSS).
#
#   zig build -Doptimize=ReleaseFast && bench/run.sh [python] > bench/results.json
set -eu
cd "$(dirname "$0")"
PY=${1:-python3}
BIN=../zig-out/bin/omnitt-statusline
export XDG_CONFIG_HOME="$PWD/xdg"
export TMPDIR="${TMPDIR:-/tmp}/omnitt-statusline-bench"
mkdir -p "$TMPDIR"

"$BIN" < input.json > "$TMPDIR/zig.out"
node statusline.mjs < input.json > "$TMPDIR/node.out"
bun statusline.mjs < input.json > "$TMPDIR/bun.out"
"$PY" statusline.py < input.json > "$TMPDIR/py.out"
for x in node bun py; do
    cmp -s "$TMPDIR/zig.out" "$TMPDIR/$x.out" || { echo "output differs: $x" >&2; exit 1; }
done

hyperfine -N --warmup 20 --runs 300 --input input.json --export-json "$TMPDIR/hyperfine.json" \
    -n zig "$BIN" -n node "node statusline.mjs" -n bun "bun statusline.mjs" -n python "$PY statusline.py" >&2

# summary: median wall time (ms), CPU time (ms) and peak RSS (MiB) per implementation
jq -c --arg machine "$( (sysctl -n machdep.cpu.brand_string 2>/dev/null || grep -m1 'model name' /proc/cpuinfo | cut -d: -f2) | sed 's/^ *//')" \
    --arg os "$(uname -sr)" --arg node "$(node --version)" --arg bun "$(bun --version)" \
    --arg python "$("$PY" --version 2>&1 | cut -d' ' -f2)" --arg zig "$(zig version)" --arg date "$(date -u +%Y-%m-%d)" '
    def ms: . * 1000 * 100 | round / 100;
    { date: $date, machine: $machine, os: $os, runs: .results[0].summary.time_wall_clock.count,
      versions: { node: $node, bun: $bun, python: $python, zig: $zig },
      results: [ .results[] | { name, command,
        wall_ms: (.summary.time_wall_clock.median | ms), wall_sd_ms: (.summary.time_wall_clock.stddev | ms),
        cpu_ms: (.summary.time_cpu.median | ms),
        rss_mib: (.summary.memory_peak_resident.median / 1048576 * 10 | round / 10) } ] }' "$TMPDIR/hyperfine.json"
