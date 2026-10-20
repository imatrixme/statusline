//! omnitt-statusline: a configurable status line for Claude Code, plus Codex's built-in one.
//!
//!   omnitt-statusline                 render (Claude Code runs this; JSON on stdin)
//!   omnitt-statusline setup [code]    install a config: point Claude Code's settings.json at this binary,
//!                                     and set Codex's built-in status line items when the config has them
//!   omnitt-statusline decode <code>   print the config inside a config code
//!   omnitt-statusline edit            print an editor link for the current config
//!   omnitt-statusline doctor          render the last input and report timings and gaps
//!   omnitt-statusline uninstall       restore settings.json / Codex config.toml and remove this tool
//!   omnitt-statusline registry        print the segment catalogue as JSON
//!
//! The renderer never touches the network and never updates itself.

const std = @import("std");
const cfgm = @import("config.zig");
const registry = @import("registry.zig");
const render = @import("render.zig");
const collect = @import("collect.zig");
const settings = @import("settings.zig");
const codex = @import("codex.zig");
const Facts = @import("facts.zig").Facts;
const Allocator = std.mem.Allocator;

pub const version = "1.1.0";
const editor_url = "https://omnitt.com/statusline";

var A: Allocator = undefined;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    A = arena.allocator();

    const args = try std.process.argsAlloc(A);
    if (args.len < 2) return renderMain();
    const cmd = args[1];
    const arg = if (args.len > 2) args[2] else null;

    if (eq(cmd, "setup")) return exit(setup(arg));
    if (eq(cmd, "decode")) return exit(decode(arg orelse return usage()));
    if (eq(cmd, "edit")) return exit(edit());
    if (eq(cmd, "doctor")) return exit(doctor());
    if (eq(cmd, "uninstall")) return exit(uninstall());
    if (eq(cmd, "registry")) return exit(printRegistry());
    if (eq(cmd, "version") or eq(cmd, "--version")) return print("omnitt-statusline {s}\n", .{version});
    return usage();
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn print(comptime f: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(A, f, args) catch return;
    std.fs.File.stdout().writeAll(s) catch {};
}

fn fail(comptime f: []const u8, args: anytype) u8 {
    const s = std.fmt.allocPrint(A, "error: " ++ f ++ "\n", args) catch return 1;
    std.fs.File.stderr().writeAll(s) catch {};
    return 1;
}

fn exit(code: u8) void {
    if (code != 0) std.process.exit(code);
}

fn usage() void {
    std.fs.File.stderr().writeAll(
        \\usage: omnitt-statusline [setup [code] | decode <code> | edit | doctor | uninstall | registry | version]
        \\Without arguments, renders the status line from Claude Code's JSON on stdin.
        \\Editor: https://omnitt.com/statusline
        \\
    ) catch {};
    std.process.exit(2);
}

// ---------------------------------------------------------------------------
// paths

fn home() []const u8 {
    return std.posix.getenv("HOME") orelse "/";
}

fn configDir() []const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |x| if (x.len > 0) {
        return std.fs.path.join(A, &.{ x, "omnitt-statusline" }) catch unreachable;
    };
    return std.fs.path.join(A, &.{ home(), ".config", "omnitt-statusline" }) catch unreachable;
}

fn configPath() []const u8 {
    return std.fs.path.join(A, &.{ configDir(), "config.json" }) catch unreachable;
}

fn previousPath() []const u8 {
    return std.fs.path.join(A, &.{ configDir(), "previous-statusline.json" }) catch unreachable;
}

fn claudeSettingsPath() []const u8 {
    if (std.posix.getenv("CLAUDE_CONFIG_DIR")) |d| if (d.len > 0) {
        return std.fs.path.join(A, &.{ d, "settings.json" }) catch unreachable;
    };
    return std.fs.path.join(A, &.{ home(), ".claude", "settings.json" }) catch unreachable;
}

fn previousCodexPath() []const u8 {
    return std.fs.path.join(A, &.{ configDir(), "previous-codex.json" }) catch unreachable;
}

fn codexDir() []const u8 {
    if (std.posix.getenv("CODEX_HOME")) |d| if (d.len > 0) return d;
    return std.fs.path.join(A, &.{ home(), ".codex" }) catch unreachable;
}

fn codexConfigPath() []const u8 {
    return std.fs.path.join(A, &.{ codexDir(), "config.toml" }) catch unreachable;
}

fn lastInputPath() []const u8 {
    return std.fs.path.join(A, &.{ collect.tmpDir(A), "last-input.json" }) catch unreachable;
}

