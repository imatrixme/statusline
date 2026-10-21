//! System load facts: CPU usage, memory, swap, disk space, fan speed and uptime.
//! Read through sysctl / Mach host statistics / the AppleSMC on macOS and /proc,
//! /sys on Linux; nothing here starts a process except `df`.

const std = @import("std");
const builtin = @import("builtin");
const collect = @import("collect.zig");
const Facts = @import("facts.zig").Facts;
const Allocator = std.mem.Allocator;

const macos = builtin.os.tag == .macos;

// A refresh right after the previous one measures CPU over the time between them;
// when the last snapshot is older than this, sample over a short window instead.
const CPU_WINDOW_S = 60;
const CPU_SAMPLE_MS = 50;
const DISK_TTL_S = 30;

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------------------
// CPU

const Ticks = struct { busy: u64, total: u64 };

const HOST_CPU_LOAD_INFO = 3;
const HOST_VM_INFO64 = 4;
extern "c" fn mach_host_self() u32;
extern "c" fn host_statistics(host: u32, flavor: c_int, info: [*]c_int, count: *u32) c_int;
extern "c" fn host_statistics64(host: u32, flavor: c_int, info: [*]c_int, count: *u32) c_int;

fn ticks(a: Allocator) ?Ticks {
    if (macos) {
        // user, system, idle, nice
        var t: [4]u32 = undefined;
        var count: u32 = 4;
        if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, @ptrCast(&t), &count) != 0) return null;
        const total = @as(u64, t[0]) + t[1] + t[2] + t[3];
        return .{ .busy = total - t[2], .total = total };
    }
    const data = std.fs.cwd().readFileAlloc(a, "/proc/stat", 1 << 20) catch return null;
    var it = std.mem.tokenizeAny(u8, std.mem.sliceTo(data, '\n'), " ");
    if (!eq(it.next() orelse return null, "cpu")) return null;
    var total: u64 = 0;
    var idle: u64 = 0;
    var i: usize = 0;
    // user nice system idle iowait irq softirq steal
    while (it.next()) |tok| : (i += 1) {
        if (i >= 8) break;
        const v = std.fmt.parseInt(u64, tok, 10) catch return null;
        total += v;
        if (i == 3 or i == 4) idle += v;
    }
    return .{ .busy = total - idle, .total = total };
}

fn cpu(a: Allocator, f: *Facts) void {
    const now = ticks(a) orelse return;
    const path = std.fs.path.join(a, &.{ collect.tmpDir(a), "cpu-ticks" }) catch return;
    var prev: ?Ticks = null;
    if (std.fs.openFileAbsolute(path, .{})) |file| {
        defer file.close();
        const st = file.stat() catch null;
        var buf: [64]u8 = undefined;
        const n = file.readAll(&buf) catch 0;
        const fresh = if (st) |s| std.time.nanoTimestamp() - s.mtime < CPU_WINDOW_S * std.time.ns_per_s else false;
        var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
        if (fresh) if (it.next()) |b| if (it.next()) |t| {
            prev = .{ .busy = std.fmt.parseInt(u64, b, 10) catch 0, .total = std.fmt.parseInt(u64, std.mem.trim(u8, t, "\n"), 10) catch 0 };
        };
    } else |_| {}
    var cur = now;
    if (prev == null or prev.?.total >= now.total) {
        std.Thread.sleep(CPU_SAMPLE_MS * std.time.ns_per_ms);
        prev = now;
        cur = ticks(a) orelse return;
    }
    const p = prev.?;
    // Mach tick counters are 32-bit and wrap; a backwards step means "start over"
    if (cur.total > p.total and cur.busy >= p.busy) {
        const busy: f64 = @floatFromInt(cur.busy - p.busy);
        const total: f64 = @floatFromInt(cur.total - p.total);
        f.putNum("sys.cpu", busy / total * 100);
    }
    const line = std.fmt.allocPrint(a, "{d} {d}\n", .{ cur.busy, cur.total }) catch return;
    const tmp = std.fmt.allocPrint(a, "{s}.{d}", .{ path, std.time.milliTimestamp() }) catch return;
    const file = std.fs.createFileAbsolute(tmp, .{}) catch return;
    file.writeAll(line) catch {};
    file.close();
    std.fs.renameAbsolute(tmp, path) catch {};
}

