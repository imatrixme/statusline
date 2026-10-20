//! Pure renderer: (config, facts, columns) -> bytes. No I/O, so the same code
//! runs natively and as WebAssembly in the web editor's preview.

const std = @import("std");
const cfgm = @import("config.zig");
const registry = @import("registry.zig");
const Facts = @import("facts.zig").Facts;
const Allocator = std.mem.Allocator;
const Color = cfgm.Color;
const Seg = cfgm.Seg;

const R = "\x1b[0m";
const PL_SEP = "\u{E0B0}";
const PL_THIN = "\u{E0B1}";
const PL_BG: Color = .{ .idx = 236 };

const Piece = struct {
    text: []const u8,
    width: usize,
    priority: i32,
    right: bool,
    bg: Color,
    order: usize,
};

pub fn render(a: Allocator, cfg: cfgm.Config, facts: *const Facts, columns: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (cfg.lines) |line| {
        var pieces: std.ArrayList(Piece) = .empty;
        for (line, 0..) |*seg, i| {
            const p = try piece(a, cfg.style, seg, facts) orelse continue;
            try pieces.append(a, .{
                .text = p,
                .width = displayWidth(p),
                .priority = seg.priority,
                .right = seg.right,
                .bg = if (seg.bg == .none) PL_BG else seg.bg,
                .order = i,
            });
        }
        if (columns > 0) fit(&pieces, cfg.style, columns);
        try assemble(a, &out, cfg.style, pieces.items, columns);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

/// Drop the lowest-priority pieces (later ones first on ties) until the line fits.
fn fit(pieces: *std.ArrayList(Piece), style: cfgm.Style, columns: usize) void {
    while (pieces.items.len > 1 and lineWidth(pieces.items, style) > columns) {
        var victim: usize = 0;
        for (pieces.items, 0..) |p, i| {
            const v = pieces.items[victim];
            if (p.priority < v.priority or (p.priority == v.priority and p.order > v.order)) victim = i;
        }
        _ = pieces.orderedRemove(victim);
    }
}

fn lineWidth(pieces: []const Piece, style: cfgm.Style) usize {
    var w: usize = 0;
    for (pieces, 0..) |p, i| {
        w += p.width;
        if (style.mode == .powerline) {
            w += 3; // padding on both sides + separator
        } else if (i > 0) {
            w += displayWidth(style.sep);
        }
    }
    return w;
}

fn assemble(a: Allocator, out: *std.ArrayList(u8), style: cfgm.Style, pieces: []const Piece, columns: usize) !void {
    var left: std.ArrayList(Piece) = .empty;
    var right: std.ArrayList(Piece) = .empty;
    for (pieces) |p| try (if (p.right) &right else &left).append(a, p);

    try joinGroup(a, out, style, left.items);
    if (right.items.len == 0) return;
    const lw = lineWidth(left.items, style);
    const rw = lineWidth(right.items, style);
    const gap = if (columns > lw + rw) columns - lw - rw else 1;
    try out.appendNTimes(a, ' ', if (left.items.len == 0 and columns == 0) 0 else gap);
    try joinGroup(a, out, style, right.items);
}

fn joinGroup(a: Allocator, out: *std.ArrayList(u8), style: cfgm.Style, pieces: []const Piece) !void {
    for (pieces, 0..) |p, i| {
        switch (style.mode) {
            .plain => {
                if (i > 0) {
                    if (style.sep_color != .none) {
                        try sgr(a, out, style.sep_color, .none, false, false, false);
                        try out.appendSlice(a, style.sep);
                        try out.appendSlice(a, R);
                    } else {
                        try out.appendSlice(a, style.sep);
                    }
                }
                try out.appendSlice(a, p.text);
            },
            .powerline => {
                if (i > 0) {
                    // Same background on both sides would make the arrow invisible; use the thin one
                    if (std.meta.eql(pieces[i - 1].bg, p.bg)) {
                        const fg: cfgm.Color = if (style.sep_color != .none) style.sep_color else .{ .idx = 244 };
                        try sgr(a, out, fg, p.bg, false, false, false);
                        try out.appendSlice(a, PL_THIN);
                    } else {
                        try sgr(a, out, pieces[i - 1].bg, p.bg, false, false, false);
                        try out.appendSlice(a, PL_SEP);
                    }
                }
                try out.appendSlice(a, p.text);
            },
        }
    }
    if (style.mode == .powerline and pieces.len > 0) {
        try out.appendSlice(a, R);
        try sgr(a, out, pieces[pieces.len - 1].bg, .none, false, false, false);
        try out.appendSlice(a, PL_SEP);
        try out.appendSlice(a, R);
    }
}

// ---------------------------------------------------------------------------
// segments

/// Render one segment, or null when it should be hidden.
fn piece(a: Allocator, style: cfgm.Style, s: *const Seg, f: *const Facts) !?[]const u8 {
    const d = s.def;
    if (d.gate.len > 0 and !(f.flag(d.gate) orelse false)) return null;

    var body: std.ArrayList(u8) = .empty;
    var fg = s.color;
    const value: ?f64 = if (d.fact.len > 0) f.num(d.fact) else null;

    if (value) |v| {
        if (s.show == .nonzero and v == 0) return null;
        if (s.min) |m| if (v < m) return null;
        if (s.rules.len > 0) fg = ruleColor(s.rules, s.gradient, v * d.scale);
    }

    const pl = style.mode == .powerline;
    const bg: Color = if (pl) (if (s.bg == .none) PL_BG else s.bg) else s.bg;

    const ok = switch (d.kind) {
        .bar => try barBody(a, &body, s, f, fg, bg),
        .flag => blk: {
            const on = f.flag(d.fact) orelse break :blk false;
            const text = if (on) s.on else s.off;
            if (text.len == 0) break :blk false;
            if (!on) fg = s.off_color;
            try body.appendSlice(a, text);
            break :blk true;
        },
        else => try valueText(a, &body, s, f, value),
    };
    if (!ok) {
        if (s.show != .always) return null;
        body.clearRetainingCapacity();
        try body.appendSlice(a, "-");
    }

    var out: std.ArrayList(u8) = .empty;
    try sgr(a, &out, fg, bg, s.bold, s.dim, s.italic);
    if (pl) try out.append(a, ' ');
    if (s.icon.len > 0) {
        try out.appendSlice(a, s.icon);
        try out.append(a, ' ');
    }
    if (s.label.len > 0) {
        try out.appendSlice(a, s.label);
        try out.append(a, ' ');
    }
    try out.appendSlice(a, body.items);
    if (d.kind != .bar) try out.appendSlice(a, s.suffix);
    if (pl) {
        try out.append(a, ' ');
    } else {
        try out.appendSlice(a, R);
    }
    return try out.toOwnedSlice(a);
}

/// Text for value-like kinds. Returns false when the value is missing.
fn valueText(a: Allocator, b: *std.ArrayList(u8), s: *const Seg, f: *const Facts, value: ?f64) !bool {
    const d = s.def;
    const w = Out{ .a = a, .b = b };
    switch (d.kind) {
        .text => {
            const raw = switch (d.source) {
                .custom => customText(a, s, f) orelse return false,
                else => f.str(d.fact) orelse return false,
            };
            try w.put(xform(a, s, raw, f));
        },
        .number => {
            const v = value orelse return false;
            try number(w, v, s.fmt, s.decimals);
        },
        .percent => {
            const v = value orelse return false;
            try fixed(w, v * d.scale, s.decimals);
            try w.put("%");
        },
        .money => {
            const v = value orelse return false;
            try w.put(if (s.fmt.len > 0) s.fmt else "$");
            try fixed(w, v, s.decimals);
        },
        .duration => {
            const v = value orelse return false;
            const secs: i64 = @intFromFloat(@max(0, if (d.unit == .ms) @floor(v / 1000) else @floor(v)));
            try duration(w, secs, s.fmt);
        },
        .fraction => {
            const used = f.num(d.used) orelse return false;
            const total = f.num(d.total) orelse return false;
            try compact(w, used);
            try w.put("/");
            try compact(w, total);
        },
        .countdown => {
            const v = value orelse return false;
            const now = f.num("sys.now") orelse return false;
            if (std.mem.eql(u8, s.fmt, "time")) {
                try clock(w, @intFromFloat(v), tzOffset(a, s, f), "%H:%M");
            } else {
                const left: i64 = @intFromFloat(v - now);
                if (left <= 0) return false;
                try duration(w, left, "compact");
            }
        },
        .ago => {
            const v = value orelse return false;
            const now = f.num("sys.now") orelse return false;
            try duration(w, @intFromFloat(@max(0, now - v)), "compact");
        },
        .clock => {
            const now = f.num("sys.now") orelse return false;
            try clock(w, @intFromFloat(now), tzOffset(a, s, f), s.fmt);
        },
        .pr => {
            const n = value orelse return false;
            const url = f.str("pr.url");
            if (s.link) if (url) |u| try w.print("\x1b]8;;{s}\x1b\\", .{u});
            try w.print("#{d}", .{@as(i64, @intFromFloat(n))});
            if (f.str("pr.review_state")) |st| {
                const mark = if (std.mem.eql(u8, st, "approved")) " ✓" else if (std.mem.eql(u8, st, "changes_requested")) " ✗" else if (std.mem.eql(u8, st, "draft")) " draft" else " ●";
                try w.put(mark);
            }
            if (s.link and url != null) try w.put("\x1b]8;;\x1b\\");
        },
        .flag, .bar => unreachable,
    }
    return true;
}

fn customText(a: Allocator, s: *const Seg, f: *const Facts) ?[]const u8 {
    if (std.mem.eql(u8, s.def.id, "text")) return if (s.text.len > 0) s.text else null;
    if (std.mem.eql(u8, s.def.id, "env")) return f.str(std.fmt.allocPrint(a, "env:{s}", .{s.env}) catch return null);
    if (std.mem.eql(u8, s.def.id, "command")) return f.str(std.fmt.allocPrint(a, "cmd:{s}", .{s.cmd}) catch return null);
    return null;
}

fn xform(a: Allocator, s: *const Seg, raw: []const u8, f: *const Facts) []const u8 {
    return switch (s.def.xform) {
        .none => raw,
        .short => raw[0..@min(raw.len, 8)],
        .strip_ctx => stripContext(a, raw),
        .dir => switch (s.dir) {
            .full => raw,
            .base => std.fs.path.basenamePosix(raw),
            .home => blk: {
                const home = f.str("sys.home") orelse break :blk raw;
                if (home.len == 0 or !std.mem.startsWith(u8, raw, home)) break :blk raw;
                if (raw.len > home.len and raw[home.len] != '/') break :blk raw;
                break :blk std.fmt.allocPrint(a, "~{s}", .{raw[home.len..]}) catch raw;
            },
        },
    };
}

/// Drop a " (… context)" suffix from the model name, e.g. "Opus 5.5 (1M context)".
fn stripContext(a: Allocator, model: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, model, '(') orelse return model;
    const j = std.mem.indexOfScalarPos(u8, model, i, ')') orelse return model;
    const inner = model[i + 1 .. j];
    if (inner.len < 7 or !std.mem.endsWith(u8, inner, "ontext")) return model;
    const c = inner[inner.len - 7];
    if (c != 'C' and c != 'c') return model;
    const head = std.mem.trimRight(u8, model[0..i], " ");
    if (j + 1 >= model.len) return head;
    return std.mem.concat(a, u8, &.{ head, model[j + 1 ..] }) catch model;
}

fn barBody(a: Allocator, b: *std.ArrayList(u8), s: *const Seg, f: *const Facts, fg: Color, bg: Color) !bool {
    const d = s.def;
    const pct = f.num(d.fact) orelse return false;
    const bar = s.bar;
    const on = rgbOf(fg);
    const off = rgbOf(bar.empty_color);
    const exact = std.math.clamp(pct, 0, 100) / 100 * @as(f64, @floatFromInt(bar.cells));
    const same = std.mem.eql(u8, bar.full, bar.empty);
    const w = Out{ .a = a, .b = b };
    const eighths = [_][]const u8{ "▏", "▎", "▍", "▌", "▋", "▊", "▉" };

    for (0..bar.cells) |i| {
        const frac = std.math.clamp(exact - @as(f64, @floatFromInt(i)), 0, 1);
        if (bar.eighths) {
            if (frac >= 1) {
                try sgr(a, b, fg, bg, false, false, false);
                try w.put(bar.full);
            } else if (frac <= 0) {
                try sgr(a, b, bar.empty_color, bg, false, false, false);
                try w.put(bar.empty);
            } else {
                const k: usize = @intFromFloat(@round(frac * 8));
                try sgr(a, b, fg, bg, false, false, false);
                try w.put(if (k == 0) bar.empty else if (k >= 8) bar.full else eighths[k - 1]);
            }
            continue;
        }
        const ch = if (same or frac >= 0.5) bar.full else bar.empty;
        if (bar.blend) {
            var c: [3]u8 = undefined;
            for (0..3) |k| {
                const o: f64 = @floatFromInt(off[k]);
                const n: f64 = @floatFromInt(on[k]);
                c[k] = @intFromFloat(@round(o + (n - o) * frac));
            }
            try w.print("\x1b[38;2;{d};{d};{d}m", .{ c[0], c[1], c[2] });
        } else {
            try sgr(a, b, if (frac >= 0.5) fg else bar.empty_color, bg, false, false, false);
        }
        try w.put(ch);
    }

    try sgr(a, b, fg, bg, s.bold, s.dim, s.italic);
    const p: i64 = @intFromFloat(@round(pct));
    switch (bar.text) {
        .none => {},
        .pct => try w.print(" {d}%", .{p}),
        .used_total, .used_total_pct => {
            const used = if (d.used.len > 0) f.num(d.used) else null;
            const total = if (d.total.len > 0) f.num(d.total) else null;
            if (used != null and total != null and total.? > 0) {
                try w.put(" ");
                try compact(w, used.?);
                try w.put("/");
                try compact(w, total.?);
            }
            if (bar.text == .used_total_pct) try w.print(" ({d}%)", .{p});
        },
    }
    return true;
}

// ---------------------------------------------------------------------------
// colour

fn ruleColor(rules: []const cfgm.Rule, gradient: bool, v: f64) Color {
    var idx: ?usize = null;
    for (rules, 0..) |r, i| {
        if (v >= r.min) idx = i;
    }
    const i = idx orelse return rules[0].color;
    if (!gradient or i + 1 >= rules.len) return rules[i].color;
    const lo = rules[i];
    const hi = rules[i + 1];
    const t = std.math.clamp((v - lo.min) / (hi.min - lo.min), 0, 1);
    const x = rgbOf(lo.color);
    const y = rgbOf(hi.color);
    var c: [3]u8 = undefined;
    for (0..3) |k| {
        const xf: f64 = @floatFromInt(x[k]);
        const yf: f64 = @floatFromInt(y[k]);
        c[k] = @intFromFloat(@round(xf + (yf - xf) * t));
    }
    return .{ .rgb = c };
}

pub fn rgbOf(c: Color) [3]u8 {
    return switch (c) {
        .rgb => |v| v,
        .idx => |n| xtermRgb(n),
        .none => .{ 192, 192, 192 },
    };
}

fn xtermRgb(n: u8) [3]u8 {
    if (n < 16) {
        const base = [16][3]u8{
            .{ 0, 0, 0 },       .{ 128, 0, 0 },   .{ 0, 128, 0 },   .{ 128, 128, 0 },
            .{ 0, 0, 128 },     .{ 128, 0, 128 }, .{ 0, 128, 128 }, .{ 192, 192, 192 },
            .{ 128, 128, 128 }, .{ 255, 0, 0 },   .{ 0, 255, 0 },   .{ 255, 255, 0 },
            .{ 0, 0, 255 },     .{ 255, 0, 255 }, .{ 0, 255, 255 }, .{ 255, 255, 255 },
        };
        return base[n];
    }
    if (n >= 232) {
        const v: u8 = 8 + (n - 232) * 10;
        return .{ v, v, v };
    }
    const lv = [6]u8{ 0, 95, 135, 175, 215, 255 };
    const k = n - 16;
    return .{ lv[k / 36], lv[(k / 6) % 6], lv[k % 6] };
}

fn sgr(a: Allocator, out: *std.ArrayList(u8), fg: Color, bg: Color, bold: bool, dim: bool, italic: bool) !void {
    var parts: [6][]const u8 = undefined;
    var n: usize = 0;
    var buf: [2][24]u8 = undefined;
    if (bold) {
        parts[n] = "1";
        n += 1;
    }
    if (dim) {
        parts[n] = "2";
        n += 1;
    }
    if (italic) {
        parts[n] = "3";
        n += 1;
    }
    switch (fg) {
        .none => {},
        .idx => |i| {
            parts[n] = try std.fmt.bufPrint(&buf[0], "38;5;{d}", .{i});
            n += 1;
        },
        .rgb => |c| {
            parts[n] = try std.fmt.bufPrint(&buf[0], "38;2;{d};{d};{d}", .{ c[0], c[1], c[2] });
            n += 1;
        },
    }
    switch (bg) {
        .none => {},
        .idx => |i| {
            parts[n] = try std.fmt.bufPrint(&buf[1], "48;5;{d}", .{i});
            n += 1;
        },
        .rgb => |c| {
            parts[n] = try std.fmt.bufPrint(&buf[1], "48;2;{d};{d};{d}", .{ c[0], c[1], c[2] });
            n += 1;
        },
    }
    if (n == 0) return;
    try out.appendSlice(a, "\x1b[");
    for (parts[0..n], 0..) |p, i| {
        if (i > 0) try out.append(a, ';');
        try out.appendSlice(a, p);
    }
    try out.append(a, 'm');
}

// ---------------------------------------------------------------------------
// formatting

const Out = struct {
    a: Allocator,
    b: *std.ArrayList(u8),

    fn put(self: Out, s: []const u8) !void {
        try self.b.appendSlice(self.a, s);
    }

    fn print(self: Out, comptime f: []const u8, args: anytype) !void {
        try self.b.print(self.a, f, args);
    }
};

/// 90000 -> 90k, 1000000 -> 1M, 1500000 -> 1.5M
fn compact(w: Out, n: f64) !void {
    var v = n;
    var s: []const u8 = "";
    if (n >= 1e9) {
        v = n / 1e9;
        s = "G";
    } else if (n >= 1e6) {
        v = n / 1e6;
        s = "M";
    } else if (n >= 1e3) {
        v = n / 1e3;
        s = "k";
    }
    if (v >= 10 or s.len == 0) {
        try w.print("{d}{s}", .{ @as(i64, @intFromFloat(v + 0.5)), s });
        return;
    }
    var buf: [32]u8 = undefined;
    const t = try std.fmt.bufPrint(&buf, "{d:.1}", .{v});
    const trimmed = if (std.mem.endsWith(u8, t, ".0")) t[0 .. t.len - 2] else t;
    try w.print("{s}{s}", .{ trimmed, s });
}

fn fixed(w: Out, v: f64, decimals: u8) !void {
    switch (decimals) {
        0 => try w.print("{d:.0}", .{v}),
        1 => try w.print("{d:.1}", .{v}),
        2 => try w.print("{d:.2}", .{v}),
        3 => try w.print("{d:.3}", .{v}),
        else => try w.print("{d:.4}", .{v}),
    }
}

fn number(w: Out, v: f64, fmt: []const u8, decimals: u8) !void {
    if (std.mem.eql(u8, fmt, "compact")) return compact(w, v);
    if (std.mem.eql(u8, fmt, "grouped") and decimals == 0) {
        var buf: [32]u8 = undefined;
        const digits = try std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(@round(@abs(v))))});
        if (v < 0) try w.put("-");
        for (digits, 0..) |c, i| {
            if (i > 0 and (digits.len - i) % 3 == 0) try w.put(",");
            try w.b.append(w.a, c);
        }
        return;
    }
    if (decimals == 0) return w.print("{d}", .{@as(i64, @intFromFloat(@round(v)))});
    return fixed(w, v, decimals);
}

