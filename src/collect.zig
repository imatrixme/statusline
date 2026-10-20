//! Native collectors: turn the stdin JSON, transcript, git and system state into
//! facts. Only the collectors needed by the configured segments run.

const std = @import("std");
const builtin = @import("builtin");
const cfgm = @import("config.zig");
const Facts = @import("facts.zig").Facts;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const TAIL_BYTES = 16 << 20; // backward transcript scan bound
const GIT_TIMEOUT_MS = 300;
const GIT_TTL_S = 2;

pub const Needs = struct {
    tx: bool = false,
    tx_prompts: bool = false,
    tx_tools: bool = false,
    git_status: bool = false,
    git_untracked: bool = false,
    git_diff: bool = false,
    git_stash: bool = false,
    git_last_commit: bool = false,
    git_tag: bool = false,
    load: bool = false,
    mem: bool = false,
    battery: bool = false,

    pub fn of(cfg: cfgm.Config) Needs {
        var n: Needs = .{};
        for (cfg.lines) |line| for (line) |s| {
            const id = s.def.id;
            switch (s.def.source) {
                .transcript => {
                    n.tx = true;
                    if (eq(id, "prompts")) n.tx_prompts = true;
                    if (eq(id, "tool-calls")) n.tx_tools = true;
                },
                .git => {
                    if (eq(id, "git-diff-add") or eq(id, "git-diff-del")) {
                        n.git_diff = true;
                    } else if (eq(id, "git-stash")) {
                        n.git_stash = true;
                    } else if (eq(id, "git-last-commit")) {
                        n.git_last_commit = true;
                    } else if (eq(id, "git-tag")) {
                        n.git_tag = true;
                    } else {
                        n.git_status = true;
                        if (eq(id, "git-untracked") or eq(id, "git-dirty")) n.git_untracked = true;
                    }
                },
                .system => {
                    if (eq(id, "load")) n.load = true;
                    if (eq(id, "mem-avail")) n.mem = true;
                    if (eq(id, "battery")) n.battery = true;
                },
                else => {},
            }
        };
        return n;
    }

    fn anyGit(n: Needs) bool {
        return n.git_status or n.git_diff or n.git_stash or n.git_last_commit or n.git_tag;
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn collect(a: Allocator, cfg: cfgm.Config, input: Value, f: *Facts) void {
    f.addJson("", input);
    const now_ms = std.time.milliTimestamp();
    f.putNum("sys.now", @floatFromInt(@divFloor(now_ms, 1000)));
    if (std.posix.getenv("HOME")) |h| f.putStr("sys.home", h);

    const needs = Needs.of(cfg);
    if (needs.tx) if (f.str("transcript_path")) |p| transcript(a, f, p, now_ms, needs);
    if (needs.anyGit()) if (f.str("workspace.current_dir") orelse f.str("cwd")) |dir| git(a, f, dir, needs);
    system(a, f, cfg, needs);
    custom(a, f, cfg);
    f.derive();
}

// ---------------------------------------------------------------------------
// transcript

fn mapFile(path: []const u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const size = file.getEndPos() catch return null;
    if (size == 0) return "";
    return std.posix.mmap(null, size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, file.handle, 0) catch null;
}

fn get(v: Value, path: []const []const u8) ?Value {
    var cur = v;
    for (path) |k| {
        switch (cur) {
            .object => |o| cur = o.get(k) orelse return null,
            else => return null,
        }
    }
    return switch (cur) {
        .null => null,
        .string => |s| if (s.len == 0) null else cur,
        else => cur,
    };
}

fn gstr(v: ?Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn gnum(v: ?Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |x| x,
        else => null,
    };
}

fn gtrue(v: ?Value) bool {
    return switch (v orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

/// "2026-10-19T03:13:15.363Z" -> ms since epoch (UTC).
fn parseTs(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const p = std.fmt.parseInt;
    const y = p(i64, s[0..4], 10) catch return null;
    const mo = p(i64, s[5..7], 10) catch return null;
    const d = p(i64, s[8..10], 10) catch return null;
    const h = p(i64, s[11..13], 10) catch return null;
    const mi = p(i64, s[14..16], 10) catch return null;
    const se = p(i64, s[17..19], 10) catch return null;
    var ms: i64 = 0;
    if (s.len >= 23 and s[19] == '.') ms = p(i64, s[20..23], 10) catch 0;
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(mo + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return ((days * 24 + h) * 60 + mi) * 60_000 + se * 1000 + ms;
}

fn isPrompt(rec: Value) bool {
    if (gtrue(get(rec, &.{"isMeta"})) or gtrue(get(rec, &.{"isCompactSummary"}))) return false;
    const content = get(rec, &.{ "message", "content" }) orelse return false;
    switch (content) {
        .string => return true,
        .array => |arr| {
            for (arr.items) |x| {
                if (eq(gstr(get(x, &.{"type"})) orelse "", "tool_result")) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// Cheap line test for a real user prompt, used to count prompts over the whole file.
fn looksLikePrompt(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "\"type\":\"user\"") != null and
        std.mem.indexOf(u8, line, "\"tool_result\"") == null and
        std.mem.indexOf(u8, line, "\"isMeta\":true") == null and
        std.mem.indexOf(u8, line, "\"isCompactSummary\":true") == null;
}

fn transcript(a: Allocator, f: *Facts, path: []const u8, now_ms: i64, needs: Needs) void {
    const data = mapFile(path) orelse return;

    var compactions = std.mem.count(u8, data, "\"subtype\":\"compact_boundary\"");
    if (compactions == 0) compactions = std.mem.count(u8, data, "\"isCompactSummary\":true");
    f.putNum("tx.compactions", @floatFromInt(compactions));
    // Whole-file scans cost ~1ms per MB; only run them when a segment needs them.
    if (needs.tx_tools) f.putNum("tx.tool_calls", @floatFromInt(std.mem.count(u8, data, "\"type\":\"tool_use\"")));
    if (needs.tx_prompts) {
        var prompts: usize = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (looksLikePrompt(line)) prompts += 1;
        }
        f.putNum("tx.prompts", @floatFromInt(prompts));
    }

    // Walk backwards. Turn time = since the last real user prompt (to the final
    // end_turn reply if the turn has finished, else to now). Speed = output tokens
    // of the latest response / time from the preceding record to its last chunk.
    const lo = if (data.len > TAIL_BYTES) data.len - TAIL_BYTES else 0;
    var seen_any = false;
    var top_ended = false;
    var phase: u8 = 0;
    var mid: []const u8 = "";
    var out_tok: f64 = 0;
    var t_end: ?i64 = null;
    var prev_ts: ?i64 = null;
    var prompt_ts: ?i64 = null;
    var reply_after_prompt = false;
    var latest_ts: ?i64 = null;
    var turn_tools: usize = 0;
    var last_tool: ?[]const u8 = null;

    var e = data.len;
    while (e > lo) {
        if (data[e - 1] == '\n') {
            e -= 1;
            continue;
        }
        const nl = std.mem.lastIndexOfScalar(u8, data[lo..e], '\n');
        const s = if (nl) |k| lo + k + 1 else lo;
        const line = data[s..e];
        e = s;
        if (s == lo and lo > 0) break; // partial first line of the window

        const maybe_asst = std.mem.indexOf(u8, line, "\"type\":\"assistant\"") != null;
        const maybe_user = std.mem.indexOf(u8, line, "\"type\":\"user\"") != null;
        if (!maybe_asst and !maybe_user) continue;
        const rec = std.json.parseFromSliceLeaky(Value, a, line, .{}) catch continue;
        const typ = gstr(get(rec, &.{"type"})) orelse continue;
        const ts = parseTs(gstr(get(rec, &.{"timestamp"})) orelse "");
        if (latest_ts == null) latest_ts = ts;

        if (eq(typ, "assistant")) {
            const id = gstr(get(rec, &.{ "message", "id" })) orelse "";
            if (!seen_any) {
                seen_any = true;
                top_ended = eq(gstr(get(rec, &.{ "message", "stop_reason" })) orelse "", "end_turn");
            }
            if (prompt_ts == null) {
                const n = std.mem.count(u8, line, "\"type\":\"tool_use\"");
                turn_tools += n;
                if (n > 0 and last_tool == null) last_tool = toolName(rec);
            }
            if (phase == 0) {
                mid = id;
                out_tok = gnum(get(rec, &.{ "message", "usage", "output_tokens" })) orelse 0;
                t_end = ts;
                phase = 1;
                if (prompt_ts == null) reply_after_prompt = true;
            } else if (phase == 1 and !eq(id, mid)) {
                prev_ts = ts;
                phase = 2;
            }
        } else if (eq(typ, "user")) {
            seen_any = true;
            if (phase == 1) {
                prev_ts = ts;
                phase = 2;
            }
            if (prompt_ts == null and isPrompt(rec)) prompt_ts = ts orelse now_ms;
        }
        if (prompt_ts != null and phase == 2) break;
    }

    if (prompt_ts) |t0| {
        const ended = reply_after_prompt and top_ended;
        const t1 = if (ended) (t_end orelse now_ms) else now_ms;
        f.putNum("tx.turn_s", @floatFromInt(@max(0, @divFloor(t1 - t0, 1000))));
        f.putNum("tx.turn_tool_calls", @floatFromInt(turn_tools));
    }
    if (prev_ts != null and t_end != null and out_tok > 0 and t_end.? > prev_ts.?) {
        const secs = @as(f64, @floatFromInt(t_end.? - prev_ts.?)) / 1000;
        f.putNum("tx.speed", @round(out_tok / secs));
    }
    if (last_tool) |t| f.putStr("tx.last_tool", t);
    if (latest_ts) |t| f.putNum("tx.idle_s", @floatFromInt(@max(0, @divFloor(now_ms - t, 1000))));
}

fn toolName(rec: Value) ?[]const u8 {
    const content = get(rec, &.{ "message", "content" }) orelse return null;
    if (content != .array) return null;
    var i = content.array.items.len;
    while (i > 0) {
        i -= 1;
        const x = content.array.items[i];
        if (eq(gstr(get(x, &.{"type"})) orelse "", "tool_use")) return gstr(get(x, &.{"name"}));
    }
    return null;
}

// ---------------------------------------------------------------------------
// processes and cache

/// Run `argv` and return stdout, or null on failure, non-zero exit or timeout.
pub fn run(a: Allocator, argv: []const []const u8, cwd: ?[]const u8, timeout_ms: u32) ?[]u8 {
    var child = std.process.Child.init(argv, a);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;

    var out: std.ArrayList(u8) = .empty;
    const fd = child.stdout.?.handle;
    const deadline = std.time.milliTimestamp() + timeout_ms;
    var buf: [16384]u8 = undefined;
    while (true) {
        const left = deadline - std.time.milliTimestamp();
        if (left <= 0) {
            _ = child.kill() catch {};
            return null;
        }
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, @intCast(left)) catch 0;
        if (ready == 0) {
            _ = child.kill() catch {};
            return null;
        }
        const n = std.posix.read(fd, &buf) catch 0;
        if (n == 0) break;
        out.appendSlice(a, buf[0..n]) catch return null;
        if (out.items.len > 64 << 20) {
            _ = child.kill() catch {};
            return null;
        }
    }
    const term = child.wait() catch return null;
    switch (term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }
    return out.items;
}

pub fn tmpDir(a: Allocator) []const u8 {
    const base = std.posix.getenv("TMPDIR") orelse "/tmp";
    const dir = std.fs.path.join(a, &.{ base, "omnitt-statusline" }) catch return base;
    std.fs.makeDirAbsolute(dir) catch |err| if (err != error.PathAlreadyExists) return base;
    return dir;
}

/// A tiny facts cache in $TMPDIR, one file per key, valid for `ttl_s` seconds.
const Cache = struct {
    path: []const u8,

    fn open(a: Allocator, kind: []const u8, key: []const u8) Cache {
        const h = std.hash.Wyhash.hash(0, key);
        const name = std.fmt.allocPrint(a, "{s}-{x}", .{ kind, h }) catch "";
        return .{ .path = std.fs.path.join(a, &.{ tmpDir(a), name }) catch "" };
    }

    /// Load cached facts into `f`; false when missing or older than `ttl_s`.
    fn load(c: Cache, a: Allocator, f: *Facts, ttl_s: u32) bool {
        if (ttl_s == 0) return false;
        const file = std.fs.openFileAbsolute(c.path, .{}) catch return false;
        defer file.close();
        const st = file.stat() catch return false;
        const age_ns = std.time.nanoTimestamp() - st.mtime;
        if (age_ns < 0 or age_ns > @as(i128, ttl_s) * std.time.ns_per_s) return false;
        const data = file.readToEndAlloc(a, 1 << 20) catch return false;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            var parts = std.mem.splitScalar(u8, line, '\t');
            const t = parts.next() orelse continue;
            const k = parts.next() orelse continue;
            const v = parts.rest();
            if (eq(t, "n")) {
                f.putNum(k, std.fmt.parseFloat(f64, v) catch continue);
            } else if (eq(t, "s")) {
                f.putStr(k, v);
            } else if (eq(t, "b")) {
                f.put(k, .{ .flag = eq(v, "1") });
            }
        }
        return true;
    }

    fn store(c: Cache, a: Allocator, f: *const Facts, keys: []const []const u8) void {
        var out: std.ArrayList(u8) = .empty;
        for (keys) |k| {
            const v = f.get(k) orelse continue;
            switch (v) {
                .num => |n| out.print(a, "n\t{s}\t{d}\n", .{ k, n }) catch return,
                .str => |s| out.print(a, "s\t{s}\t{s}\n", .{ k, std.mem.trim(u8, s, "\n\t") }) catch return,
                .flag => |b| out.print(a, "b\t{s}\t{d}\n", .{ k, @intFromBool(b) }) catch return,
            }
        }
        const tmp = std.fmt.allocPrint(a, "{s}.{d}", .{ c.path, std.time.milliTimestamp() }) catch return;
        const file = std.fs.createFileAbsolute(tmp, .{}) catch return;
        file.writeAll(out.items) catch {};
        file.close();
        std.fs.renameAbsolute(tmp, c.path) catch {};
    }
};

// ---------------------------------------------------------------------------
// git

const git_keys = [_][]const u8{
    "git.branch",   "git.sha",   "git.dirty",    "git.staged",   "git.unstaged", "git.untracked",
    "git.ahead",    "git.behind", "git.diff_add", "git.diff_del", "git.stash",    "git.last_commit",
    "git.tag",
};

fn git(a: Allocator, f: *Facts, dir: []const u8, n: Needs) void {
    const key = std.fmt.allocPrint(a, "{s}\x00{any}", .{ dir, n }) catch return;
    const cache = Cache.open(a, "git", key);
    if (cache.load(a, f, GIT_TTL_S)) return;

    const base = [_][]const u8{ "git", "--no-optional-locks" };
    if (n.git_status) {
        const uflag = if (n.git_untracked) "--untracked-files=normal" else "--untracked-files=no";
        const out = run(a, &(base ++ [_][]const u8{ "status", "--porcelain=v2", "--branch", uflag }), dir, GIT_TIMEOUT_MS) orelse return;
        var staged: usize = 0;
        var unstaged: usize = 0;
        var untracked: usize = 0;
        var sha: ?[]const u8 = null;
        var head: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "# branch.oid ")) {
                const v = line[13..];
                if (!eq(v, "(initial)")) sha = v;
            } else if (std.mem.startsWith(u8, line, "# branch.head ")) {
                head = line[14..];
            } else if (std.mem.startsWith(u8, line, "# branch.ab ")) {
                var ab = std.mem.splitScalar(u8, line[12..], ' ');
                const ahead = ab.next() orelse "+0";
                const behind = ab.next() orelse "-0";
                f.putNum("git.ahead", std.fmt.parseFloat(f64, ahead[1..]) catch 0);
                f.putNum("git.behind", std.fmt.parseFloat(f64, behind[1..]) catch 0);
            } else if (line.len > 3 and (line[0] == '1' or line[0] == '2') and line[1] == ' ') {
                if (line[2] != '.') staged += 1;
                if (line[3] != '.') unstaged += 1;
            } else if (std.mem.startsWith(u8, line, "u ")) {
                unstaged += 1;
            } else if (std.mem.startsWith(u8, line, "? ")) {
                untracked += 1;
            }
        }
        if (sha) |s| f.putStr("git.sha", s);
        if (head) |h| {
            f.putStr("git.branch", if (eq(h, "(detached)")) (if (sha) |s| s[0..@min(7, s.len)] else "?") else h);
        }
        f.putNum("git.staged", @floatFromInt(staged));
        f.putNum("git.unstaged", @floatFromInt(unstaged));
        f.putNum("git.untracked", @floatFromInt(untracked));
        f.put("git.dirty", .{ .flag = staged + unstaged + untracked > 0 });
    }
    if (n.git_diff) {
        var add: f64 = 0;
        var del: f64 = 0;
        if (run(a, &(base ++ [_][]const u8{ "diff", "HEAD", "--numstat" }), dir, GIT_TIMEOUT_MS)) |out| {
            var it = std.mem.splitScalar(u8, out, '\n');
            while (it.next()) |ln| {
                var cols = std.mem.splitScalar(u8, ln, '\t');
                const x = cols.next() orelse continue;
                const y = cols.next() orelse continue;
                add += std.fmt.parseFloat(f64, x) catch continue; // "-" for binary files
                del += std.fmt.parseFloat(f64, y) catch 0;
            }
            f.putNum("git.diff_add", add);
            f.putNum("git.diff_del", del);
        }
    }
    if (n.git_stash) {
        const out = run(a, &(base ++ [_][]const u8{ "rev-list", "--walk-reflogs", "--count", "refs/stash" }), dir, GIT_TIMEOUT_MS);
        f.putNum("git.stash", if (out) |o| std.fmt.parseFloat(f64, std.mem.trim(u8, o, " \n")) catch 0 else 0);
    }
    if (n.git_last_commit) {
        if (run(a, &(base ++ [_][]const u8{ "log", "-1", "--format=%ct" }), dir, GIT_TIMEOUT_MS)) |o| {
            if (std.fmt.parseFloat(f64, std.mem.trim(u8, o, " \n"))) |t| f.putNum("git.last_commit", t) else |_| {}
        }
    }
    if (n.git_tag) {
        if (run(a, &(base ++ [_][]const u8{ "describe", "--tags", "--abbrev=0" }), dir, GIT_TIMEOUT_MS)) |o| {
            f.putStr("git.tag", std.mem.trim(u8, o, " \n"));
        }
    }
    cache.store(a, f, &git_keys);
}

// ---------------------------------------------------------------------------
// system

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *const c_long, tm: *Tm) ?*Tm;
extern "c" fn tzset() void;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn getloadavg(loadavg: [*]f64, nelem: c_int) c_int;

fn utcOffset(now: c_long) ?f64 {
    var tm: Tm = undefined;
    _ = localtime_r(&now, &tm) orelse return null;
    return @floatFromInt(tm.gmtoff);
}

fn system(a: Allocator, f: *Facts, cfg: cfgm.Config, n: Needs) void {
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    if (std.posix.gethostname(&host_buf)) |h| {
        const short = if (std.mem.endsWith(u8, h, ".local")) h[0 .. h.len - 6] else h;
        f.putStr("sys.hostname", a.dupe(u8, short) catch "");
    } else |_| {}
    if (std.posix.getenv("USER")) |u| f.putStr("sys.user", u);

    const now: c_long = @intCast(std.time.timestamp());
    var tz_needed = false;
    for (cfg.lines) |line| for (line) |s| {
        if (s.def.kind == .clock or s.def.kind == .countdown) tz_needed = true;
    };
    if (tz_needed) {
        if (utcOffset(now)) |off| f.putNum("tz:", off);
        for (cfg.lines) |line| for (line) |s| {
            if (s.tz.len == 0) continue;
            const key = std.fmt.allocPrint(a, "tz:{s}", .{s.tz}) catch continue;
            if (f.has(key)) continue;
            const z = a.dupeZ(u8, s.tz) catch continue;
            _ = setenv("TZ", z, 1);
            tzset();
            if (utcOffset(now)) |off| f.putNum(key, off);
        };
    }

    if (n.load) {
        var l: [3]f64 = undefined;
        if (getloadavg(&l, 3) >= 1) f.putNum("sys.load1", l[0]);
    }
    if (n.mem) if (memAvailable(a)) |pct| f.putNum("sys.mem_avail", pct);
    if (n.battery) battery(a, f);
}

fn memAvailable(a: Allocator) ?f64 {
    if (builtin.os.tag == .macos) {
        var level: i32 = 0;
        var len: usize = @sizeOf(i32);
        if (std.c.sysctlbyname("kern.memorystatus_level", &level, &len, null, 0) != 0) return null;
        return @floatFromInt(level);
    }
    const data = std.fs.cwd().readFileAlloc(a, "/proc/meminfo", 64 << 10) catch return null;
    var total: ?f64 = null;
    var avail: ?f64 = null;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        var cols = std.mem.tokenizeAny(u8, line, ": ");
        const k = cols.next() orelse continue;
        const v = std.fmt.parseFloat(f64, cols.next() orelse continue) catch continue;
        if (eq(k, "MemTotal")) total = v;
        if (eq(k, "MemAvailable")) avail = v;
    }
    if (total == null or avail == null or total.? == 0) return null;
    return avail.? / total.? * 100;
}