fn readFile(path: []const u8, limit: usize) ?[]u8 {
    return std.fs.cwd().readFileAlloc(A, path, limit) catch null;
}

fn writeAtomic(path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrint(A, "{s}.tmp-{d}", .{ path, std.time.milliTimestamp() });
    {
        const f = try std.fs.createFileAbsolute(tmp, .{});
        defer f.close();
        try f.writeAll(data);
    }
    try std.fs.renameAbsolute(tmp, path);
}

fn loadConfig() cfgm.Config {
    if (readFile(configPath(), 1 << 20)) |json| {
        if (cfgm.parse(A, json)) |c| return c else |_| {}
    }
    return cfgm.parse(A, cfgm.default_json) catch unreachable;
}

fn columns() usize {
    const c = std.posix.getenv("COLUMNS") orelse return 0;
    return std.fmt.parseInt(usize, c, 10) catch 0;
}

// ---------------------------------------------------------------------------
// render

fn renderMain() void {
    const raw = std.fs.File.stdin().readToEndAlloc(A, 16 << 20) catch "";
    // Keep the last input for `doctor`; the only write outside the cache.
    if (std.fs.createFileAbsolute(lastInputPath(), .{})) |f| {
        f.writeAll(raw) catch {};
        f.close();
    } else |_| {}
    const out = renderInput(raw) catch return;
    std.fs.File.stdout().writeAll(out) catch {};
}

fn renderInput(raw: []const u8) ![]u8 {
    const cfg = loadConfig();
    const input = std.json.parseFromSliceLeaky(std.json.Value, A, raw, .{}) catch std.json.Value{ .null = {} };
    var facts = Facts.init(A);
    collect.collect(A, cfg, input, &facts);
    return render.render(A, cfg, &facts, columns());
}

// ---------------------------------------------------------------------------
// setup / decode / edit

fn decode(code: []const u8) u8 {
    const json = cfgm.decode(A, code) catch return fail("not a valid config code", .{});
    const v = std.json.parseFromSliceLeaky(std.json.Value, A, json, .{}) catch return fail("config code does not contain JSON", .{});
    const pretty = std.json.Stringify.valueAlloc(A, v, .{ .whitespace = .indent_2 }) catch return 1;
    print("{s}\n", .{pretty});
    return 0;
}

fn edit() u8 {
    const json = readFile(configPath(), 1 << 20) orelse cfgm.default_json;
    const v = std.json.parseFromSliceLeaky(std.json.Value, A, json, .{}) catch return fail("{s} is not valid JSON", .{configPath()});
    const compact = std.json.Stringify.valueAlloc(A, v, .{}) catch return 1;
    const code = cfgm.encode(A, compact) catch return 1;
    print("{s}#c={s}\n", .{ editor_url, code });
    return 0;
}

/// Ask on the terminal (not stdin, which is the piped install script).
fn confirm(question: []const u8) bool {
    const tty = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write }) catch return false;
    defer tty.close();
    tty.writeAll(question) catch return false;
    var buf: [16]u8 = undefined;
    const n = tty.read(&buf) catch return false;
    const ans = std.mem.trim(u8, buf[0..n], " \r\n");
    return eq(ans, "y") or eq(ans, "Y") or eq(ans, "yes");
}

