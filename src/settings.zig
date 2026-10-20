//! Minimal-diff edits to Claude Code's settings.json: only the top-level
//! `statusLine` member is touched; every other byte is preserved.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Member = struct {
    key: []const u8,
    key_start: usize,
    value_start: usize,
    value_end: usize,
};

pub const Doc = struct {
    open: usize,
    close: usize,
    members: []Member,
    indent: []const u8,

    pub fn find(d: Doc, key: []const u8) ?usize {
        for (d.members, 0..) |m, i| {
            if (std.mem.eql(u8, m.key, key)) return i;
        }
        return null;
    }
};

pub const Error = error{ NotAnObject, Malformed, OutOfMemory };

/// Scan the top-level object. The text must already be valid JSON.
pub fn scan(a: Allocator, text: []const u8) Error!Doc {
    var i = skipWs(text, 0);
    if (i >= text.len or text[i] != '{') return error.NotAnObject;
    const open = i;
    i += 1;
    var members: std.ArrayList(Member) = .empty;
    while (true) {
        i = skipWs(text, i);
        if (i >= text.len) return error.Malformed;
        if (text[i] == '}') break;
        if (text[i] == ',') {
            i += 1;
            continue;
        }
        if (text[i] != '"') return error.Malformed;
        const key_start = i;
        const key_end = try skipString(text, i);
        i = skipWs(text, key_end);
        if (i >= text.len or text[i] != ':') return error.Malformed;
        i = skipWs(text, i + 1);
        const value_start = i;
        i = try skipValue(text, i);
        try members.append(a, .{
            .key = text[key_start + 1 .. key_end - 1],
            .key_start = key_start,
            .value_start = value_start,
            .value_end = i,
        });
    }
    var indent: []const u8 = "  ";
    if (members.items.len > 0) {
        const ks = members.items[0].key_start;
        var s = ks;
        while (s > open + 1 and (text[s - 1] == ' ' or text[s - 1] == '\t')) s -= 1;
        if (s < ks) indent = text[s..ks];
    }
    return .{ .open = open, .close = i, .members = try members.toOwnedSlice(a), .indent = indent };
}

fn skipWs(t: []const u8, start: usize) usize {
    var i = start;
    while (i < t.len and (t[i] == ' ' or t[i] == '\t' or t[i] == '\n' or t[i] == '\r')) i += 1;
    return i;
}

fn skipString(t: []const u8, start: usize) Error!usize {
    var i = start + 1;
    while (i < t.len) : (i += 1) {
        if (t[i] == '\\') {
            i += 1;
        } else if (t[i] == '"') {
            return i + 1;
        }
    }
    return error.Malformed;
}

fn skipValue(t: []const u8, start: usize) Error!usize {
    if (start >= t.len) return error.Malformed;
    switch (t[start]) {
        '"' => return skipString(t, start),
        '{', '[' => {
            var depth: usize = 0;
            var i = start;
            while (i < t.len) {
                switch (t[i]) {
                    '"' => {
                        i = try skipString(t, i);
                        continue;
                    },
                    '{', '[' => depth += 1,
                    '}', ']' => {
                        depth -= 1;
                        if (depth == 0) return i + 1;
                    },
                    else => {},
                }
                i += 1;
            }
            return error.Malformed;
        },
        else => {
            var i = start;
            while (i < t.len and t[i] != ',' and t[i] != '}' and t[i] != ']' and t[i] != ' ' and t[i] != '\n' and t[i] != '\r' and t[i] != '\t') i += 1;
            return i;
        },
    }
}

/// Set top-level `key` to the JSON text `value`, inserting it if absent.
pub fn set(a: Allocator, text: []const u8, key: []const u8, value: []const u8) Error![]u8 {
    const d = try scan(a, text);
    if (d.find(key)) |i| {
        const m = d.members[i];
        return std.mem.concat(a, u8, &.{ text[0..m.value_start], value, text[m.value_end..] });
    }
    const entry = try std.fmt.allocPrint(a, "{s}\"{s}\": {s}", .{ d.indent, key, value });
    if (d.members.len == 0) {
        return std.mem.concat(a, u8, &.{ text[0 .. d.open + 1], "\n", entry, "\n", text[d.close..] });
    }
    const last = d.members[d.members.len - 1];
    return std.mem.concat(a, u8, &.{ text[0..last.value_end], ",\n", entry, text[last.value_end..] });
}