// ---------------------------------------------------------------------------
// memory, swap, uptime

const VmStats64 = extern struct {
    free_count: u32,
    active_count: u32,
    inactive_count: u32,
    wire_count: u32,
    zero_fill_count: u64,
    reactivations: u64,
    pageins: u64,
    pageouts: u64,
    faults: u64,
    cow_faults: u64,
    lookups: u64,
    hits: u64,
    purges: u64,
    purgeable_count: u32,
    speculative_count: u32,
    decompressions: u64,
    compressions: u64,
    swapins: u64,
    swapouts: u64,
    compressor_page_count: u32,
    throttled_count: u32,
    external_page_count: u32,
    internal_page_count: u32,
    total_uncompressed_pages_in_compressor: u64,
};

fn sysctl(comptime T: type, name: [:0]const u8) ?T {
    var v: T = undefined;
    var len: usize = @sizeOf(T);
    if (std.c.sysctlbyname(name, &v, &len, null, 0) != 0) return null;
    return v;
}

fn memory(a: Allocator, f: *Facts, swap: bool) void {
    if (macos) {
        const total = sysctl(u64, "hw.memsize") orelse return;
        var vm: VmStats64 = undefined;
        var count: u32 = @sizeOf(VmStats64) / @sizeOf(c_int);
        if (host_statistics64(mach_host_self(), HOST_VM_INFO64, @ptrCast(&vm), &count) != 0) return;
        // Activity Monitor's "Memory Used": app memory + wired + compressed
        const page: f64 = @floatFromInt(std.heap.pageSize());
        const app: f64 = @as(f64, @floatFromInt(vm.internal_page_count)) - @as(f64, @floatFromInt(vm.purgeable_count));
        const used = (app + @as(f64, @floatFromInt(vm.wire_count)) + @as(f64, @floatFromInt(vm.compressor_page_count))) * page;
        putMem(f, used, @floatFromInt(total));
        if (swap) {
            // struct xsw_usage { u64 total, avail, used; u32 pagesize; bool encrypted }
            if (sysctl([4]u64, "vm.swapusage")) |x| f.putNum("sys.swap_used", @floatFromInt(x[2]));
        }
        return;
    }
    const data = std.fs.cwd().readFileAlloc(a, "/proc/meminfo", 64 << 10) catch return;
    var total: ?f64 = null;
    var avail: ?f64 = null;
    var swap_total: ?f64 = null;
    var swap_free: ?f64 = null;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        var cols = std.mem.tokenizeAny(u8, line, ": ");
        const k = cols.next() orelse continue;
        const v = (std.fmt.parseFloat(f64, cols.next() orelse continue) catch continue) * 1024;
        if (eq(k, "MemTotal")) total = v;
        if (eq(k, "MemAvailable")) avail = v;
        if (eq(k, "SwapTotal")) swap_total = v;
        if (eq(k, "SwapFree")) swap_free = v;
    }
    if (total != null and avail != null) putMem(f, total.? - avail.?, total.?);
    if (swap and swap_total != null and swap_free != null) f.putNum("sys.swap_used", swap_total.? - swap_free.?);
}

fn putMem(f: *Facts, used: f64, total: f64) void {
    if (total <= 0) return;
    f.putNum("sys.mem_used", used);
    f.putNum("sys.mem_total", total);
    f.putNum("sys.mem_used_pct", used / total * 100);
}