// Without a code, installs the default layout. A config may target Claude Code (`lines`),
// Codex (`codex`) or both; only the tools it names are touched.
fn setup(code: ?[]const u8) u8 {
    const json = if (code) |c| cfgm.decode(A, c) catch return fail("not a valid config code", .{}) else cfgm.default_json;
    var root = std.json.parseFromSliceLeaky(std.json.Value, A, json, .{}) catch return fail("config code does not contain JSON", .{});
    if (root != .object) return fail("config is not a JSON object", .{});
    const for_claude = root.object.get("lines") != null;
    if (!for_claude and root.object.get("codex") == null) return fail("config has neither \"lines\" nor \"codex\"", .{});
    // A Codex-only code must not wipe an installed Claude Code layout: carry it over.
    if (!for_claude) if (readFile(configPath(), 1 << 20)) |old| {
        if (std.json.parseFromSliceLeaky(std.json.Value, A, old, .{})) |ov| {
            if (ov == .object) {
                var it = ov.object.iterator();
                while (it.next()) |kv| if (!eq(kv.key_ptr.*, "codex")) root.object.put(kv.key_ptr.*, kv.value_ptr.*) catch {};
            }
        } else |_| {}
    };

    print("omnitt-statusline {s}\n\nConfig:\n", .{version});
    if (for_claude) {
        const cfg0 = cfgm.fromValue(A, root) catch return fail("config \"lines\" is invalid", .{});
        for (cfg0.lines, 1..) |line, i| {
            print("  line {d}:", .{i});
            for (line) |s| print(" {s}", .{s.def.id});
            print("\n", .{});
        }
        for (cfg0.unknown) |id| print("  (unknown to this version, ignored: {s})\n", .{id});

        // Command segments run a shell command on every refresh; a shared link must
        // not be able to install one without the user seeing and accepting it.
        var commands: std.ArrayList([]const u8) = .empty;
        for (cfg0.lines) |line| for (line) |s| {
            if (eq(s.def.id, "command") and s.cmd.len > 0) commands.append(A, s.cmd) catch {};
        };
        if (commands.items.len > 0) {
            print("\nThis config runs these shell commands on every status line refresh:\n", .{});
            for (commands.items) |c| print("  $ {s}\n", .{c});
            if (!confirm("Allow them? [y/N] ")) {
                stripCommands(&root);
                print("Command segments removed; the rest of the config will be installed.\n", .{});
            }
        }
    }
    const codex_sel = if (root.object.get("codex")) |v| codexSelection(v) else null;
    if (codex_sel) |sel| {
        print("  codex:", .{});
        for (sel.ids) |id| print(" {s}", .{id});
        print("{s}\n", .{if (sel.colors) "" else " (no colours)"});
    }

    const final = std.json.Stringify.valueAlloc(A, root, .{ .whitespace = .indent_2 }) catch return 1;
    std.fs.cwd().makePath(configDir()) catch |e| return fail("cannot create {s}: {s}", .{ configDir(), @errorName(e) });
    writeAtomic(configPath(), final) catch |e| return fail("cannot write {s}: {s}", .{ configPath(), @errorName(e) });

    const exe = std.fs.selfExePathAlloc(A) catch return fail("cannot resolve own path", .{});
    var changes: std.ArrayList(u8) = .empty;
    if (for_claude) {
        const cfg = cfgm.parse(A, final) catch return fail("config became invalid", .{});
        if (setupClaude(cfg, exe, &changes) != 0) return 1;
    }
    if (codex_sel) |sel| setupCodex(sel, &changes);

    print("\nChanged:\n  {s}: config written\n{s}\nRestart Claude Code / Codex to see it.\nUndo everything: {s} uninstall\n", .{ configPath(), changes.items, exe });
    return 0;
}

fn setupClaude(cfg: cfgm.Config, exe: []const u8, changes: *std.ArrayList(u8)) u8 {
    const sp = claudeSettingsPath();
    if (readFile(sp, 4 << 20)) |text| {
        _ = std.json.parseFromSliceLeaky(std.json.Value, A, text, .{}) catch
            return fail("{s} is not valid JSON; left unchanged. Fix it and run setup again.", .{sp});
        const doc = settings.scan(A, text) catch return fail("{s} is not a JSON object; left unchanged", .{sp});
        // Remember what statusLine was before the first install, for uninstall.
        std.fs.accessAbsolute(previousPath(), .{}) catch {
            const prev = (settings.getRaw(A, text, "statusLine") catch null) orelse "null";
            writeAtomic(previousPath(), prev) catch {};
        };
        const backup = std.fmt.allocPrint(A, "{s}.omnitt-backup-{d}", .{ sp, std.time.timestamp() }) catch return 1;
        writeAtomic(backup, text) catch |e| return fail("cannot back up {s}: {s}", .{ sp, @errorName(e) });
        const value = settings.statusLineValue(A, doc.indent, exe, cfg.padding, cfg.refresh) catch return 1;
        const updated = settings.set(A, text, "statusLine", value) catch return fail("cannot edit {s}", .{sp});
        writeAtomic(sp, updated) catch |e| return fail("cannot write {s}: {s}", .{ sp, @errorName(e) });
        changes.print(A, "  {s}: statusLine updated (backup: {s})\n", .{ sp, backup }) catch {};
    } else {
        std.fs.cwd().makePath(std.fs.path.dirname(sp) orelse ".") catch {};
        writeAtomic(previousPath(), "null") catch {};
        const value = settings.statusLineValue(A, "  ", exe, cfg.padding, cfg.refresh) catch return 1;
        const text = std.fmt.allocPrint(A, "{{\n  \"statusLine\": {s}\n}}\n", .{value}) catch return 1;
        writeAtomic(sp, text) catch |e| return fail("cannot write {s}: {s}", .{ sp, @errorName(e) });
        changes.print(A, "  {s}: created with statusLine\n", .{sp}) catch {};
    }
    return 0;
}