/// hm: "1hr 5m" / "5m"; ms: "65:03"; clock: "1:05:03" / "5:03"; min: "65m";
/// compact: "1h5m" / "5m" / "30s" / "2d3h"
fn duration(w: Out, secs: i64, fmt: []const u8) !void {
    const m = @divFloor(secs, 60);
    const h = @divFloor(m, 60);
    if (std.mem.eql(u8, fmt, "ms")) return w.print("{d}:{d:0>2}", .{ @as(u64, @intCast(m)), @as(u64, @intCast(@mod(secs, 60))) });
    if (std.mem.eql(u8, fmt, "min")) return w.print("{d}m", .{m});
    if (std.mem.eql(u8, fmt, "clock")) {
        if (h > 0) return w.print("{d}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(h)), @as(u64, @intCast(@mod(m, 60))), @as(u64, @intCast(@mod(secs, 60))) });
        return w.print("{d}:{d:0>2}", .{ @as(u64, @intCast(m)), @as(u64, @intCast(@mod(secs, 60))) });
    }
    if (std.mem.eql(u8, fmt, "compact")) {
        const d = @divFloor(h, 24);
        if (d > 0) return w.print("{d}d{d}h", .{ d, @mod(h, 24) });
        if (h > 0) return w.print("{d}h{d}m", .{ h, @mod(m, 60) });
        if (m > 0) return w.print("{d}m", .{m});
        return w.print("{d}s", .{secs});
    }
    if (h > 0) return w.print("{d}hr {d}m", .{ h, @mod(m, 60) });
    return w.print("{d}m", .{m});
}

fn tzOffset(a: Allocator, s: *const Seg, f: *const Facts) i64 {
    const key = std.fmt.allocPrint(a, "tz:{s}", .{s.tz}) catch return 0;
    const v = f.num(key) orelse f.num("tz:") orelse 0;
    return @intFromFloat(v);
}

/// strftime subset: %Y %y %m %d %H %I %M %S %p %a %b %%
fn clock(w: Out, epoch: i64, offset: i64, fmt: []const u8) !void {
    const t = epoch + offset;
    const days = @divFloor(t, 86400);
    const sod = @mod(t, 86400);
    const civil = civilFromDays(days);
    const wday: usize = @intCast(@mod(days + 4, 7)); // 1970-01-01 was a Thursday
    const hour = @divFloor(sod, 3600);
    const minute = @divFloor(@mod(sod, 3600), 60);
    const second = @mod(sod, 60);
    const wdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] != '%' or i + 1 >= fmt.len) {
            try w.b.append(w.a, fmt[i]);
            continue;
        }
        i += 1;
        const u = struct {
            fn two(x: i64) u64 {
                return @intCast(x);
            }
        }.two;
        switch (fmt[i]) {
            'Y' => try w.print("{d}", .{civil.y}),
            'y' => try w.print("{d:0>2}", .{u(@mod(civil.y, 100))}),
            'm' => try w.print("{d:0>2}", .{u(civil.m)}),
            'd' => try w.print("{d:0>2}", .{u(civil.d)}),
            'H' => try w.print("{d:0>2}", .{u(hour)}),
            'I' => try w.print("{d:0>2}", .{u(if (@mod(hour, 12) == 0) 12 else @mod(hour, 12))}),
            'M' => try w.print("{d:0>2}", .{u(minute)}),
            'S' => try w.print("{d:0>2}", .{u(second)}),
            'p' => try w.put(if (hour < 12) "AM" else "PM"),
            'a' => try w.put(wdays[wday]),
            'b' => try w.put(months[@intCast(civil.m - 1)]),
            '%' => try w.put("%"),
            else => {
                try w.b.append(w.a, '%');
                try w.b.append(w.a, fmt[i]);
            },
        }
    }
}

