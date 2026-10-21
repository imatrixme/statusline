// Reference status line in JavaScript for the benchmark: same config file, same
// input, byte-identical output to omnitt-statusline for the segments below.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const SEGMENTS = {
    model: { fact: 'model.display_name', kind: 'text', strip: true, icon: '\u{F06A9}', color: 141 },
    effort: { fact: 'effort.level', kind: 'text', icon: '\u{F09D1}', color: 214 },
    'ctx-used-pct': { fact: 'context_window.used_percentage', kind: 'percent', icon: '\u{F035B}', color: 78, rules: [[0, 78], [50, 220], [80, 203]] },
    'session-duration': { fact: 'cost.total_duration_ms', kind: 'duration', icon: '\u{F0954}', color: 183 },
    'tokens-in': { fact: 'context_window.total_input_tokens', kind: 'compact', icon: '\u{F0045}', color: 81 },
    'tokens-out': { fact: 'context_window.total_output_tokens', kind: 'compact', icon: '\u{F005D}', color: 114 },
    'cache-hit': { fact: 'prompt_cache.hit_ratio', kind: 'percent', scale: 100, icon: '\u{F0450}', color: 79 },
    cost: { fact: 'cost.total_cost_usd', kind: 'money', icon: '\u{F01C1}', color: 220 },
};

const get = (obj, path) => path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);

function compact(n) {
    let v = n;
    let s = '';
    if (n >= 1e9) [v, s] = [n / 1e9, 'G'];
    else if (n >= 1e6) [v, s] = [n / 1e6, 'M'];
    else if (n >= 1e3) [v, s] = [n / 1e3, 'k'];
    if (v >= 10 || !s) return `${Math.floor(v + 0.5)}${s}`;
    return `${v.toFixed(1).replace(/\.0$/, '')}${s}`;
}

function duration(ms) {
    const secs = Math.max(0, Math.floor(ms / 1000));
    const m = Math.floor(secs / 60);
    const h = Math.floor(m / 60);
    return h > 0 ? `${h}hr ${m % 60}m` : `${m}m`;
}

function format(def, v) {
    switch (def.kind) {
        case 'text':
            return def.strip ? String(v).replace(/ \([^)]*context\)$/, '') : String(v);
        case 'percent':
            return `${(v * (def.scale ?? 1)).toFixed(0)}%`;
        case 'money':
            return `$${v.toFixed(2)}`;
        case 'duration':
            return duration(v);
        case 'compact':
            return compact(v);
    }
}

const raw = readFileSync(0, 'utf8');
const tmp = join(process.env.TMPDIR ?? '/tmp', 'omnitt-statusline-js');
mkdirSync(tmp, { recursive: true });
writeFileSync(join(tmp, 'last-input.json'), raw);

const config = JSON.parse(readFileSync(join(process.env.XDG_CONFIG_HOME, 'omnitt-statusline', 'config.json'), 'utf8'));
const input = JSON.parse(raw);
const out = config.lines.map((line) =>
    line
        .map(({ id }) => {
            const def = SEGMENTS[id];
            const v = get(input, def.fact);
            if (v == null) return null;
            let color = def.color;
            for (const [min, c] of def.rules ?? []) if (v >= min) color = c;
            return `\x1b[38;5;${color}m${def.icon} ${format(def, v)}\x1b[0m`;
        })
        .filter(Boolean)
        .join(' ')
);
process.stdout.write(`${out.join('\n')}\n`);
