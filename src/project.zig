//! Project and environment facts: which toolchains the working directory uses
//! (marker files, then the runtime version found on PATH), the package it
//! belongs to, and the cloud / container contexts that CLI tools would act on.

const std = @import("std");
const cfgm = @import("config.zig");
const collect = @import("collect.zig");
const Facts = @import("facts.zig").Facts;
const Allocator = std.mem.Allocator;

const RUNTIME_TIMEOUT_MS = 1000;
// Runtime versions change only when PATH or the directory's pins change; both are in the cache key.
const RUNTIME_TTL_S = 60;
const MAX_UP = 8;

pub const Lang = struct {
    id: []const u8,
    /// File names in the directory (or a parent up to the repository root); `*.ext` matches a suffix.
    markers: []const []const u8,
    argv: []const []const u8,
    /// Version is the first number after this text (default: first number in the output).
    after: []const u8 = "",
};

pub const langs = [_]Lang{
    .{ .id = "node", .markers = &.{ "package.json", ".nvmrc", ".node-version" }, .argv = &.{ "node", "--version" } },
    .{ .id = "bun", .markers = &.{ "bun.lock", "bun.lockb", "bunfig.toml" }, .argv = &.{ "bun", "--version" } },
    .{ .id = "deno", .markers = &.{ "deno.json", "deno.jsonc", "deno.lock" }, .argv = &.{ "deno", "--version" } },
    .{ .id = "python", .markers = &.{ "pyproject.toml", "requirements.txt", "setup.py", "Pipfile", ".python-version", "uv.lock" }, .argv = &.{ "python3", "--version" } },
    .{ .id = "go", .markers = &.{ "go.mod", "go.work" }, .argv = &.{ "go", "env", "GOVERSION" } },
    .{ .id = "rust", .markers = &.{ "Cargo.toml", "rust-toolchain.toml", "rust-toolchain" }, .argv = &.{ "rustc", "--version" } },
    // `--version` (JDK 9+) prints to stdout; `-version` uses stderr
    .{ .id = "java", .markers = &.{ "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", ".java-version" }, .argv = &.{ "java", "--version" } },
    .{ .id = "ruby", .markers = &.{ "Gemfile", ".ruby-version" }, .argv = &.{ "ruby", "--version" } },
    .{ .id = "php", .markers = &.{"composer.json"}, .argv = &.{ "php", "--version" } },
    // "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 ...)"
    .{ .id = "swift", .markers = &.{ "Package.swift", "*.xcodeproj", "*.xcworkspace" }, .argv = &.{ "swift", "--version" }, .after = "Swift version " },
    .{ .id = "zig", .markers = &.{ "build.zig", "build.zig.zon" }, .argv = &.{ "zig", "version" } },
    .{ .id = "dotnet", .markers = &.{ "global.json", "*.csproj", "*.fsproj", "*.sln", "*.slnx" }, .argv = &.{ "dotnet", "--version" } },
};

/// Lockfile -> package manager, checked in this order within a directory.
const lockfiles = [_][2][]const u8{
    .{ "bun.lock", "bun" },             .{ "bun.lockb", "bun" },          .{ "pnpm-lock.yaml", "pnpm" },
    .{ "yarn.lock", "yarn" },           .{ "package-lock.json", "npm" },  .{ "deno.lock", "deno" },
    .{ "uv.lock", "uv" },               .{ "poetry.lock", "poetry" },     .{ "pdm.lock", "pdm" },
    .{ "Pipfile.lock", "pipenv" },      .{ "Cargo.lock", "cargo" },       .{ "go.sum", "go" },
    .{ "Gemfile.lock", "bundler" },     .{ "composer.lock", "composer" }, .{ "Package.resolved", "swiftpm" },
    .{ "gradlew", "gradle" },           .{ "pom.xml", "maven" },          .{ "mix.lock", "mix" },
    .{ "pubspec.lock", "pub" },
};

const manifests = [_][]const u8{ "package.json", "Cargo.toml", "pyproject.toml", "composer.json" };

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn matches(marker: []const u8, name: []const u8) bool {
    if (marker[0] == '*') return std.mem.endsWith(u8, name, marker[1..]);
    return eq(marker, name);
}

