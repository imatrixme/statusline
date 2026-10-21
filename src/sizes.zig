//! Directory sizes (disk usage, like `du`): the working directory, build outputs and
//! toolchain caches. A walk can take seconds, so the status line only reads cached
//! results; a stale or missing result starts a detached `omnitt-statusline __size`
//! worker that measures in the background and writes the cache for later refreshes.

const std = @import("std");
const builtin = @import("builtin");
const cfgm = @import("config.zig");
const collect = @import("collect.zig");
const project = @import("project.zig");
const Facts = @import("facts.zig").Facts;
const Allocator = std.mem.Allocator;

const TTL_S = 300;
// A worker that has not finished by then is assumed dead and may be replaced.
const LOCK_STALE_S = 900;
const MAX_UP = 8;

const Target = struct { id: []const u8, key: []const u8 };

const targets = [_]Target{
    .{ .id = "dir-size", .key = "size.dir" },
    .{ .id = "node-modules", .key = "size.node_modules" },
    .{ .id = "rust-target", .key = "size.rust_target" },
    .{ .id = "go-cache", .key = "size.go_cache" },
    .{ .id = "pods", .key = "size.pods" },
    .{ .id = "xcode-derived", .key = "size.xcode_derived" },
    .{ .id = "gradle-cache", .key = "size.gradle_cache" },
    .{ .id = "maven-repo", .key = "size.maven_repo" },
};

fn isDir(p: []const u8) bool {
    var d = std.fs.openDirAbsolute(p, .{}) catch return false;
    d.close();
    return true;
}

/// Directory `name` in `dir` or a parent, next to the file `beside` (so `target/` counts
/// only beside Cargo.toml, not Maven's), stopping at the repository root or $HOME.
fn findUp(a: Allocator, dir: []const u8, name: []const u8, beside: []const u8) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse "";
    var cur = dir;
    var depth: usize = 0;
    while (depth < MAX_UP) : (depth += 1) {
        const p = std.fs.path.join(a, &.{ cur, name }) catch return null;
        const marker = std.fs.path.join(a, &.{ cur, beside }) catch return null;
        if (isDir(p)) if (std.fs.accessAbsolute(marker, .{})) |_| return p else |_| {};
        const git = std.fs.path.join(a, &.{ cur, ".git" }) catch return null;
        std.fs.accessAbsolute(git, .{}) catch {
            if (std.mem.eql(u8, cur, home)) return null;
            cur = std.fs.path.dirname(cur) orelse return null;
            continue;
        };
        return null;
    }
    return null;
}

fn homeJoin(a: Allocator, parts: []const []const u8) []const u8 {
    var all: std.ArrayList([]const u8) = .empty;
    all.append(a, std.posix.getenv("HOME") orelse "/") catch return "";
    all.appendSlice(a, parts) catch return "";
    return std.fs.path.join(a, all.items) catch "";
}

/// Directories measured for a target; empty when they do not exist here.
fn paths(a: Allocator, id: []const u8, dir: []const u8) []const []const u8 {
    const env = std.posix.getenv;
    var out: std.ArrayList([]const u8) = .empty;
    const add = struct {
        fn f(al: Allocator, list: *std.ArrayList([]const u8), p: ?[]const u8) void {
            if (p) |v| if (v.len > 0 and isDir(v)) list.append(al, v) catch {};
        }
    }.f;
    const eq = std.mem.eql;
    if (eq(u8, id, "dir-size")) {
        add(a, &out, dir);
    } else if (eq(u8, id, "node-modules")) {
        add(a, &out, findUp(a, dir, "node_modules", "package.json"));
    } else if (eq(u8, id, "rust-target")) {
        add(a, &out, env("CARGO_TARGET_DIR") orelse findUp(a, dir, "target", "Cargo.toml"));
    } else if (eq(u8, id, "pods")) {
        add(a, &out, findUp(a, dir, "Pods", "Podfile"));
    } else if (eq(u8, id, "go-cache")) {
        // go env GOCACHE / GOMODCACHE defaults, without starting `go`
        const cache = env("GOCACHE") orelse if (builtin.os.tag == .macos)
            homeJoin(a, &.{ "Library", "Caches", "go-build" })
        else if (env("XDG_CACHE_HOME")) |x| std.fs.path.join(a, &.{ x, "go-build" }) catch "" else homeJoin(a, &.{ ".cache", "go-build" });
        add(a, &out, cache);
        const gopath = if (env("GOPATH")) |g| std.mem.sliceTo(g, ':') else homeJoin(a, &.{"go"});
        add(a, &out, env("GOMODCACHE") orelse std.fs.path.join(a, &.{ gopath, "pkg", "mod" }) catch null);
    } else if (eq(u8, id, "xcode-derived")) {
        if (builtin.os.tag == .macos) add(a, &out, homeJoin(a, &.{ "Library", "Developer", "Xcode", "DerivedData" }));
    } else if (eq(u8, id, "gradle-cache")) {
        const base = env("GRADLE_USER_HOME") orelse homeJoin(a, &.{".gradle"});
        add(a, &out, std.fs.path.join(a, &.{ base, "caches" }) catch null);
    } else if (eq(u8, id, "maven-repo")) {
        add(a, &out, homeJoin(a, &.{ ".m2", "repository" }));
    }
    return out.items;
}

