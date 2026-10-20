//! Codex CLI support. Codex has no command-based status line: `[tui] status_line`
//! takes an ordered list of built-in item ids and `status_line_use_colors` turns
//! theme colours on or off. So for Codex we only pick and order built-in items,
//! and edit those two keys in `config.toml`, leaving every other byte alone.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Codex release the item list was taken from (codex-rs/tui/src/bottom_pane/status_line_setup.rs).
pub const version = "0.163.0";

pub const Item = struct { id: []const u8, name: []const u8, name_zh: []const u8 };

pub const items = [_]Item{
    .{ .id = "model", .name = "Model", .name_zh = "模型" },
    .{ .id = "model-with-reasoning", .name = "Model with reasoning level", .name_zh = "模型与推理强度" },
    .{ .id = "reasoning", .name = "Reasoning level", .name_zh = "推理强度" },
    .{ .id = "current-dir", .name = "Current directory", .name_zh = "当前目录" },
    .{ .id = "project-name", .name = "Project name", .name_zh = "项目名" },
    .{ .id = "hostname", .name = "Hostname", .name_zh = "主机名" },
    .{ .id = "git-branch", .name = "Git branch", .name_zh = "Git 分支" },
    .{ .id = "pull-request-number", .name = "Pull request number", .name_zh = "PR 编号" },
    .{ .id = "branch-changes", .name = "Branch changes vs default branch", .name_zh = "相对默认分支的改动" },
    .{ .id = "run-state", .name = "Run state", .name_zh = "运行状态" },
    .{ .id = "permissions", .name = "Permissions", .name_zh = "权限配置" },
    .{ .id = "approval-mode", .name = "Approval mode", .name_zh = "审批模式" },
    .{ .id = "context-remaining", .name = "Context remaining %", .name_zh = "上下文剩余 %" },
    .{ .id = "context-used", .name = "Context used %", .name_zh = "上下文已用 %" },
    .{ .id = "five-hour-limit", .name = "Primary usage limit remaining", .name_zh = "主限额剩余" },
    .{ .id = "weekly-limit", .name = "Secondary usage limit remaining", .name_zh = "周限额剩余" },
    .{ .id = "codex-version", .name = "Codex version", .name_zh = "Codex 版本" },
    .{ .id = "context-window-size", .name = "Context window size", .name_zh = "上下文窗口大小" },
    .{ .id = "used-tokens", .name = "Tokens used in session", .name_zh = "会话 token 总量" },
    .{ .id = "total-input-tokens", .name = "Input tokens", .name_zh = "输入 token" },
    .{ .id = "total-output-tokens", .name = "Output tokens", .name_zh = "输出 token" },
    .{ .id = "thread-credits", .name = "Thread credits (Enterprise)", .name_zh = "线程额度（企业版）" },
    .{ .id = "estimated-thread-cost", .name = "Thread cost (Enterprise)", .name_zh = "线程费用（企业版）" },
    .{ .id = "thread-id", .name = "Thread id", .name_zh = "线程 ID" },
    .{ .id = "fast-mode", .name = "Fast mode", .name_zh = "Fast 模式" },
    .{ .id = "daybreak", .name = "Daybreak", .name_zh = "Daybreak" },
    .{ .id = "raw-output", .name = "Raw scrollback mode", .name_zh = "原始滚动模式" },
    .{ .id = "thread-name", .name = "Thread name", .name_zh = "线程名" },
    .{ .id = "thread-title", .name = "Thread title", .name_zh = "线程标题" },
    .{ .id = "workspace-headline", .name = "Workspace headline (Enterprise)", .name_zh = "工作区通知（企业版）" },
    .{ .id = "task-progress", .name = "Task progress", .name_zh = "任务进度" },
};