const Civil = struct { y: i64, m: i64, d: i64 };

/// Days since 1970-01-01 -> civil date (H. Hinnant).
fn civilFromDays(z0: i64) Civil {
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0), .m = m, .d = d };
}

// ---------------------------------------------------------------------------
// width

/// Terminal columns taken by `s`, ignoring CSI and OSC escape sequences.
pub fn displayWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == 0x1b and i + 1 < s.len) {
            if (s[i + 1] == '[') {
                i += 2;
                while (i < s.len and (s[i] < 0x40 or s[i] > 0x7e)) i += 1;
                i += 1;
                continue;
            }
            if (s[i + 1] == ']') {
                i += 2;
                while (i < s.len) {
                    if (s[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                continue;
            }
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const cp = std.unicode.utf8Decode(s[i..@min(s.len, i + len)]) catch c;
        w += if (isWide(cp)) 2 else 1;
        i += len;
    }
    return w;
}

fn isWide(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE4F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1F64F) or
        (cp >= 0x1F900 and cp <= 0x1F9FF) or
        (cp >= 0x20000 and cp <= 0x3FFFD);
}

// ---------------------------------------------------------------------------
// tests

const testing = std.testing;

fn testRender(a: Allocator, cfg_json: []const u8, facts_json: []const u8, columns: usize) ![]u8 {
    const cfg = try cfgm.parse(a, cfg_json);
    var f = Facts.init(a);
    f.addJson("", try std.json.parseFromSliceLeaky(std.json.Value, a, facts_json, .{}));
    f.derive();
    return render(a, cfg, &f, columns);
}

test "order, lines, icon and label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try testRender(arena.allocator(),
        \\{"lines":[[{"id":"cost","icon":"💰","label":"花费","color":220},{"id":"model","icon":null}],[{"id":"effort","icon":""}]]}
    ,
        \\{"cost":{"total_cost_usd":1.234},"model":{"display_name":"Opus 5.5 (1M context)"},"effort":{"level":"high"}}
    , 0);
    try testing.expectEqualStrings("\x1b[38;5;220m💰 花费 $1.23\x1b[0m \x1b[38;5;141mOpus 5.5\x1b[0m\n\x1b[38;5;214mhigh\x1b[0m\n", out);
}