fn uptime(a: Allocator, f: *Facts) void {
    if (macos) {
        // struct timeval kern.boottime
        const tv = sysctl([2]i64, "kern.boottime") orelse return;
        f.putNum("sys.uptime", @floatFromInt(std.time.timestamp() - tv[0]));
        return;
    }
    const data = std.fs.cwd().readFileAlloc(a, "/proc/uptime", 256) catch return;
    var it = std.mem.tokenizeScalar(u8, data, ' ');
    f.putNum("sys.uptime", std.fmt.parseFloat(f64, it.next() orelse return) catch return);
}

// ---------------------------------------------------------------------------
// disk

/// Free space and use of the volume holding `dir`, from POSIX `df -Pk`.
fn disk(a: Allocator, f: *Facts, dir: []const u8) void {
    const cache = collect.Cache.open(a, "disk", dir);
    if (cache.load(a, f, DISK_TTL_S)) return;
    if (collect.run(a, &.{ "df", "-Pk", dir }, null, 500)) |out| {
        var lines = std.mem.splitScalar(u8, out, '\n');
        _ = lines.next();
        var cols = std.mem.tokenizeScalar(u8, lines.next() orelse "", ' ');
        _ = cols.next(); // filesystem
        _ = cols.next(); // 1024-blocks
        const used = std.fmt.parseFloat(f64, cols.next() orelse "") catch null;
        const avail = std.fmt.parseFloat(f64, cols.next() orelse "") catch null;
        if (used != null and avail != null and used.? + avail.? > 0) {
            f.putNum("sys.disk_free", avail.? * 1024);
            f.putNum("sys.disk_used_pct", used.? / (used.? + avail.?) * 100);
        }
    }
    cache.store(a, f, &.{ "sys.disk_free", "sys.disk_used_pct" });
}

// ---------------------------------------------------------------------------
// fan

/// First fan's speed in rpm. macOS: AppleSMC keys FNum / F0Ac through IOKit, loaded at
/// run time so the binary does not link the framework. Linux: hwmon fan*_input.
fn fan(a: Allocator, f: *Facts) void {
    if (macos) {
        if (Smc.open()) |smc| {
            defer smc.close();
            const n = smc.read("FNum") orelse return;
            if (n.size == 0 or n.bytes[0] == 0) return;
            if (smc.read("F0Ac")) |v| if (v.number()) |rpm| f.putNum("sys.fan", @round(rpm));
        }
        return;
    }
    var hw = std.fs.openDirAbsolute("/sys/class/hwmon", .{ .iterate = true }) catch return;
    defer hw.close();
    var it = hw.iterate();
    while (it.next() catch null) |e| {
        const p = std.fmt.allocPrint(a, "/sys/class/hwmon/{s}/fan1_input", .{e.name}) catch continue;
        const data = std.fs.cwd().readFileAlloc(a, p, 64) catch continue;
        const rpm = std.fmt.parseFloat(f64, std.mem.trim(u8, data, " \n")) catch continue;
        f.putNum("sys.fan", rpm);
        return;
    }
}