/// Cached sizes for the configured targets; starts a worker for stale ones.
pub fn sizes(a: Allocator, f: *Facts, cfg: cfgm.Config, dir: []const u8) void {
    for (targets) |t| {
        if (!project.needed(cfg, t.id)) continue;
        const ps = paths(a, t.id, dir);
        if (ps.len == 0) continue;
        var key: std.ArrayList(u8) = .empty;
        key.appendSlice(a, t.key) catch continue;
        for (ps) |p| {
            key.append(a, 0) catch continue;
            key.appendSlice(a, p) catch continue;
        }
        const cache = collect.Cache.open(a, "size", key.items);
        const age = cache.loadAny(a, f) orelse std.math.maxInt(i64);
        if (age > TTL_S) spawn(a, cache.path, t.key, ps);
    }
}

fn spawn(a: Allocator, cache_path: []const u8, key: []const u8, ps: []const []const u8) void {
    const lock = std.fmt.allocPrint(a, "{s}.lock", .{cache_path}) catch return;
    if (std.fs.openFileAbsolute(lock, .{})) |file| {
        defer file.close();
        const st = file.stat() catch return;
        if (std.time.nanoTimestamp() - st.mtime < LOCK_STALE_S * std.time.ns_per_s) return;
    } else |_| {}
    const lf = std.fs.createFileAbsolute(lock, .{}) catch return;
    lf.close();

    const exe = std.fs.selfExePathAlloc(a) catch return;
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ exe, "__size", cache_path, key }) catch return;
    argv.appendSlice(a, ps) catch return;
    var child = std.process.Child.init(argv.items, a);
    // No pipes: Claude Code waits for our stdout to close, so the worker must not inherit it.
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        std.fs.deleteFileAbsolute(lock) catch {};
    };
}

extern "c" fn setpriority(which: c_int, who: c_uint, prio: c_int) c_int;

/// `omnitt-statusline __size <cache> <key> <dir>...`: measure and write the cache.
pub fn worker(a: Allocator, args: []const []const u8) u8 {
    if (args.len < 3) return 2;
    _ = std.posix.setsid() catch {};
    _ = setpriority(0, 0, 10); // PRIO_PROCESS, this process, lower priority
    const cache_path = args[0];
    const key = args[1];
    defer {
        const lock = std.fmt.allocPrint(a, "{s}.lock", .{cache_path}) catch "";
        std.fs.deleteFileAbsolute(lock) catch {};
    }
    var seen = std.AutoHashMap([2]u64, void).init(a);
    var total: u64 = 0;
    for (args[2..]) |p| {
        var d = std.fs.openDirAbsolute(p, .{ .iterate = true, .no_follow = true }) catch continue;
        defer d.close();
        total += walk(a, d, &seen, 0);
    }
    var f = Facts.init(a);
    f.putNum(key, @floatFromInt(total));
    (collect.Cache{ .path = cache_path }).store(a, &f, &.{key});
    return 0;
}

/// Allocated bytes under `dir` (st_blocks, symlinks not followed, hard links counted once).
fn walk(a: Allocator, dir: std.fs.Dir, seen: *std.AutoHashMap([2]u64, void), depth: usize) u64 {
    if (depth > 128) return 0;
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next() catch null) |e| {
        const st = std.posix.fstatat(dir.fd, e.name, std.posix.AT.SYMLINK_NOFOLLOW) catch continue;
        const is_dir = e.kind == .directory;
        if (!is_dir and st.nlink > 1) {
            const id = [2]u64{ @intCast(st.dev), @intCast(st.ino) };
            const gop = seen.getOrPut(id) catch continue;
            if (gop.found_existing) continue;
        }
        total += @as(u64, @intCast(st.blocks)) * 512;
        if (is_dir) {
            var sub = dir.openDir(e.name, .{ .iterate = true, .no_follow = true }) catch continue;
            defer sub.close();
            total += walk(a, sub, seen, depth + 1);
        }
    }
    return total;
}