test "threshold colour and hidden segments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try testRender(arena.allocator(),
        \\{"lines":[[{"id":"ctx-used-pct","icon":"","rules":[[50,"#ffff00"],[80,"#ff0000"]]},{"id":"cache-hit"}]]}
    ,
        \\{"context_window":{"used_percentage":85}}
    , 0);
    try testing.expectEqualStrings("\x1b[38;2;255;0;0m85%\x1b[0m\n", out);
}

test "blended braille bar" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try testRender(arena.allocator(),
        \\{"lines":[[{"id":"limit-5h-bar","icon":"","color":"#ffffff","rules":[],"bar":{"cells":2,"empty_color":"#000000","text":"none"}}]]}
    ,
        \\{"rate_limits":{"five_hour":{"used_percentage":75}}}
    , 0);
    try testing.expectEqualStrings("\x1b[38;2;255;255;255m\x1b[38;2;255;255;255m⣿\x1b[38;2;128;128;128m⣿\x1b[38;2;255;255;255m\x1b[0m\n", out);
}

test "eighth blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try testRender(arena.allocator(),
        \\{"lines":[[{"id":"limit-5h-bar","icon":"","color":1,"rules":[],"bar":{"chars":"blocks","cells":4,"empty_color":2,"text":"none"}}]]}
    ,
        \\{"rate_limits":{"five_hour":{"used_percentage":50}}}
    , 0);
    try testing.expectEqualStrings("\x1b[38;5;1m\x1b[38;5;1m█\x1b[38;5;1m█\x1b[38;5;2m \x1b[38;5;2m \x1b[38;5;1m\x1b[0m\n", out);
}

