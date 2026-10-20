//! Config v1: which segments appear, in which order, and how each one looks.
//! Stored as plain JSON in ~/.config/omnitt-statusline/config.json and passed
//! around as a "config code" (`j` + base64url(JSON) or `z` + base64url(raw deflate)).

const std = @import("std");
const registry = @import("registry.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Color = union(enum) {
    none,
    idx: u8,
    rgb: [3]u8,
};

pub const Rule = struct { min: f64, color: Color };

pub const Show = enum { present, always, nonzero };

pub const BarText = enum { none, pct, used_total, used_total_pct };

pub const Bar = struct {
    full: []const u8 = "⣿",
    empty: []const u8 = "⣿",
    /// Use ▏▎▍▌▋▊▉ for the boundary cell instead of colour blending.
    eighths: bool = false,
    cells: u8 = 10,
    /// Blend the boundary cell between the full and empty colours (true colour).
    blend: bool = true,
    empty_color: Color = .{ .idx = 238 },
    text: BarText = .pct,
};

pub const DirStyle = enum { base, home, full };

pub const Seg = struct {
    def: *const registry.Def,
    icon: []const u8,
    label: []const u8 = "",
    color: Color,
    bg: Color = .none,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    fmt: []const u8,
    decimals: u8,
    suffix: []const u8,
    rules: []const Rule,
    gradient: bool = false,
    show: Show = .present,
    min: ?f64 = null,
    priority: i32 = 50,
    right: bool = false,
    bar: Bar = .{},
    on: []const u8,
    off: []const u8,
    off_color: Color,
    link: bool = true,
    dir: DirStyle = .base,
    // custom segments
    text: []const u8 = "",
    env: []const u8 = "",
    cmd: []const u8 = "",
    timeout_ms: u32 = 200,
    ttl_s: u32 = 5,
    tz: []const u8 = "",
};

pub const Mode = enum { plain, powerline };

pub const Style = struct {
    mode: Mode = .plain,
    sep: []const u8 = " ",
    sep_color: Color = .none,
};

pub const Config = struct {
    lines: []const []const Seg,
    style: Style = .{},
    padding: u32 = 0,
    refresh: ?u32 = null,
    /// Segment ids in the source config that this build does not know.
    unknown: []const []const u8 = &.{},
};

pub const default_json =
    \\{"v":1,"lines":[
    \\[{"id":"model"},{"id":"effort"},{"id":"ctx-bar","bar":{"cells":11}},{"id":"compactions"},{"id":"session-duration"}],
    \\[{"id":"tokens-in"},{"id":"tokens-out"},{"id":"cache-hit"},{"id":"cache-warm"},{"id":"turn-time"},{"id":"speed"},
    \\ {"id":"cost"},{"id":"git-branch"},{"id":"git-diff-add"},{"id":"git-diff-del"}]]}
;

pub const Error = error{ InvalidConfig, OutOfMemory };

pub fn parse(a: Allocator, json: []const u8) Error!Config {
    const root = std.json.parseFromSliceLeaky(Value, a, json, .{}) catch return error.InvalidConfig;
    return fromValue(a, root);
}

pub fn fromValue(a: Allocator, root: Value) Error!Config {
    if (root != .object) return error.InvalidConfig;
    const o = root.object;
    var cfg: Config = .{ .lines = &.{} };
    var unknown: std.ArrayList([]const u8) = .empty;

    if (o.get("style")) |s| if (s == .object) {
        if (s.object.get("mode")) |m| if (m == .string) {
            cfg.style.mode = std.meta.stringToEnum(Mode, m.string) orelse .plain;
        };
        if (str(s.object.get("sep"))) |v| cfg.style.sep = v;
        if (s.object.get("sep_color")) |c| cfg.style.sep_color = color(c);
    };
    if (o.get("padding")) |p| if (int(p)) |n| {
        cfg.padding = @intCast(std.math.clamp(n, 0, 20));
    };
    if (o.get("refresh")) |p| if (int(p)) |n| {
        if (n >= 1) cfg.refresh = @intCast(@min(n, 3600));
    };

    const lines_v = o.get("lines") orelse return error.InvalidConfig;
    if (lines_v != .array) return error.InvalidConfig;
    var lines: std.ArrayList([]const Seg) = .empty;
    for (lines_v.array.items) |lv| {
        if (lv != .array) continue;
        var segs: std.ArrayList(Seg) = .empty;
        for (lv.array.items) |sv| {
            if (sv != .object) continue;
            const id = str(sv.object.get("id")) orelse continue;
            const def = registry.find(id) orelse {
                try unknown.append(a, id);
                continue;
            };
            try segs.append(a, try segment(a, def, sv.object));
        }
        try lines.append(a, try segs.toOwnedSlice(a));
    }
    cfg.lines = try lines.toOwnedSlice(a);
    cfg.unknown = try unknown.toOwnedSlice(a);
    return cfg;
}