const Smc = struct {
    conn: u32,
    lib: std.DynLib,
    call: *const fn (u32, u32, *const anyopaque, usize, *anyopaque, *usize) callconv(.c) c_int,
    close_fn: *const fn (u32) callconv(.c) c_int,

    // SMCKeyData_t from the AppleSMC user client (80 bytes)
    const KeyData = extern struct {
        key: u32 = 0,
        vers: [6]u8 = @splat(0),
        _pad0: [2]u8 = @splat(0),
        plimit: [16]u8 = @splat(0),
        data_size: u32 = 0,
        data_type: u32 = 0,
        data_attr: u8 = 0,
        _pad1: [3]u8 = @splat(0),
        result: u8 = 0,
        status: u8 = 0,
        data8: u8 = 0,
        _pad2: u8 = 0,
        data32: u32 = 0,
        bytes: [32]u8 = @splat(0),
    };
    comptime {
        std.debug.assert(@sizeOf(KeyData) == 80);
    }
    const KERNEL_INDEX_SMC = 2;
    const CMD_READ_BYTES = 5;
    const CMD_READ_KEYINFO = 9;

    const Value = struct {
        type: u32,
        size: u32,
        bytes: [32]u8,

        fn number(v: Value) ?f64 {
            if (v.type == fourcc("flt ") and v.size == 4) return @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, v.bytes[0..4], .little))));
            if (v.type == fourcc("fpe2") and v.size == 2) return @as(f64, @floatFromInt(std.mem.readInt(u16, v.bytes[0..2], .big))) / 4;
            if (v.type == fourcc("ui16") and v.size == 2) return @floatFromInt(std.mem.readInt(u16, v.bytes[0..2], .big));
            return null;
        }
    };

    fn fourcc(s: *const [4]u8) u32 {
        return std.mem.readInt(u32, s, .big);
    }

    extern "c" var mach_task_self_: u32;

    fn open() ?Smc {
        var lib = std.DynLib.open("/System/Library/Frameworks/IOKit.framework/IOKit") catch return null;
        const matching = lib.lookup(*const fn ([*:0]const u8) callconv(.c) ?*anyopaque, "IOServiceMatching") orelse return fail(&lib);
        const get = lib.lookup(*const fn (u32, ?*anyopaque) callconv(.c) u32, "IOServiceGetMatchingService") orelse return fail(&lib);
        const open_fn = lib.lookup(*const fn (u32, u32, u32, *u32) callconv(.c) c_int, "IOServiceOpen") orelse return fail(&lib);
        const release = lib.lookup(*const fn (u32) callconv(.c) c_int, "IOObjectRelease") orelse return fail(&lib);
        const call = lib.lookup(*const fn (u32, u32, *const anyopaque, usize, *anyopaque, *usize) callconv(.c) c_int, "IOConnectCallStructMethod") orelse return fail(&lib);
        const close_fn = lib.lookup(*const fn (u32) callconv(.c) c_int, "IOServiceClose") orelse return fail(&lib);
        // IOServiceGetMatchingService consumes the matching dictionary
        const service = get(0, matching("AppleSMC"));
        if (service == 0) return fail(&lib);
        defer _ = release(service);
        var conn: u32 = 0;
        if (open_fn(service, mach_task_self_, 0, &conn) != 0) return fail(&lib);
        return .{ .conn = conn, .lib = lib, .call = call, .close_fn = close_fn };
    }

    fn fail(lib: *std.DynLib) ?Smc {
        lib.close();
        return null;
    }

    fn close(self: Smc) void {
        _ = self.close_fn(self.conn);
        var lib = self.lib;
        lib.close();
    }

    fn exchange(self: Smc, in: *const KeyData) ?KeyData {
        var out: KeyData = .{};
        var len: usize = @sizeOf(KeyData);
        if (self.call(self.conn, KERNEL_INDEX_SMC, in, @sizeOf(KeyData), &out, &len) != 0 or out.result != 0) return null;
        return out;
    }

    fn read(self: Smc, key: *const [4]u8) ?Value {
        const info = self.exchange(&.{ .key = fourcc(key), .data8 = CMD_READ_KEYINFO }) orelse return null;
        var in: KeyData = .{ .key = fourcc(key), .data8 = CMD_READ_BYTES };
        in.data_size = info.data_size;
        const out = self.exchange(&in) orelse return null;
        return .{ .type = info.data_type, .size = info.data_size, .bytes = out.bytes };
    }
};

// ---------------------------------------------------------------------------

pub const Needs = struct { cpu: bool = false, mem: bool = false, swap: bool = false, disk: bool = false, fan: bool = false, uptime: bool = false };

pub fn collectSys(a: Allocator, f: *Facts, n: Needs, dir: ?[]const u8) void {
    if (n.cpu) cpu(a, f);
    if (n.mem or n.swap) memory(a, f, n.swap);
    if (n.uptime) uptime(a, f);
    if (n.disk) disk(a, f, dir orelse std.posix.getenv("HOME") orelse "/");
    if (n.fan) fan(a, f);
}