pub fn needed(cfg: cfgm.Config, id: []const u8) bool {
    for (cfg.lines) |line| for (line) |s| {
        if (eq(s.def.id, id)) return true;
    };
    return false;
}

/// Toolchain and package facts for `dir`.
pub fn project(a: Allocator, f: *Facts, cfg: cfgm.Config, dir: []const u8) void {
    var want_lang: [langs.len]bool = undefined;
    var any_lang = false;
    for (langs, 0..) |l, i| {
        want_lang[i] = needed(cfg, l.id);
        any_lang = any_lang or want_lang[i];
    }
    const want_pm = needed(cfg, "pkg-manager");
    const want_pkg = needed(cfg, "pkg-name") or needed(cfg, "pkg-version");
    if (needed(cfg, "python-venv")) venv(a, f);
    if (!any_lang and !want_pm and !want_pkg) return;

    var found: [langs.len]bool = @splat(false);
    var pm: ?[]const u8 = null;
    var manifest: ?[]const u8 = null;
    var cur: []const u8 = dir;
    const home = std.posix.getenv("HOME") orelse "";
    var depth: usize = 0;
    while (depth < MAX_UP) : (depth += 1) {
        var is_root = false;
        if (std.fs.openDirAbsolute(cur, .{ .iterate = true })) |d_| {
            var d = d_;
            defer d.close();
            var it = d.iterate();
            var dir_pm: ?usize = null;
            while (it.next() catch null) |e| {
                if (eq(e.name, ".git")) is_root = true;
                for (langs, 0..) |l, i| {
                    if (!want_lang[i] or found[i]) continue;
                    for (l.markers) |m| if (matches(m, e.name)) {
                        found[i] = true;
                        break;
                    };
                }
                if (pm == null) for (lockfiles, 0..) |lf, i| {
                    if (eq(lf[0], e.name) and (dir_pm == null or i < dir_pm.?)) dir_pm = i;
                };
                if (manifest == null) for (manifests) |m| {
                    if (eq(m, e.name)) manifest = std.fs.path.join(a, &.{ cur, m }) catch null;
                };
            }
            if (pm == null) if (dir_pm) |i| {
                pm = lockfiles[i][1];
            };
        } else |_| {}
        if (is_root or eq(cur, home)) break;
        cur = std.fs.path.dirname(cur) orelse break;
    }

    if (manifest) |m| package(a, f, m, &pm);
    if (want_pm) if (pm) |p| f.putStr("proj.pm", p);

    for (langs, 0..) |l, i| if (found[i]) runtime(a, f, l, dir);
}

fn runtime(a: Allocator, f: *Facts, l: Lang, dir: []const u8) void {
    const key = std.fmt.allocPrint(a, "lang.{s}", .{l.id}) catch return;
    const ck = std.fmt.allocPrint(a, "{s}\x00{s}\x00{s}", .{ l.id, std.posix.getenv("PATH") orelse "", dir }) catch return;
    const cache = collect.Cache.open(a, "lang", ck);
    if (cache.load(a, f, RUNTIME_TTL_S)) return;
    if (collect.run(a, l.argv, dir, RUNTIME_TIMEOUT_MS)) |out| {
        const from = if (l.after.len > 0) (if (std.mem.indexOf(u8, out, l.after)) |p| p + l.after.len else 0) else 0;
        if (version(out[from..])) |v| f.putStr(key, v);
    }
    // Stored even when empty, so a missing tool is not spawned again on every refresh.
    cache.store(a, f, &.{key});
}

/// First version-looking token: "v22.11.0" -> "22.11.0", "go1.25.1" -> "1.25.1", "openjdk 21 2023-09-19" -> "21".
pub fn version(out: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, out, " \t\r\n(),:");
    while (it.next()) |tok| {
        var s = tok;
        while (s.len > 0 and std.ascii.isAlphabetic(s[0])) s = s[1..];
        if (s.len == 0 or !std.ascii.isDigit(s[0])) continue;
        // short prefixes only ("v22", "go1.25"), not words that merely end in digits
        if (tok.len - s.len > 2) continue;
        var end: usize = 0;
        while (end < s.len and (std.ascii.isDigit(s[end]) or s[end] == '.')) end += 1;
        const v = std.mem.trimRight(u8, s[0..end], ".");
        if (v.len > 0) return v;
    }
    return null;
}