fn segment(a: Allocator, def: *const registry.Def, o: std.json.ObjectMap) Error!Seg {
    var s: Seg = .{
        .def = def,
        .icon = def.icon,
        .color = .{ .idx = def.color },
        .fmt = def.fmt,
        .decimals = def.decimals,
        .suffix = def.suffix,
        .rules = &.{},
        .on = def.on,
        .off = def.off,
        .off_color = if (def.off_color) |c| .{ .idx = c } else .{ .idx = def.color },
    };
    if (def.rules.len > 0) {
        const rules = try a.alloc(Rule, def.rules.len);
        for (def.rules, rules) |r, *out| out.* = .{ .min = r[0], .color = .{ .idx = @intFromFloat(r[1]) } };
        s.rules = rules;
    }
    if (def.kind == .bar) s.bar.text = std.meta.stringToEnum(BarText, def.fmt) orelse .pct;

    if (str(o.get("icon"))) |v| s.icon = v;
    if (o.get("icon")) |v| if (v == .null) {
        s.icon = "";
    };
    if (str(o.get("label"))) |v| s.label = v;
    if (o.get("color")) |v| s.color = color(v);
    if (o.get("bg")) |v| s.bg = color(v);
    if (o.get("off_color")) |v| s.off_color = color(v);
    if (boolean(o.get("bold"))) |v| s.bold = v;
    if (boolean(o.get("dim"))) |v| s.dim = v;
    if (boolean(o.get("italic"))) |v| s.italic = v;
    if (str(o.get("fmt"))) |v| s.fmt = v;
    if (o.get("decimals")) |v| if (int(v)) |n| {
        s.decimals = @intCast(std.math.clamp(n, 0, 6));
    };
    if (str(o.get("suffix"))) |v| s.suffix = v;
    if (str(o.get("on"))) |v| s.on = v;
    if (str(o.get("off"))) |v| s.off = v;
    if (boolean(o.get("gradient"))) |v| s.gradient = v;
    if (boolean(o.get("right"))) |v| s.right = v;
    if (boolean(o.get("link"))) |v| s.link = v;
    if (o.get("priority")) |v| if (int(v)) |n| {
        s.priority = @intCast(std.math.clamp(n, -1000, 1000));
    };
    if (str(o.get("show"))) |v| s.show = std.meta.stringToEnum(Show, v) orelse .present;
    if (o.get("min")) |v| s.min = float(v);
    if (str(o.get("dir"))) |v| s.dir = std.meta.stringToEnum(DirStyle, v) orelse .base;
    if (str(o.get("text"))) |v| s.text = v;
    if (str(o.get("env"))) |v| s.env = v;
    if (str(o.get("cmd"))) |v| s.cmd = v;
    if (str(o.get("tz"))) |v| s.tz = v;
    if (o.get("timeout")) |v| if (int(v)) |n| {
        s.timeout_ms = @intCast(std.math.clamp(n, 10, 2000));
    };
    if (o.get("ttl")) |v| if (int(v)) |n| {
        s.ttl_s = @intCast(std.math.clamp(n, 0, 86400));
    };

    if (o.get("rules")) |rv| if (rv == .array) {
        var rules: std.ArrayList(Rule) = .empty;
        for (rv.array.items) |r| {
            if (r != .array or r.array.items.len != 2) continue;
            const min = float(r.array.items[0]) orelse continue;
            try rules.append(a, .{ .min = min, .color = color(r.array.items[1]) });
        }
        std.mem.sort(Rule, rules.items, {}, struct {
            fn lt(_: void, x: Rule, y: Rule) bool {
                return x.min < y.min;
            }
        }.lt);
        s.rules = try rules.toOwnedSlice(a);
    };

    if (o.get("bar")) |bv| if (bv == .object) {
        const b = bv.object;
        if (str(b.get("chars"))) |name| applyChars(&s.bar, name);
        if (str(b.get("full"))) |v| s.bar.full = v;
        if (str(b.get("empty"))) |v| s.bar.empty = v;
        if (b.get("cells")) |v| if (int(v)) |n| {
            s.bar.cells = @intCast(std.math.clamp(n, 1, 40));
        };
        if (boolean(b.get("blend"))) |v| s.bar.blend = v;
        if (b.get("empty_color")) |v| s.bar.empty_color = color(v);
        if (str(b.get("text"))) |v| s.bar.text = std.meta.stringToEnum(BarText, v) orelse s.bar.text;
    };
    return s;
}