/// Our segment id -> the Codex item showing the same information. Segments not
/// listed have no Codex counterpart. Codex shows usage limits as remaining, we
/// default to used; the item is still the same limit.
pub const equivalents = [_][2][]const u8{
    .{ "model", "model" },
    .{ "effort", "reasoning" },
    .{ "fast-mode", "fast-mode" },
    .{ "ctx-bar", "context-used" },
    .{ "ctx-used-pct", "context-used" },
    .{ "ctx-remaining-pct", "context-remaining" },
    .{ "ctx-window-size", "context-window-size" },
    .{ "tokens-in", "total-input-tokens" },
    .{ "tokens-out", "total-output-tokens" },
    .{ "limit-5h-pct", "five-hour-limit" },
    .{ "limit-5h-bar", "five-hour-limit" },
    .{ "limit-7d-pct", "weekly-limit" },
    .{ "limit-7d-bar", "weekly-limit" },
    .{ "session-name", "thread-name" },
    .{ "session-id", "thread-id" },
    .{ "version", "codex-version" },
    .{ "dir", "current-dir" },
    .{ "project-dir", "project-name" },
    .{ "pr", "pull-request-number" },
    .{ "git-branch", "git-branch" },
    .{ "hostname", "hostname" },
};

pub fn known(id: []const u8) bool {
    for (items) |it| if (std.mem.eql(u8, it.id, id)) return true;
    return false;
}

pub fn writeJson(s: *std.json.Stringify) !void {
    try s.beginObject();
    try s.objectField("version");
    try s.write(version);
    try s.objectField("items");
    try s.write(items);
    try s.objectField("map");
    try s.beginObject();
    for (equivalents) |e| {
        try s.objectField(e[0]);
        try s.write(e[1]);
    }
    try s.endObject();
    try s.endObject();
}

// ---------------------------------------------------------------------------
// config.toml editing

const table = "tui";
const key_items = "status_line";
const key_colors = "status_line_use_colors";

/// The two keys as they were before the first install, for uninstall.
pub const Prev = struct {
    had_table: bool,
    /// Full original line(s) of each key including the newline, or null when absent.
    items: ?[]const u8,
    colors: ?[]const u8,
    /// Whether the file ended with a newline; edits always terminate the lines they write.
    final_newline: bool,
    /// Whether config.toml existed at all; set by the caller, which owns the file.
    had_file: bool = true,
};

pub fn capture(a: Allocator, text: []const u8) !Prev {
    const doc = try scan(a, text);
    const t = doc.findTable(table);
    return .{
        .had_table = t != null,
        .items = if (doc.findKey(table, key_items)) |e| text[e.start..e.end] else null,
        .colors = if (doc.findKey(table, key_colors)) |e| text[e.start..e.end] else null,
        .final_newline = text.len == 0 or text[text.len - 1] == '\n',
    };
}

/// Set the item list and colour switch. Ids must be plain kebab-case (checked by the caller via `known`).
pub fn apply(a: Allocator, text: []const u8, ids: []const []const u8, colors: bool) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    try line.appendSlice(a, key_items ++ " = [");
    for (ids, 0..) |id, i| {
        if (i > 0) try line.appendSlice(a, ", ");
        try line.print(a, "\"{s}\"", .{id});
    }
    try line.appendSlice(a, "]\n");
    const c = if (colors) key_colors ++ " = true\n" else key_colors ++ " = false\n";
    return setKeys(a, text, line.items, c, false);
}

/// Put both keys back as captured; drop the `[tui]` table again if we created it and it is empty.
pub fn restore(a: Allocator, text: []const u8, prev: Prev) ![]u8 {
    const out = try setKeys(a, text, prev.items, prev.colors, !prev.had_table);
    if (!prev.final_newline and out.len > 0 and out[out.len - 1] == '\n') return out[0 .. out.len - 1];
    return out;
}

const Edit = struct { start: usize, end: usize, with: []const u8 };

