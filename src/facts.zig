//! Facts: the flat key -> value table the renderer reads. Collectors (native only)
//! fill it; the web preview passes it in as JSON. Keys are dotted paths of the
//! Claude Code stdin JSON plus collector prefixes (`tx.`, `git.`, `sys.`, ...).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Fact = union(enum) {
    num: f64,
    str: []const u8,
    flag: bool,
};

pub const Facts = struct {
    a: Allocator,
    map: std.StringHashMapUnmanaged(Fact) = .empty,

    pub fn init(a: Allocator) Facts {
        return .{ .a = a };
    }

    pub fn put(self: *Facts, key: []const u8, v: Fact) void {
        self.map.put(self.a, key, v) catch {};
    }

    pub fn putNum(self: *Facts, key: []const u8, n: f64) void {
        self.put(key, .{ .num = n });
    }

    pub fn putStr(self: *Facts, key: []const u8, s: []const u8) void {
        if (s.len > 0) self.put(key, .{ .str = s });
    }

    pub fn get(self: *const Facts, key: []const u8) ?Fact {
        return self.map.get(key);
    }

    pub fn has(self: *const Facts, key: []const u8) bool {
        return self.map.contains(key);
    }

    pub fn num(self: *const Facts, key: []const u8) ?f64 {
        return switch (self.get(key) orelse return null) {
            .num => |n| n,
            .str => |s| std.fmt.parseFloat(f64, s) catch null,
            .flag => null,
        };
    }

    pub fn str(self: *const Facts, key: []const u8) ?[]const u8 {
        return switch (self.get(key) orelse return null) {
            .str => |s| s,
            else => null,
        };
    }

    pub fn flag(self: *const Facts, key: []const u8) ?bool {
        return switch (self.get(key) orelse return null) {
            .flag => |b| b,
            .num => |n| n != 0,
            .str => null,
        };
    }

    /// Flatten a JSON value into dotted keys. Arrays store their length; null and
    /// empty strings are treated as missing.
    pub fn addJson(self: *Facts, prefix: []const u8, v: Value) void {
        switch (v) {
            .object => |o| {
                var it = o.iterator();
                while (it.next()) |e| {
                    const key = if (prefix.len == 0)
                        e.key_ptr.*
                    else
                        std.fmt.allocPrint(self.a, "{s}.{s}", .{ prefix, e.key_ptr.* }) catch continue;
                    self.addJson(key, e.value_ptr.*);
                }
            },
            .array => |arr| self.putNum(prefix, @floatFromInt(arr.items.len)),
            .integer => |i| self.putNum(prefix, @floatFromInt(i)),
            .float => |f| self.putNum(prefix, f),
            .number_string => |s| if (std.fmt.parseFloat(f64, s)) |f| self.putNum(prefix, f) else |_| {},
            .string => |s| self.putStr(prefix, s),
            .bool => |b| self.put(prefix, .{ .flag = b }),
            .null => {},
        }
    }

    /// Values computed from other facts. Pure, so native and web agree.
    pub fn derive(self: *Facts) void {
        if (self.num("cost.total_api_duration_ms")) |api| {
            if (self.num("cost.total_duration_ms")) |total| {
                if (total > 0) self.putNum("derived.api_ratio", api / total * 100);
            }
        }
        if (self.str("workspace.repo.owner")) |owner| {
            if (self.str("workspace.repo.name")) |name| {
                self.putStr("derived.repo", std.fmt.allocPrint(self.a, "{s}/{s}", .{ owner, name }) catch "");
            }
        }
        if (self.str("worktree.name") orelse self.str("workspace.git_worktree")) |wt| {
            self.putStr("derived.worktree", wt);
        }
    }
};

test "flatten and derive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(Value, a,
        \\{"model":{"display_name":"Opus"},"cost":{"total_duration_ms":2000,"total_api_duration_ms":500},
        \\ "workspace":{"added_dirs":["a","b"],"repo":{"owner":"o","name":"n"}},"x":null,"y":""}
    , .{});
    var f = Facts.init(a);
    f.addJson("", v);
    f.derive();
    try std.testing.expectEqualStrings("Opus", f.str("model.display_name").?);
    try std.testing.expectEqual(@as(f64, 2), f.num("workspace.added_dirs").?);
    try std.testing.expectEqual(@as(f64, 25), f.num("derived.api_ratio").?);
    try std.testing.expectEqualStrings("o/n", f.str("derived.repo").?);
    try std.testing.expect(!f.has("x"));
    try std.testing.expect(!f.has("y"));
}