test "narrow terminal drops lowest priority first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try testRender(arena.allocator(),
        \\{"lines":[[{"id":"text","text":"aaaa","icon":"","color":null},{"id":"text","text":"bbbb","icon":"","priority":10,"color":null},{"id":"text","text":"cccc","icon":"","color":null}]]}
    , "{}", 10);
    try testing.expectEqualStrings("aaaa\x1b[0m cccc\x1b[0m\n", out);
}

test "durations and clock" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try testRender(arena.allocator(),
        \\{"lines":[[{"id":"session-duration","icon":""},{"id":"clock","icon":"","fmt":"%Y-%m-%d %H:%M %a","tz":"America/Los_Angeles"},{"id":"limit-5h-reset","icon":""}]]}
    ,
        \\{"cost":{"total_duration_ms":3900000},"sys":{"now":1792468800},"tz:America/Los_Angeles":-25200,
        \\ "rate_limits":{"five_hour":{"resets_at":1792476000}}}
    , 0);
    try testing.expectEqualStrings("\x1b[38;5;183m1hr 5m\x1b[0m \x1b[38;5;252m2026-10-19 21:00 Mon\x1b[0m \x1b[38;5;110m2h0m\x1b[0m\n", out);
}

test "display width skips escapes" {
    try testing.expectEqual(@as(usize, 5), displayWidth("\x1b[38;5;1mab\x1b[0m中c\x1b]8;;http://x\x1b\\"));
}