fn setKeys(a: Allocator, text: []const u8, items_line: ?[]const u8, colors_line: ?[]const u8, drop_empty_table: bool) ![]u8 {
    const doc = try scan(a, text);
    // `tui = {...}` or `tui.status_line = ...` at the top level: rewriting those safely
    // needs a real TOML writer, so leave the file alone and let the user edit it.
    for (doc.entries) |e| if (e.kind == .key and e.table.len == 0 and
        (std.mem.eql(u8, e.name, table) or std.mem.startsWith(u8, e.name, table ++ "."))) return error.UnsupportedLayout;

    var edits: std.ArrayList(Edit) = .empty;
    var out: std.ArrayList(u8) = .empty;
    if (doc.findTable(table)) |hdr| {
        const old_items = doc.findKey(table, key_items);
        const old_colors = doc.findKey(table, key_colors);
        if (old_items) |e| try edits.append(a, .{ .start = e.start, .end = e.end, .with = try terminated(a, items_line orelse "") });
        if (old_colors) |e| try edits.append(a, .{ .start = e.start, .end = e.end, .with = try terminated(a, colors_line orelse "") });
        // Missing keys go right under the header, or for the colour switch right after the item list.
        if (old_items == null) if (items_line) |l| try edits.append(a, try insertAt(a, text, hdr.end, l));
        if (old_colors == null) if (colors_line) |l| {
            // After the item list there is no missing newline to add: its replacement is always terminated.
            if (old_items) |e| {
                try edits.append(a, .{ .start = e.end, .end = e.end, .with = try terminated(a, l) });
            } else try edits.append(a, try insertAt(a, text, hdr.end, l));
        };
        std.mem.sort(Edit, edits.items, {}, struct {
            // At the same position an insertion goes first, then the replacement starting there.
            fn lt(_: void, x: Edit, y: Edit) bool {
                return x.start < y.start or (x.start == y.start and x.end < y.end);
            }
        }.lt);
        var pos: usize = 0;
        for (edits.items) |e| {
            try out.appendSlice(a, text[pos..e.start]);
            try out.appendSlice(a, e.with);
            pos = e.end;
        }
        try out.appendSlice(a, text[pos..]);
    } else {
        try out.appendSlice(a, text);
        if (items_line != null or colors_line != null) {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
            if (out.items.len > 0) try out.append(a, '\n');
            try out.appendSlice(a, "[" ++ table ++ "]\n");
            if (items_line) |l| try out.appendSlice(a, try terminated(a, l));
            if (colors_line) |l| try out.appendSlice(a, try terminated(a, l));
        }
    }
    if (drop_empty_table) return dropEmptyTable(a, out.items);
    return out.items;
}

fn insertAt(a: Allocator, text: []const u8, at: usize, line: []const u8) !Edit {
    // The anchor line may be the last one in the file, without a newline.
    const lead = if (at > 0 and text[at - 1] != '\n') "\n" else "";
    return .{ .start = at, .end = at, .with = try std.mem.concat(a, u8, &.{ lead, try terminated(a, line) }) };
}

fn terminated(a: Allocator, line: []const u8) ![]const u8 {
    if (line.len == 0 or line[line.len - 1] == '\n') return line;
    return std.mem.concat(a, u8, &.{ line, "\n" });
}

/// Remove a `[tui]` header that has no keys and no comments under it, plus one blank line before it.
fn dropEmptyTable(a: Allocator, text: []u8) ![]u8 {
    const doc = try scan(a, text);
    const hdr = doc.findTable(table) orelse return text;
    var next: usize = text.len;
    for (doc.entries) |e| {
        if (e.start <= hdr.start) continue;
        if (e.kind == .key and std.mem.eql(u8, e.table, table)) return text;
        if (e.kind == .header) {
            next = e.start;
            break;
        }
    }
    for (text[hdr.end..next]) |ch| if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r') return text;
    var start = hdr.start;
    if (start >= 2 and text[start - 1] == '\n' and text[start - 2] == '\n') start -= 1;
    return std.mem.concat(a, u8, &.{ text[0..start], text[next..] });
}

// ---------------------------------------------------------------------------
// minimal TOML scanner: finds table headers and top-level keys of each table with
// their byte spans; understands strings, comments and multi-line arrays / inline tables