fn battery(a: Allocator, f: *Facts) void {
    if (builtin.os.tag == .linux) {
        for ([_][]const u8{ "BAT0", "BAT1", "battery" }) |name| {
            const p = std.fmt.allocPrint(a, "/sys/class/power_supply/{s}/capacity", .{name}) catch continue;
            const data = std.fs.cwd().readFileAlloc(a, p, 64) catch continue;
            f.putNum("sys.battery", std.fmt.parseFloat(f64, std.mem.trim(u8, data, " \n")) catch continue);
            return;
        }
        return;
    }
    const cache = Cache.open(a, "battery", "pmset");
    if (cache.load(a, f, 60)) return;
    const out = run(a, &.{ "pmset", "-g", "batt" }, null, 300) orelse return;
    const pct_end = std.mem.indexOfScalar(u8, out, '%') orelse return;
    var start = pct_end;
    while (start > 0 and std.ascii.isDigit(out[start - 1])) start -= 1;
    f.putNum("sys.battery", std.fmt.parseFloat(f64, out[start..pct_end]) catch return);
    cache.store(a, f, &.{"sys.battery"});
}

// ---------------------------------------------------------------------------
// custom

fn custom(a: Allocator, f: *Facts, cfg: cfgm.Config) void {
    for (cfg.lines) |line| for (line) |s| {
        if (s.env.len > 0 and eq(s.def.id, "env")) {
            const key = std.fmt.allocPrint(a, "env:{s}", .{s.env}) catch continue;
            if (std.posix.getenv(s.env)) |v| f.putStr(key, v);
        }
        if (s.cmd.len > 0 and eq(s.def.id, "command")) {
            const key = std.fmt.allocPrint(a, "cmd:{s}", .{s.cmd}) catch continue;
            if (f.has(key)) continue;
            const cache = Cache.open(a, "cmd", s.cmd);
            if (cache.load(a, f, s.ttl_s) and f.has(key)) continue;
            const out = run(a, &.{ "/bin/sh", "-c", s.cmd }, f.str("workspace.current_dir"), s.timeout_ms) orelse continue;
            const first = std.mem.sliceTo(std.mem.trim(u8, out, " \r\n\t"), '\n');
            f.putStr(key, first);
            cache.store(a, f, &.{key});
        }
    };
}

test "porcelain timestamp" {
    try std.testing.expectEqual(@as(i64, 1792468800000), parseTs("2026-10-20T04:00:00.000Z").?);
}