pub const bar_presets = [_]struct { name: []const u8, full: []const u8, empty: []const u8, eighths: bool = false }{
    .{ .name = "braille", .full = "⣿", .empty = "⣿" },
    .{ .name = "blocks", .full = "█", .empty = " ", .eighths = true },
    .{ .name = "shade", .full = "█", .empty = "░" },
    .{ .name = "dots", .full = "●", .empty = "○" },
    .{ .name = "line", .full = "━", .empty = "─" },
    .{ .name = "ascii", .full = "#", .empty = "-" },
};

fn applyChars(b: *Bar, name: []const u8) void {
    for (bar_presets) |p| {
        if (std.mem.eql(u8, p.name, name)) {
            b.full = p.full;
            b.empty = p.empty;
            b.eighths = p.eighths;
            return;
        }
    }
}

fn str(v: ?Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn boolean(v: ?Value) ?bool {
    return switch (v orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

fn int(v: Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) @intFromFloat(f) else null,
        else => null,
    };
}

fn float(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

/// 0–255 -> xterm-256 index; "#rrggbb" -> true colour; anything else -> none.
pub fn color(v: Value) Color {
    switch (v) {
        .integer => |i| if (i >= 0 and i <= 255) return .{ .idx = @intCast(i) },
        .string => |s| if (s.len == 7 and s[0] == '#') {
            var rgb: [3]u8 = undefined;
            for (0..3) |k| rgb[k] = std.fmt.parseInt(u8, s[1 + k * 2 .. 3 + k * 2], 16) catch return .none;
            return .{ .rgb = rgb };
        },
        else => {},
    }
    return .none;
}

// ---------------------------------------------------------------------------
// config codes

const b64 = std.base64.url_safe_no_pad;

pub fn encode(a: Allocator, json: []const u8) ![]u8 {
    const out = try a.alloc(u8, 1 + b64.Encoder.calcSize(json.len));
    out[0] = 'j';
    _ = b64.Encoder.encode(out[1..], json);
    return out;
}

pub fn decode(a: Allocator, code: []const u8) ![]u8 {
    const t = std.mem.trim(u8, code, " \t\r\n'\"");
    if (t.len < 2) return error.InvalidCode;
    const body = t[1..];
    const raw = try a.alloc(u8, b64.Decoder.calcSizeForSlice(body) catch return error.InvalidCode);
    b64.Decoder.decode(raw, body) catch return error.InvalidCode;
    return switch (t[0]) {
        'j' => raw,
        'z' => inflate(a, raw),
        else => error.InvalidCode,
    };
}

fn inflate(a: Allocator, data: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&in, .raw, &window);
    return d.reader.allocRemaining(a, .limited(1 << 20)) catch error.InvalidCode;
}

test "default config parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), default_json);
    try std.testing.expectEqual(@as(usize, 2), cfg.lines.len);
    try std.testing.expectEqual(@as(usize, 5), cfg.lines[0].len);
    try std.testing.expectEqual(@as(u8, 11), cfg.lines[0][2].bar.cells);
    try std.testing.expectEqual(@as(usize, 3), cfg.lines[0][2].rules.len);
}

test "code round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const code = try encode(a, default_json);
    try std.testing.expectEqualStrings(default_json, try decode(a, code));
}

test "raw deflate code" {
    // printf '{"v":1}' | python3 -c 'import sys,zlib,base64;c=zlib.compressobj(9,zlib.DEFLATED,-15);d=c.compress(sys.stdin.buffer.read())+c.flush();print(base64.urlsafe_b64encode(d).decode().rstrip("="))'
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("{\"v\":1}", try decode(arena.allocator(), "zq1YqU7IyrAUA"));
}

test "unknown segments are reported, not fatal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), "{\"v\":2,\"lines\":[[{\"id\":\"model\"},{\"id\":\"from-the-future\"}]]}");
    try std.testing.expectEqual(@as(usize, 1), cfg.lines[0].len);
    try std.testing.expectEqualStrings("from-the-future", cfg.unknown[0]);
}