const Entry = struct {
    kind: enum { header, key },
    /// header: table name; key: the table it belongs to ("" for the root table)
    table: []const u8,
    /// key name (unquoted); empty for headers
    name: []const u8,
    /// span of the whole line(s), including the trailing newline when present
    start: usize,
    end: usize,
};

const Doc = struct {
    entries: []Entry,

    fn findTable(d: Doc, name: []const u8) ?Entry {
        for (d.entries) |e| if (e.kind == .header and std.mem.eql(u8, e.table, name)) return e;
        return null;
    }

    fn findKey(d: Doc, tbl: []const u8, name: []const u8) ?Entry {
        for (d.entries) |e| if (e.kind == .key and std.mem.eql(u8, e.table, tbl) and std.mem.eql(u8, e.name, name)) return e;
        return null;
    }
};

fn scan(a: Allocator, text: []const u8) !Doc {
    var entries: std.ArrayList(Entry) = .empty;
    var current: []const u8 = "";
    var i: usize = 0;
    while (i < text.len) {
        const line_start = i;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i >= text.len) break;
        switch (text[i]) {
            '\n' => i += 1,
            '\r', '#' => i = lineEnd(text, i),
            '[' => {
                const array_table = i + 1 < text.len and text[i + 1] == '[';
                const open: usize = if (array_table) 2 else 1;
                const close = std.mem.indexOfScalarPos(u8, text, i, ']') orelse return error.InvalidToml;
                const name = unquote(std.mem.trim(u8, text[i + open .. close], " \t"));
                current = if (array_table) "[[array]]" else name;
                i = lineEnd(text, close);
                try entries.append(a, .{ .kind = .header, .table = current, .name = "", .start = line_start, .end = i });
            },
            else => {
                const eq = try keyEnd(text, i);
                const name = unquote(std.mem.trim(u8, text[i..eq], " \t"));
                i = try valueEnd(text, eq + 1);
                try entries.append(a, .{ .kind = .key, .table = current, .name = name, .start = line_start, .end = i });
            },
        }
    }
    return .{ .entries = entries.items };
}

/// Index just past the newline ending this line (or end of text); skips a trailing comment.
fn lineEnd(text: []const u8, from: usize) usize {
    const nl = std.mem.indexOfScalarPos(u8, text, from, '\n') orelse return text.len;
    return nl + 1;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) return s[1 .. s.len - 1];
    return s;
}

/// Position of the `=` after a (possibly quoted or dotted) key.
fn keyEnd(text: []const u8, from: usize) !usize {
    var i = from;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '=' => return i,
            '"', '\'' => i = try stringEnd(text, i) - 1,
            '\n' => return error.InvalidToml,
            else => {},
        }
    }
    return error.InvalidToml;
}

/// End of a value: the newline after it once all brackets are closed.
fn valueEnd(text: []const u8, from: usize) !usize {
    var depth: usize = 0;
    var i = from;
    while (i < text.len) {
        switch (text[i]) {
            '"', '\'' => i = try stringEnd(text, i),
            '[', '{' => {
                depth += 1;
                i += 1;
            },
            ']', '}' => {
                if (depth == 0) return error.InvalidToml;
                depth -= 1;
                i += 1;
            },
            '#' => i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len,
            '\n' => {
                i += 1;
                if (depth == 0) return i;
            },
            else => i += 1,
        }
    }
    if (depth != 0) return error.InvalidToml;
    return text.len;
}