/// Remove top-level `key` together with its separating comma.
pub fn remove(a: Allocator, text: []const u8, key: []const u8) Error![]u8 {
    const d = try scan(a, text);
    const i = d.find(key) orelse return a.dupe(u8, text);
    const m = d.members[i];
    if (i + 1 < d.members.len) {
        return std.mem.concat(a, u8, &.{ text[0..m.key_start], text[d.members[i + 1].key_start..] });
    }
    if (i > 0) {
        return std.mem.concat(a, u8, &.{ text[0..d.members[i - 1].value_end], text[m.value_end..] });
    }
    const after = skipWs(text, m.value_end);
    return std.mem.concat(a, u8, &.{ text[0 .. d.open + 1], "\n", text[after..] });
}

/// The JSON text of a top-level member, or null when absent.
pub fn getRaw(a: Allocator, text: []const u8, key: []const u8) Error!?[]const u8 {
    const d = try scan(a, text);
    const i = d.find(key) orelse return null;
    return text[d.members[i].value_start..d.members[i].value_end];
}

/// `statusLine` object text, indented to sit one level inside the document.
pub fn statusLineValue(a: Allocator, indent: []const u8, command: []const u8, padding: u32, refresh: ?u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{{\n{s}{s}\"type\": \"command\",\n{s}{s}\"command\": {f},\n{s}{s}\"padding\": {d}", .{
        indent, indent, indent, indent, std.json.fmt(command, .{}), indent, indent, padding,
    });
    if (refresh) |r| try out.print(a, ",\n{s}{s}\"refreshInterval\": {d}", .{ indent, indent, r });
    try out.print(a, "\n{s}}}", .{indent});
    return out.toOwnedSlice(a);
}

const testing = std.testing;

test "replace keeps everything else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "{\n    \"model\": \"x\",\n    \"statusLine\": {\"type\": \"command\", \"command\": \"old\"},\n    \"hooks\": {\"a\": [1, \"}\"]}\n}\n";
    const out = try set(a, src, "statusLine", "{}");
    try testing.expectEqualStrings("{\n    \"model\": \"x\",\n    \"statusLine\": {},\n    \"hooks\": {\"a\": [1, \"}\"]}\n}\n", out);
}

test "insert after last member with detected indent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try set(a, "{\n\t\"a\": 1\n}\n", "statusLine", "true");
    try testing.expectEqualStrings("{\n\t\"a\": 1,\n\t\"statusLine\": true\n}\n", out);
    const empty = try set(a, "{}", "statusLine", "true");
    try testing.expectEqualStrings("{\n  \"statusLine\": true\n}", empty);
}

test "remove first, middle, last, only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}";
    try testing.expectEqualStrings("{\n  \"b\": 2,\n  \"c\": 3\n}", try remove(a, src, "a"));
    try testing.expectEqualStrings("{\n  \"a\": 1,\n  \"c\": 3\n}", try remove(a, src, "b"));
    try testing.expectEqualStrings("{\n  \"a\": 1,\n  \"b\": 2\n}", try remove(a, src, "c"));
    try testing.expectEqualStrings("{\n}", try remove(a, "{\n  \"a\": 1\n}", "a"));
}

test "statusLine value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try statusLineValue(arena.allocator(), "  ", "/Users/x/.claude/bin/omnitt-statusline", 0, 1);
    try testing.expectEqualStrings("{\n    \"type\": \"command\",\n    \"command\": \"/Users/x/.claude/bin/omnitt-statusline\",\n    \"padding\": 0,\n    \"refreshInterval\": 1\n  }", v);
}