fn venv(a: Allocator, f: *Facts) void {
    if (std.posix.getenv("VIRTUAL_ENV")) |p| {
        const base = std.fs.path.basename(p);
        // ".venv" says nothing; the project directory that holds it does
        const generic = eq(base, ".venv") or eq(base, "venv") or eq(base, "env") or eq(base, ".env");
        const name = if (generic) std.fs.path.basename(std.fs.path.dirname(p) orelse p) else base;
        f.putStr("lang.venv", a.dupe(u8, name) catch return);
    } else if (std.posix.getenv("CONDA_DEFAULT_ENV")) |c| {
        f.putStr("lang.venv", c);
    }
}

fn package(a: Allocator, f: *Facts, path: []const u8, pm: *?[]const u8) void {
    const data = std.fs.cwd().readFileAlloc(a, path, 1 << 20) catch return;
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".json")) {
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, data, .{}) catch return;
        if (v != .object) return;
        if (v.object.get("name")) |n| if (n == .string) f.putStr("proj.name", n.string);
        if (v.object.get("version")) |n| if (n == .string) f.putStr("proj.version", n.string);
        // corepack's "packageManager": "pnpm@9.12.0" is authoritative over lockfiles
        if (v.object.get("packageManager")) |n| if (n == .string) {
            pm.* = std.mem.sliceTo(n.string, '@');
        };
        return;
    }
    // TOML: name / version in [package], [project] or [tool.poetry]
    var section: []const u8 = "";
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') {
            section = std.mem.trim(u8, line, "[] ");
            continue;
        }
        if (!(eq(section, "package") or eq(section, "project") or eq(section, "tool.poetry"))) continue;
        const eqpos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eqpos], " ");
        const val = std.mem.trim(u8, line[eqpos + 1 ..], " \"'");
        if (val.len == 0 or val[0] == '{') continue; // `version.workspace = true`
        if (eq(k, "name") and !f.has("proj.name")) f.putStr("proj.name", val);
        if (eq(k, "version") and !f.has("proj.version")) f.putStr("proj.version", val);
    }
}

// ---------------------------------------------------------------------------
// cloud and environment

pub fn cloud(a: Allocator, f: *Facts, cfg: cfgm.Config, dir: ?[]const u8) void {
    const env = std.posix.getenv;
    const home = env("HOME") orelse "";
    if (needed(cfg, "k8s-context") or needed(cfg, "k8s-namespace")) kube(a, f, home);
    if (needed(cfg, "docker-context")) {
        const c = env("DOCKER_CONTEXT") orelse readJsonStr(a, home, ".docker/config.json", "currentContext");
        // "default" is the local daemon; only a switched context is worth showing
        if (c) |v| if (!eq(v, "default")) f.putStr("cloud.docker_context", v);
    }
    if (env("AWS_VAULT") orelse env("AWS_PROFILE")) |p| f.putStr("cloud.aws_profile", p);
    if (env("AWS_REGION") orelse env("AWS_DEFAULT_REGION")) |r| f.putStr("cloud.aws_region", r);
    if (needed(cfg, "gcloud-project")) gcloud(a, f, home);
    if (env("TF_WORKSPACE")) |w| {
        f.putStr("cloud.terraform", w);
    } else if (dir) |d| {
        const p = std.fs.path.join(a, &.{ d, ".terraform", "environment" }) catch "";
        if (std.fs.cwd().readFileAlloc(a, p, 4096)) |w| f.putStr("cloud.terraform", std.mem.trim(u8, w, " \r\n")) else |_| {}
    }
    if (env("IN_NIX_SHELL") != null) f.put("cloud.nix", .{ .flag = true });
    if (env("SSH_CONNECTION") != null or env("SSH_TTY") != null) f.put("cloud.ssh", .{ .flag = true });
    if (env("container") != null or env("REMOTE_CONTAINERS") != null or env("CODESPACES") != null or
        exists("/.dockerenv") or exists("/run/.containerenv")) f.put("cloud.container", .{ .flag = true });
}

fn exists(p: []const u8) bool {
    std.fs.accessAbsolute(p, .{}) catch return false;
    return true;
}

