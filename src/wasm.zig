//! WebAssembly entry for the web editor's preview. Same renderer as the native
//! binary; facts come from the page as JSON instead of from collectors.
//!
//!   const p = alloc(n)            -> write UTF-8 into memory at p
//!   const len = render(cfgPtr, cfgLen, factsPtr, factsLen, columns)
//!   read `len` bytes at output()  -> ANSI text, or an error message when len has bit 31 set
//!   reset()                        -> free everything before the next render

const std = @import("std");
const cfgm = @import("config.zig");
const render_mod = @import("render.zig");
const Facts = @import("facts.zig").Facts;

var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
var out_ptr: [*]const u8 = undefined;

export fn alloc(n: usize) ?[*]u8 {
    const buf = arena.allocator().alloc(u8, n) catch return null;
    return buf.ptr;
}

export fn reset() void {
    _ = arena.reset(.retain_capacity);
}

export fn output() [*]const u8 {
    return out_ptr;
}

export fn render(cfg_ptr: [*]const u8, cfg_len: usize, facts_ptr: [*]const u8, facts_len: usize, columns: u32) u32 {
    const a = arena.allocator();
    const text = run(a, cfg_ptr[0..cfg_len], facts_ptr[0..facts_len], columns) catch |e| {
        const msg = @errorName(e);
        out_ptr = msg.ptr;
        return @as(u32, @intCast(msg.len)) | 0x8000_0000;
    };
    out_ptr = text.ptr;
    return @intCast(text.len);
}

fn run(a: std.mem.Allocator, cfg_json: []const u8, facts_json: []const u8, columns: u32) ![]u8 {
    const cfg = try cfgm.parse(a, cfg_json);
    var facts = Facts.init(a);
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, facts_json, .{}) catch return error.InvalidFacts;
    facts.addJson("", v);
    facts.derive();
    return render_mod.render(a, cfg, &facts, columns);
}