const CodexSelection = struct { ids: []const []const u8, colors: bool };

/// `"codex": {"items": [...], "colors": true}`. Ids Codex {codex.version} does not know are dropped:
/// Codex would warn about them on every start.
fn codexSelection(v: std.json.Value) ?CodexSelection {
    if (v != .object) return null;
    var ids: std.ArrayList([]const u8) = .empty;
    if (v.object.get("items")) |arr| if (arr == .array) for (arr.array.items) |it| {
        if (it != .string) continue;
        if (!codex.known(it.string)) {
            print("  (not a Codex {s} status line item, skipped: {s})\n", .{ codex.version, it.string });
            continue;
        }
        for (ids.items) |seen| {
            if (eq(seen, it.string)) break;
        } else ids.append(A, it.string) catch {};
    };
    if (ids.items.len == 0) return null;
    const colors = if (v.object.get("colors")) |c| (c != .bool or c.bool) else true;
    return .{ .ids = ids.items, .colors = colors };
}

/// Codex problems never abort setup: the Claude Code part is independent.
fn setupCodex(sel: CodexSelection, changes: *std.ArrayList(u8)) void {
    std.fs.accessAbsolute(codexDir(), .{}) catch {
        changes.print(A, "  Codex: {s} not found, skipped\n", .{codexDir()}) catch {};
        return;
    };
    const path = codexConfigPath();
    const old = readFile(path, 4 << 20);
    const text = old orelse "";
    const updated = codex.apply(A, text, sel.ids, sel.colors) catch |e| {
        const why = switch (e) {
            error.UnsupportedLayout => "its [tui] settings are written as an inline table or dotted keys",
            error.InvalidToml => "it could not be parsed",
            else => @errorName(e),
        };
        changes.print(A, "  {s}: left unchanged because {s}. Set it under [tui] yourself:\n    status_line = [", .{ path, why }) catch {};
        for (sel.ids, 0..) |id, i| changes.print(A, "{s}\"{s}\"", .{ if (i > 0) ", " else "", id }) catch {};
        changes.print(A, "]\n    status_line_use_colors = {}\n", .{sel.colors}) catch {};
        return;
    };
    // Remember the two keys as they were before the first install, for uninstall.
    std.fs.accessAbsolute(previousCodexPath(), .{}) catch {
        if (codex.capture(A, text)) |captured| {
            var prev = captured;
            prev.had_file = old != null;
            if (std.json.Stringify.valueAlloc(A, prev, .{})) |j| writeAtomic(previousCodexPath(), j) catch {} else |_| {}
        } else |_| {}
    };
    var backup: []const u8 = "";
    if (old != null) {
        backup = std.fmt.allocPrint(A, "{s}.omnitt-backup-{d}", .{ path, std.time.timestamp() }) catch return;
        writeAtomic(backup, text) catch |e| {
            changes.print(A, "  {s}: left unchanged, cannot back it up: {s}\n", .{ path, @errorName(e) }) catch {};
            return;
        };
    }
    writeAtomic(path, updated) catch |e| {
        changes.print(A, "  {s}: cannot write: {s}\n", .{ path, @errorName(e) }) catch {};
        return;
    };
    if (old != null)
        changes.print(A, "  {s}: [tui] status_line updated (backup: {s})\n", .{ path, backup }) catch {}
    else
        changes.print(A, "  {s}: created with [tui] status_line\n", .{path}) catch {};
}

fn stripCommands(root: *std.json.Value) void {
    const lines = root.object.getPtr("lines") orelse return;
    if (lines.* != .array) return;
    for (lines.array.items) |*line| {
        if (line.* != .array) continue;
        var i: usize = 0;
        while (i < line.array.items.len) {
            const s = line.array.items[i];
            const id = if (s == .object) s.object.get("id") else null;
            if (id != null and id.? == .string and eq(id.?.string, "command")) {
                _ = line.array.orderedRemove(i);
            } else i += 1;
        }
    }
}

// ---------------------------------------------------------------------------
// uninstall