fn readJsonStr(a: Allocator, home: []const u8, rel: []const u8, field: []const u8) ?[]const u8 {
    const p = std.fs.path.join(a, &.{ home, rel }) catch return null;
    const data = std.fs.cwd().readFileAlloc(a, p, 1 << 20) catch return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, data, .{}) catch return null;
    if (v != .object) return null;
    const s = v.object.get(field) orelse return null;
    return if (s == .string) s.string else null;
}

/// current-context and its namespace from the first kubeconfig file. A line scan
/// rather than a YAML parser: kubectl writes this file in one predictable shape.
fn kube(a: Allocator, f: *Facts, home: []const u8) void {
    const path = if (std.posix.getenv("KUBECONFIG")) |k|
        std.mem.sliceTo(k, ':')
    else
        std.fs.path.join(a, &.{ home, ".kube", "config" }) catch return;
    const data = std.fs.cwd().readFileAlloc(a, path, 4 << 20) catch return;
    var current: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "current-context:")) current = yamlVal(line["current-context:".len..]);
    }
    const ctx = current orelse return;
    if (ctx.len == 0) return;
    f.putStr("cloud.k8s_context", ctx);

    // contexts: list items; each has `name:` and an optional nested `namespace:`
    var in_contexts = false;
    var ns: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len > 0 and line[0] != ' ' and line[0] != '-') {
            if (in_contexts) break;
            in_contexts = std.mem.startsWith(u8, line, "contexts:");
            continue;
        }
        if (!in_contexts) continue;
        const t = std.mem.trimLeft(u8, line, " ");
        if (std.mem.startsWith(u8, t, "- ")) {
            if (name != null and eq(name.?, ctx)) break;
            ns = null;
            name = null;
        }
        const item = std.mem.trimLeft(u8, t, "- ");
        if (std.mem.startsWith(u8, item, "namespace:")) ns = yamlVal(item["namespace:".len..]);
        if (std.mem.startsWith(u8, item, "name:")) name = yamlVal(item["name:".len..]);
    }
    if (name != null and eq(name.?, ctx)) if (ns) |n| f.putStr("cloud.k8s_namespace", n);
}

fn yamlVal(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\"'");
}

fn gcloud(a: Allocator, f: *Facts, home: []const u8) void {
    if (std.posix.getenv("CLOUDSDK_CORE_PROJECT")) |p| return f.putStr("cloud.gcloud_project", p);
    const base = std.posix.getenv("CLOUDSDK_CONFIG") orelse (std.fs.path.join(a, &.{ home, ".config", "gcloud" }) catch return);
    const active = std.posix.getenv("CLOUDSDK_ACTIVE_CONFIG_NAME") orelse blk: {
        const p = std.fs.path.join(a, &.{ base, "active_config" }) catch return;
        const d = std.fs.cwd().readFileAlloc(a, p, 4096) catch break :blk "default";
        break :blk std.mem.trim(u8, d, " \r\n");
    };
    const name = std.fmt.allocPrint(a, "config_{s}", .{active}) catch return;
    const p = std.fs.path.join(a, &.{ base, "configurations", name }) catch return;
    const data = std.fs.cwd().readFileAlloc(a, p, 1 << 20) catch return;
    var section: []const u8 = "";
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') {
            section = std.mem.trim(u8, line, "[] ");
            continue;
        }
        if (!eq(section, "core")) continue;
        const eqpos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (eq(std.mem.trim(u8, line[0..eqpos], " "), "project")) {
            return f.putStr("cloud.gcloud_project", std.mem.trim(u8, line[eqpos + 1 ..], " "));
        }
    }
}

test "version tokens" {
    const t = std.testing;
    try t.expectEqualStrings("22.11.0", version("v22.11.0\n").?);
    try t.expectEqualStrings("1.25.1", version("go1.25.1\n").?);
    try t.expectEqualStrings("21", version("openjdk 21 2023-09-19\nOpenJDK Runtime").?);
    try t.expectEqualStrings("3.13.0", version("Python 3.13.0rc1\n").?);
    try t.expectEqualStrings("1.83.0", version("rustc 1.83.0 (90b35a623 2024-11-26)").?);
    try t.expectEqualStrings("8.3.1", version("PHP 8.3.1 (cli) (built: Dec 20 2023)").?);
    try t.expectEqualStrings("6.2", version("6.2 (swiftlang-6.2.0.19.9 clang-1700.3.19.1)").?);
    try t.expectEqual(@as(?[]const u8, null), version("command not found"));
}