/// Index just past the closing quote of the string starting at `from`.
fn stringEnd(text: []const u8, from: usize) !usize {
    const q = text[from];
    const triple = from + 2 < text.len and text[from + 1] == q and text[from + 2] == q;
    if (triple) {
        const delim = text[from .. from + 3];
        var i = from + 3;
        while (i + 3 <= text.len) : (i += 1) {
            if (q == '"' and text[i] == '\\') {
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, text[i .. i + 3], delim)) {
                // A closing delimiter may be followed by up to two more quotes that belong to the content.
                var end = i + 3;
                while (end < text.len and end < i + 5 and text[end] == q) end += 1;
                return end;
            }
        }
        return error.InvalidToml;
    }
    var i = from + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') return error.InvalidToml;
        if (q == '"' and text[i] == '\\') {
            i += 1;
            continue;
        }
        if (text[i] == q) return i + 1;
    }
    return error.InvalidToml;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn roundTrip(before: []const u8, ids: []const []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prev = try capture(a, before);
    const after = try apply(a, before, ids, true);
    try testing.expectEqualStrings(expected, after);
    // Applying twice changes nothing more; restoring gives back the original bytes.
    try testing.expectEqualStrings(after, try apply(a, after, ids, true));
    try testing.expectEqualStrings(before, try restore(a, after, prev));
}

test "replaces existing keys in place, keeps everything else" {
    try roundTrip(
        \\model = "gpt-5"
        \\
        \\[tui]
        \\# my status line
        \\status_line = ["model", "git-branch"]  # trailing
        \\theme = "dark"
        \\status_line_use_colors = false
        \\
        \\[profiles.work]
        \\model = "o3"
        \\
    , &.{ "model-with-reasoning", "context-used" },
        \\model = "gpt-5"
        \\
        \\[tui]
        \\# my status line
        \\status_line = ["model-with-reasoning", "context-used"]
        \\theme = "dark"
        \\status_line_use_colors = true
        \\
        \\[profiles.work]
        \\model = "o3"
        \\
    );
}

test "multi-line array value and brackets inside other values" {
    try roundTrip(
        \\[tui]
        \\notifications = [
        \\  ["a", "b]"],
        \\]
        \\status_line = [
        \\  "model", # first
        \\  "git-branch",
        \\]
        \\[other]
        \\x = 1
    , &.{"model"},
        \\[tui]
        \\notifications = [
        \\  ["a", "b]"],
        \\]
        \\status_line = ["model"]
        \\status_line_use_colors = true
        \\[other]
        \\x = 1
    );
}

test "adds keys under an existing table" {
    try roundTrip(
        \\[tui]
        \\theme = "dark"
        \\
    , &.{"model"},
        \\[tui]
        \\status_line = ["model"]
        \\status_line_use_colors = true
        \\theme = "dark"
        \\
    );
}

test "creates the table and removes it again on restore" {
    try roundTrip(
        \\model = "gpt-5"
        \\[mcp_servers.x]
        \\command = "y"
    , &.{ "model", "weekly-limit" },
        \\model = "gpt-5"
        \\[mcp_servers.x]
        \\command = "y"
        \\
        \\[tui]
        \\status_line = ["model", "weekly-limit"]
        \\status_line_use_colors = true
        \\
    );
    try roundTrip("", &.{"model"},
        \\[tui]
        \\status_line = ["model"]
        \\status_line_use_colors = true
        \\
    );
}

test "multi-line strings do not confuse the scanner" {
    try roundTrip(
        \\instructions = """
        \\[tui]
        \\status_line = "not a key"
        \\"""
        \\[tui]
        \\status_line = ['model']
    , &.{"reasoning"},
        \\instructions = """
        \\[tui]
        \\status_line = "not a key"
        \\"""
        \\[tui]
        \\status_line = ["reasoning"]
        \\status_line_use_colors = true
        \\
    );
}

test "refuses layouts it cannot edit safely" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.UnsupportedLayout, apply(a, "tui = { status_line = [] }\n", &.{"model"}, true));
    try testing.expectError(error.UnsupportedLayout, apply(a, "tui.status_line = []\n", &.{"model"}, true));
    try testing.expectError(error.InvalidToml, apply(a, "[tui]\nstatus_line = [\"model\"\n", &.{"model"}, true));
}

test "catalog and map are consistent" {
    for (equivalents) |e| try testing.expect(known(e[1]));
}