fn uninstall() u8 {
    const sp = claudeSettingsPath();
    // Only touch settings.json if setup changed it (a Codex-only install never did).
    const claude_prev = readFile(previousPath(), 1 << 20);
    if (claude_prev != null) if (readFile(sp, 4 << 20)) |text| {
        const p = std.mem.trim(u8, claude_prev.?, " \n");
        const updated = if (eq(p, "null"))
            settings.remove(A, text, "statusLine") catch return fail("cannot edit {s}", .{sp})
        else
            settings.set(A, text, "statusLine", p) catch return fail("cannot edit {s}", .{sp});
        const backup = std.fmt.allocPrint(A, "{s}.omnitt-backup-{d}", .{ sp, std.time.timestamp() }) catch return 1;
        writeAtomic(backup, text) catch {};
        writeAtomic(sp, updated) catch |e| return fail("cannot write {s}: {s}", .{ sp, @errorName(e) });
        print("{s}: statusLine restored (backup: {s})\n", .{ sp, backup });
    };
    uninstallCodex();
    std.fs.deleteTreeAbsolute(configDir()) catch {};
    print("{s}: removed\n", .{configDir()});
    std.fs.deleteTreeAbsolute(collect.tmpDir(A)) catch {};
    if (std.fs.selfExePathAlloc(A)) |exe| {
        std.fs.deleteFileAbsolute(exe) catch {};
        print("{s}: removed\n", .{exe});
    } else |_| {}
    return 0;
}

fn uninstallCodex() void {
    const pj = readFile(previousCodexPath(), 1 << 20) orelse return;
    const prev = std.json.parseFromSliceLeaky(codex.Prev, A, pj, .{}) catch return;
    const path = codexConfigPath();
    const text = readFile(path, 4 << 20) orelse return;
    const restored = codex.restore(A, text, prev) catch |e| {
        print("{s}: not restored ({s}); remove status_line under [tui] yourself if needed\n", .{ path, @errorName(e) });
        return;
    };
    // setup created the file and nothing else was added since: remove it again.
    if (!prev.had_file and std.mem.trim(u8, restored, " \t\r\n").len == 0) {
        std.fs.deleteFileAbsolute(path) catch {};
        print("{s}: removed (created by setup)\n", .{path});
        return;
    }
    const backup = std.fmt.allocPrint(A, "{s}.omnitt-backup-{d}", .{ path, std.time.timestamp() }) catch return;
    writeAtomic(backup, text) catch {};
    writeAtomic(path, restored) catch |e| {
        print("{s}: cannot write: {s}\n", .{ path, @errorName(e) });
        return;
    };
    print("{s}: [tui] status line restored (backup: {s})\n", .{ path, backup });
}

// ---------------------------------------------------------------------------
// doctor / registry

fn doctor() u8 {
    const cfg = loadConfig();
    print("omnitt-statusline {s}\nconfig: {s}\n", .{ version, configPath() });
    for (cfg.unknown) |id| print("  unknown segment (newer config?): {s}\n", .{id});
    const raw = readFile(lastInputPath(), 16 << 20) orelse {
        print("No input recorded yet. Start Claude Code with this status line first.\n", .{});
        return 0;
    };
    const input = std.json.parseFromSliceLeaky(std.json.Value, A, raw, .{}) catch return fail("last input is not JSON", .{});
    print("claude code: {s}\n\n", .{if (input == .object) (if (input.object.get("version")) |v| (if (v == .string) v.string else "?") else "?") else "?"});

    var facts = Facts.init(A);
    var timer = std.time.Timer.start() catch return 1;
    collect.collect(A, cfg, input, &facts);
    const t_collect = timer.lap();
    const out = render.render(A, cfg, &facts, columns()) catch return 1;
    const t_render = timer.lap();
    print("{s}\n", .{out});
    print("collect {d:.1}ms, render {d:.1}ms\n\n", .{ ms(t_collect), ms(t_render) });

    for (cfg.lines) |line| for (line) |s| {
        const d = s.def;
        const key = if (d.fact.len > 0) d.fact else if (d.kind == .fraction) d.used else "";
        if (key.len == 0 or facts.has(key)) continue;
        const note = switch (d.source) {
            .session => if (d.since.len > 0) std.fmt.allocPrint(A, "not in Claude Code's input (needs {s}+ or not applicable now)", .{d.since}) catch "" else "not in Claude Code's input right now",
            .transcript => "transcript has no matching record (internal format may have changed)",
            .git => "not a git repository, git missing, or git timed out",
            else => "not available on this system",
        };
        print("  hidden: {s} ({s}): {s}\n", .{ d.id, key, note });
    };
    return 0;
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn printRegistry() u8 {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    registry.writeJson(&w.interface) catch return 1;
    w.interface.writeAll("\n") catch return 1;
    w.interface.flush() catch return 1;
    return 0;
}

test {
    _ = @import("config.zig");
    _ = @import("facts.zig");
    _ = @import("registry.zig");
    _ = @import("render.zig");
    _ = @import("settings.zig");
    _ = @import("collect.zig");
    _ = @import("codex.zig");
}
