//! Segment catalogue. Every segment the renderer can draw is declared here once;
//! the web editor reads the same table through `omnitt-statusline registry`.

const std = @import("std");
const codex = @import("codex.zig");

pub const Kind = enum {
    /// String fact, optionally transformed.
    text,
    /// Number with a numeric format (compact / raw / grouped).
    number,
    /// Number shown as a percentage; `scale` converts ratios to 0–100.
    percent,
    /// Elapsed time; `unit` says whether the fact is in ms or s.
    duration,
    /// Money with a currency symbol.
    money,
    /// Boolean: `on` text when true, `off` text (if any) when false.
    flag,
    /// Percentage drawn as a bar, optionally followed by text.
    bar,
    /// `used/total` pair, e.g. `90k/1M`.
    fraction,
    /// Epoch seconds in the future, shown as remaining time or wall-clock time.
    countdown,
    /// Epoch seconds in the past, shown as age.
    ago,
    /// Current time (`sys.now`) in a time zone.
    clock,
    /// Pull request number with review state and an OSC 8 link.
    pr,
    /// Byte count in binary units ("1.2G"); with `total`, "9.1G/16G".
    bytes,
};

pub const Source = enum { session, transcript, git, project, cloud, system, disk, custom };

pub const Unit = enum { none, ms, s };

pub const Xform = enum {
    none,
    /// "Opus 5.5 (1M context)" -> "Opus 5.5"
    strip_ctx,
    /// Directory display, controlled by the segment's `dir` option.
    dir,
    /// First 8 characters (ids, hashes).
    short,
};

pub const Group = struct { id: []const u8, name: []const u8, name_zh: []const u8 };

pub const groups = [_]Group{
    .{ .id = "model", .name = "Model", .name_zh = "模型" },
    .{ .id = "context", .name = "Context window", .name_zh = "上下文" },
    .{ .id = "tokens", .name = "Tokens", .name_zh = "累计 token" },
    .{ .id = "cache", .name = "Prompt cache", .name_zh = "Prompt cache" },
    .{ .id = "cost", .name = "Cost & time", .name_zh = "费用与时间" },
    .{ .id = "limits", .name = "Rate limits", .name_zh = "限额" },
    .{ .id = "session", .name = "Session", .name_zh = "会话" },
    .{ .id = "workspace", .name = "Workspace", .name_zh = "工作区" },
    .{ .id = "turn", .name = "Turn (transcript)", .name_zh = "轮次（transcript）" },
    .{ .id = "git", .name = "Git", .name_zh = "Git" },
    .{ .id = "lang", .name = "Languages & runtimes", .name_zh = "语言与运行时" },
    .{ .id = "project", .name = "Package", .name_zh = "项目包" },
    .{ .id = "cloud", .name = "Cloud & environment", .name_zh = "云与环境" },
    .{ .id = "system", .name = "System", .name_zh = "系统" },
    .{ .id = "disk", .name = "Disk usage", .name_zh = "磁盘占用" },
    .{ .id = "custom", .name = "Custom", .name_zh = "自定义" },
};

pub const Def = struct {
    id: []const u8,
    group: []const u8,
    source: Source,
    kind: Kind,
    /// Fact key read by the segment (empty for segments that compute their own).
    fact: []const u8 = "",
    icon: []const u8,
    color: u8,
    name: []const u8,
    name_zh: []const u8,
    fmt: []const u8 = "",
    unit: Unit = .none,
    scale: f64 = 1,
    decimals: u8 = 0,
    suffix: []const u8 = "",
    on: []const u8 = "",
    off: []const u8 = "",
    off_color: ?u8 = null,
    xform: Xform = .none,
    /// Bar / fraction: facts for the `used/total` text.
    used: []const u8 = "",
    total: []const u8 = "",
    /// Only show when this boolean fact is true.
    gate: []const u8 = "",
    /// Default threshold colours: value >= rule[0] -> colour rule[1].
    rules: []const [2]f64 = &.{},
    /// Oldest Claude Code version that provides the fact, when known.
    since: []const u8 = "",
};

// Nerd Font (Material Design) code points
const ROBOT = "\u{F06A9}";
const BRAIN = "\u{F09D1}";
const CHIP = "\u{F035B}";
const COUNT = "\u{F006A}";
const CLOCK = "\u{F0954}";
const DOWN = "\u{F0045}";
const UP = "\u{F005D}";
const CACHE = "\u{F0450}";
const FIRE = "\u{F0238}";
const DOLLAR = "\u{F01C1}";
const TIMER = "\u{F051B}";
const SPEED = "\u{F04C5}";
const BRANCH = "\u{E0A0}";
const PLUS = "\u{F0415}";
const MINUS = "\u{F0374}";
const FOLDER = "\u{F024B}";
const GIT = "\u{F02A2}";
const SERVER = "\u{F048B}";
const USER = "\u{F0004}";
const CALENDAR = "\u{F00ED}";
const BATTERY = "\u{F0079}";
const GITHUB = "\u{F02A4}";
const CONSOLE = "\u{F018D}";
const BOLT = "\u{F140B}";
const TAG = "\u{F04F9}";
const PALETTE = "\u{F03D8}";
const HOURGLASS = "\u{F051F}";
const WRENCH = "\u{F05B7}";
const GAUGE = "\u{F029A}";
const TEXT = "\u{F09A8}";
// Devicons / Seti / Material Design, names as in Nerd Fonts glyphnames.json
const NODE = "\u{E718}"; // dev-nodejs_small
const BUN = "\u{E76F}"; // dev-bun
const DENO = "\u{E7C0}"; // dev-denojs
const PYTHON = "\u{E73C}"; // dev-python
const VENV = "\u{F0320}"; // md-language_python
const GO = "\u{E627}"; // seti-go
const RUST = "\u{E7A8}"; // dev-rust
const JAVA = "\u{E738}"; // dev-java
const RUBY = "\u{E739}"; // dev-ruby
const PHP = "\u{E73D}"; // dev-php
const SWIFT = "\u{E755}"; // dev-swift
const ZIG = "\u{E6A9}"; // seti-zig
const DOTNET = "\u{E77F}"; // dev-dotnet
const PACKAGE = "\u{F03D3}"; // md-package
const PACKAGE_VARIANT = "\u{F03D6}"; // md-package_variant
const TAG_TEXT = "\u{F1224}"; // md-tag_text
const K8S = "\u{F10FE}"; // md-kubernetes
const DOCKER = "\u{F0868}"; // md-docker
const AWS = "\u{F0E0F}"; // md-aws
const GCLOUD = "\u{F11F6}"; // md-google_cloud
const TERRAFORM = "\u{F1062}"; // md-terraform
const NIX = "\u{F1105}"; // md-nix
const SSH = "\u{F08C0}"; // md-ssh
const CUBE = "\u{F01A7}"; // md-cube_outline
const CONFLICT = "\u{F0029}"; // md-alert_octagon
const MERGE = "\u{F062D}"; // md-source_merge
const UPSTREAM = "\u{F14CE}"; // md-source_branch_sync
const CPU = "\u{F0EE0}"; // md-cpu_64_bit
const MEMORY = "\u{F035B}"; // md-memory
const SWAP = "\u{F04E1}"; // md-swap_horizontal
const HARDDISK = "\u{F02CA}"; // md-harddisk
const FAN = "\u{F0210}"; // md-fan
const UPTIME = "\u{F0150}"; // md-clock_outline
const FOLDER_SIZE = "\u{F0256}"; // md-folder_outline
const WORKTREES = "\u{F062C}"; // md-source_branch

const ctx_rules = &[_][2]f64{ .{ 0, 78 }, .{ 50, 220 }, .{ 80, 203 } };
const limit_rules = &[_][2]f64{ .{ 0, 78 }, .{ 70, 220 }, .{ 90, 203 } };

pub const defs = [_]Def{
    // model
    .{ .id = "model", .group = "model", .source = .session, .kind = .text, .fact = "model.display_name", .xform = .strip_ctx, .icon = ROBOT, .color = 141, .name = "Model", .name_zh = "模型名称" },
    .{ .id = "model-id", .group = "model", .source = .session, .kind = .text, .fact = "model.id", .icon = ROBOT, .color = 141, .name = "Model ID", .name_zh = "模型 ID" },
    .{ .id = "effort", .group = "model", .source = .session, .kind = .text, .fact = "effort.level", .icon = BRAIN, .color = 214, .name = "Effort", .name_zh = "推理强度" },
    .{ .id = "thinking", .group = "model", .source = .session, .kind = .flag, .fact = "thinking.enabled", .on = "thinking", .icon = BRAIN, .color = 177, .name = "Thinking", .name_zh = "扩展思考" },
    .{ .id = "fast-mode", .group = "model", .source = .session, .kind = .flag, .fact = "fast_mode", .on = "fast", .icon = BOLT, .color = 220, .name = "Fast mode", .name_zh = "快速模式" },
    .{ .id = "output-style", .group = "model", .source = .session, .kind = .text, .fact = "output_style.name", .icon = PALETTE, .color = 146, .name = "Output style", .name_zh = "输出风格" },
    .{ .id = "agent", .group = "model", .source = .session, .kind = .text, .fact = "agent.name", .icon = ROBOT, .color = 117, .name = "Agent", .name_zh = "Agent 名称" },

    // context
    .{ .id = "ctx-bar", .group = "context", .source = .session, .kind = .bar, .fact = "context_window.used_percentage", .used = "context_window.total_input_tokens", .total = "context_window.context_window_size", .fmt = "used_total_pct", .rules = ctx_rules, .icon = CHIP, .color = 78, .name = "Context bar", .name_zh = "上下文进度条" },
    .{ .id = "ctx-used-pct", .group = "context", .source = .session, .kind = .percent, .fact = "context_window.used_percentage", .rules = ctx_rules, .icon = CHIP, .color = 78, .name = "Context used %", .name_zh = "上下文已用 %" },
    .{ .id = "ctx-remaining-pct", .group = "context", .source = .session, .kind = .percent, .fact = "context_window.remaining_percentage", .icon = CHIP, .color = 78, .name = "Context left %", .name_zh = "上下文剩余 %" },
    .{ .id = "ctx-tokens", .group = "context", .source = .session, .kind = .fraction, .used = "context_window.total_input_tokens", .total = "context_window.context_window_size", .icon = CHIP, .color = 81, .name = "Context tokens", .name_zh = "上下文 token（已用/上限）" },
    .{ .id = "ctx-window-size", .group = "context", .source = .session, .kind = .number, .fact = "context_window.context_window_size", .fmt = "compact", .icon = CHIP, .color = 81, .name = "Context size", .name_zh = "上下文上限" },
    .{ .id = "last-input", .group = "context", .source = .session, .kind = .number, .fact = "context_window.current_usage.input_tokens", .fmt = "compact", .icon = DOWN, .color = 81, .name = "Last input", .name_zh = "上次调用输入" },
    .{ .id = "last-output", .group = "context", .source = .session, .kind = .number, .fact = "context_window.current_usage.output_tokens", .fmt = "compact", .icon = UP, .color = 114, .name = "Last output", .name_zh = "上次调用输出" },
    .{ .id = "last-cache-read", .group = "context", .source = .session, .kind = .number, .fact = "context_window.current_usage.cache_read_input_tokens", .fmt = "compact", .icon = CACHE, .color = 79, .name = "Last cache read", .name_zh = "上次缓存读取" },
    .{ .id = "last-cache-write", .group = "context", .source = .session, .kind = .number, .fact = "context_window.current_usage.cache_creation_input_tokens", .fmt = "compact", .icon = CACHE, .color = 173, .name = "Last cache write", .name_zh = "上次缓存写入" },
    .{ .id = "exceeds-200k", .group = "context", .source = .session, .kind = .flag, .fact = "exceeds_200k_tokens", .on = ">200k", .icon = CHIP, .color = 203, .name = "Over 200k", .name_zh = "超过 200k" },

    // tokens
    .{ .id = "tokens-in", .group = "tokens", .source = .session, .kind = .number, .fact = "context_window.total_input_tokens", .fmt = "compact", .icon = DOWN, .color = 81, .name = "Input tokens", .name_zh = "输入 token" },
    .{ .id = "tokens-out", .group = "tokens", .source = .session, .kind = .number, .fact = "context_window.total_output_tokens", .fmt = "compact", .icon = UP, .color = 114, .name = "Output tokens", .name_zh = "输出 token" },

    // prompt cache
    .{ .id = "cache-hit", .group = "cache", .source = .session, .kind = .percent, .fact = "prompt_cache.hit_ratio", .scale = 100, .icon = CACHE, .color = 79, .name = "Cache hit rate", .name_zh = "缓存命中率", .since = "2.1.251" },
    .{ .id = "cache-warm", .group = "cache", .source = .session, .kind = .flag, .fact = "prompt_cache.warm", .gate = "prompt_cache.caching_observed", .on = "HOT", .off = "COLD", .off_color = 75, .icon = FIRE, .color = 209, .name = "Cache warm", .name_zh = "缓存冷热", .since = "2.1.251" },
    .{ .id = "cache-expires", .group = "cache", .source = .session, .kind = .countdown, .fact = "prompt_cache.expires_at", .fmt = "countdown", .icon = HOURGLASS, .color = 209, .name = "Cache expires in", .name_zh = "缓存剩余时间", .since = "2.1.251" },
    .{ .id = "cache-misses", .group = "cache", .source = .session, .kind = .number, .fact = "prompt_cache.misses", .fmt = "raw", .icon = CACHE, .color = 203, .name = "Cache misses", .name_zh = "缓存未命中次数", .since = "2.1.251" },

    // cost & time
    .{ .id = "cost", .group = "cost", .source = .session, .kind = .money, .fact = "cost.total_cost_usd", .decimals = 2, .icon = DOLLAR, .color = 220, .name = "Cost", .name_zh = "费用" },
    .{ .id = "session-duration", .group = "cost", .source = .session, .kind = .duration, .fact = "cost.total_duration_ms", .unit = .ms, .fmt = "hm", .icon = CLOCK, .color = 183, .name = "Session time", .name_zh = "会话时长" },
    .{ .id = "api-duration", .group = "cost", .source = .session, .kind = .duration, .fact = "cost.total_api_duration_ms", .unit = .ms, .fmt = "hm", .icon = CLOCK, .color = 183, .name = "API time", .name_zh = "API 时长" },
    .{ .id = "api-ratio", .group = "cost", .source = .session, .kind = .percent, .fact = "derived.api_ratio", .icon = GAUGE, .color = 183, .name = "API time share", .name_zh = "API 时间占比" },
    .{ .id = "lines-added", .group = "cost", .source = .session, .kind = .number, .fact = "cost.total_lines_added", .fmt = "grouped", .icon = PLUS, .color = 78, .name = "Lines added", .name_zh = "新增行数" },
    .{ .id = "lines-removed", .group = "cost", .source = .session, .kind = .number, .fact = "cost.total_lines_removed", .fmt = "grouped", .icon = MINUS, .color = 203, .name = "Lines removed", .name_zh = "删除行数" },

    // rate limits
    .{ .id = "limit-5h-pct", .group = "limits", .source = .session, .kind = .percent, .fact = "rate_limits.five_hour.used_percentage", .rules = limit_rules, .icon = GAUGE, .color = 78, .name = "5h limit %", .name_zh = "5 小时限额 %" },
    .{ .id = "limit-5h-bar", .group = "limits", .source = .session, .kind = .bar, .fact = "rate_limits.five_hour.used_percentage", .fmt = "pct", .rules = limit_rules, .icon = GAUGE, .color = 78, .name = "5h limit bar", .name_zh = "5 小时限额进度条" },
    .{ .id = "limit-5h-reset", .group = "limits", .source = .session, .kind = .countdown, .fact = "rate_limits.five_hour.resets_at", .fmt = "countdown", .icon = HOURGLASS, .color = 110, .name = "5h limit resets", .name_zh = "5 小时限额重置" },
    .{ .id = "limit-7d-pct", .group = "limits", .source = .session, .kind = .percent, .fact = "rate_limits.seven_day.used_percentage", .rules = limit_rules, .icon = GAUGE, .color = 78, .name = "7d limit %", .name_zh = "7 天限额 %" },
    .{ .id = "limit-7d-bar", .group = "limits", .source = .session, .kind = .bar, .fact = "rate_limits.seven_day.used_percentage", .fmt = "pct", .rules = limit_rules, .icon = GAUGE, .color = 78, .name = "7d limit bar", .name_zh = "7 天限额进度条" },
    .{ .id = "limit-7d-reset", .group = "limits", .source = .session, .kind = .countdown, .fact = "rate_limits.seven_day.resets_at", .fmt = "countdown", .icon = HOURGLASS, .color = 110, .name = "7d limit resets", .name_zh = "7 天限额重置" },
    .{ .id = "spend-pct", .group = "limits", .source = .session, .kind = .percent, .fact = "rate_limits.spend_limit.used_percentage", .rules = limit_rules, .icon = DOLLAR, .color = 78, .name = "Spend limit %", .name_zh = "消费限额 %", .since = "2.1.251" },
    .{ .id = "spend-used", .group = "limits", .source = .session, .kind = .money, .fact = "rate_limits.spend_limit.used_usd", .decimals = 2, .icon = DOLLAR, .color = 220, .name = "Spend used", .name_zh = "已消费", .since = "2.1.284" },
    .{ .id = "spend-limit", .group = "limits", .source = .session, .kind = .money, .fact = "rate_limits.spend_limit.limit_usd", .decimals = 0, .icon = DOLLAR, .color = 220, .name = "Spend limit", .name_zh = "消费上限", .since = "2.1.284" },

    // session
    .{ .id = "session-name", .group = "session", .source = .session, .kind = .text, .fact = "session_name", .icon = TEXT, .color = 252, .name = "Session name", .name_zh = "会话名称" },
    .{ .id = "session-id", .group = "session", .source = .session, .kind = .text, .fact = "session_id", .xform = .short, .icon = TEXT, .color = 244, .name = "Session ID", .name_zh = "会话 ID" },
    .{ .id = "version", .group = "session", .source = .session, .kind = .text, .fact = "version", .icon = CONSOLE, .color = 244, .name = "Claude Code version", .name_zh = "Claude Code 版本" },
    .{ .id = "vim-mode", .group = "session", .source = .session, .kind = .text, .fact = "vim.mode", .icon = CONSOLE, .color = 150, .name = "Vim mode", .name_zh = "Vim 模式" },

    // workspace
    .{ .id = "dir", .group = "workspace", .source = .session, .kind = .text, .fact = "workspace.current_dir", .xform = .dir, .icon = FOLDER, .color = 110, .name = "Directory", .name_zh = "当前目录" },
    .{ .id = "project-dir", .group = "workspace", .source = .session, .kind = .text, .fact = "workspace.project_dir", .xform = .dir, .icon = FOLDER, .color = 110, .name = "Project directory", .name_zh = "项目目录" },
    .{ .id = "added-dirs", .group = "workspace", .source = .session, .kind = .number, .fact = "workspace.added_dirs", .fmt = "raw", .suffix = " dirs", .icon = FOLDER, .color = 110, .name = "Added dirs", .name_zh = "附加目录数" },
    .{ .id = "repo", .group = "workspace", .source = .session, .kind = .text, .fact = "derived.repo", .icon = GITHUB, .color = 252, .name = "Repository", .name_zh = "仓库" },
    .{ .id = "worktree", .group = "workspace", .source = .session, .kind = .text, .fact = "derived.worktree", .icon = GIT, .color = 150, .name = "Worktree", .name_zh = "Worktree" },
    .{ .id = "pr", .group = "workspace", .source = .session, .kind = .pr, .fact = "pr.number", .icon = GITHUB, .color = 141, .name = "Pull request", .name_zh = "Pull request" },

    // turn (derived from the transcript, an internal format)
    .{ .id = "turn-time", .group = "turn", .source = .transcript, .kind = .duration, .fact = "tx.turn_s", .unit = .s, .fmt = "ms", .icon = TIMER, .color = 213, .name = "Turn time", .name_zh = "本轮耗时" },
    .{ .id = "speed", .group = "turn", .source = .transcript, .kind = .number, .fact = "tx.speed", .fmt = "raw", .suffix = " t/s", .icon = SPEED, .color = 156, .name = "Output speed", .name_zh = "输出速度" },
    .{ .id = "compactions", .group = "turn", .source = .transcript, .kind = .number, .fact = "tx.compactions", .fmt = "raw", .icon = COUNT, .color = 111, .name = "Compactions", .name_zh = "压缩次数" },
    .{ .id = "prompts", .group = "turn", .source = .transcript, .kind = .number, .fact = "tx.prompts", .fmt = "raw", .icon = TEXT, .color = 111, .name = "Prompts", .name_zh = "提问次数" },
    .{ .id = "tool-calls", .group = "turn", .source = .transcript, .kind = .number, .fact = "tx.tool_calls", .fmt = "raw", .icon = WRENCH, .color = 180, .name = "Tool calls (session)", .name_zh = "工具调用（会话）" },
    .{ .id = "turn-tool-calls", .group = "turn", .source = .transcript, .kind = .number, .fact = "tx.turn_tool_calls", .fmt = "raw", .icon = WRENCH, .color = 180, .name = "Tool calls (turn)", .name_zh = "工具调用（本轮）" },
    .{ .id = "last-tool", .group = "turn", .source = .transcript, .kind = .text, .fact = "tx.last_tool", .icon = WRENCH, .color = 180, .name = "Last tool", .name_zh = "最近工具" },
    .{ .id = "idle", .group = "turn", .source = .transcript, .kind = .duration, .fact = "tx.idle_s", .unit = .s, .fmt = "hm", .icon = HOURGLASS, .color = 244, .name = "Idle time", .name_zh = "空闲时长" },

    // git
    .{ .id = "git-branch", .group = "git", .source = .git, .kind = .text, .fact = "git.branch", .icon = BRANCH, .color = 150, .name = "Branch", .name_zh = "分支" },
    .{ .id = "git-sha", .group = "git", .source = .git, .kind = .text, .fact = "git.sha", .xform = .short, .icon = GIT, .color = 244, .name = "Commit", .name_zh = "提交哈希" },
    .{ .id = "git-dirty", .group = "git", .source = .git, .kind = .flag, .fact = "git.dirty", .on = "*", .icon = GIT, .color = 214, .name = "Dirty", .name_zh = "有未提交改动" },
    .{ .id = "git-staged", .group = "git", .source = .git, .kind = .number, .fact = "git.staged", .fmt = "raw", .icon = PLUS, .color = 78, .name = "Staged files", .name_zh = "已暂存文件" },
    .{ .id = "git-unstaged", .group = "git", .source = .git, .kind = .number, .fact = "git.unstaged", .fmt = "raw", .icon = GIT, .color = 214, .name = "Modified files", .name_zh = "未暂存文件" },
    .{ .id = "git-untracked", .group = "git", .source = .git, .kind = .number, .fact = "git.untracked", .fmt = "raw", .icon = GIT, .color = 244, .name = "Untracked files", .name_zh = "未跟踪文件" },
    .{ .id = "git-ahead", .group = "git", .source = .git, .kind = .number, .fact = "git.ahead", .fmt = "raw", .icon = UP, .color = 117, .name = "Ahead", .name_zh = "领先远端" },
    .{ .id = "git-behind", .group = "git", .source = .git, .kind = .number, .fact = "git.behind", .fmt = "raw", .icon = DOWN, .color = 209, .name = "Behind", .name_zh = "落后远端" },
    .{ .id = "git-stash", .group = "git", .source = .git, .kind = .number, .fact = "git.stash", .fmt = "raw", .icon = GIT, .color = 180, .name = "Stashes", .name_zh = "stash 数" },
    .{ .id = "git-diff-add", .group = "git", .source = .git, .kind = .number, .fact = "git.diff_add", .fmt = "raw", .icon = PLUS, .color = 78, .name = "Diff added", .name_zh = "改动新增行" },
    .{ .id = "git-diff-del", .group = "git", .source = .git, .kind = .number, .fact = "git.diff_del", .fmt = "raw", .icon = MINUS, .color = 203, .name = "Diff removed", .name_zh = "改动删除行" },
    .{ .id = "git-last-commit", .group = "git", .source = .git, .kind = .ago, .fact = "git.last_commit", .icon = CLOCK, .color = 244, .name = "Last commit", .name_zh = "上次提交距今" },
    .{ .id = "git-tag", .group = "git", .source = .git, .kind = .text, .fact = "git.tag", .icon = TAG, .color = 180, .name = "Nearest tag", .name_zh = "最近标签" },
    .{ .id = "git-upstream", .group = "git", .source = .git, .kind = .text, .fact = "git.upstream", .icon = UPSTREAM, .color = 110, .name = "Upstream", .name_zh = "上游分支" },
    .{ .id = "git-conflicts", .group = "git", .source = .git, .kind = .number, .fact = "git.conflicts", .fmt = "raw", .icon = CONFLICT, .color = 196, .name = "Conflicts", .name_zh = "冲突文件" },
    .{ .id = "git-worktrees", .group = "git", .source = .git, .kind = .number, .fact = "git.worktrees", .fmt = "raw", .icon = WORKTREES, .color = 150, .name = "Worktrees", .name_zh = "worktree 数" },
    .{ .id = "git-state", .group = "git", .source = .git, .kind = .text, .fact = "git.state", .icon = MERGE, .color = 209, .name = "Operation in progress", .name_zh = "进行中的操作" },

    // languages: shown when the directory (or a parent up to the repository root) has the
    // language's marker files; the version is the runtime on PATH, as the tools would run it
    .{ .id = "node", .group = "lang", .source = .project, .kind = .text, .fact = "lang.node", .icon = NODE, .color = 113, .name = "Node.js", .name_zh = "Node.js" },
    .{ .id = "bun", .group = "lang", .source = .project, .kind = .text, .fact = "lang.bun", .icon = BUN, .color = 223, .name = "Bun", .name_zh = "Bun" },
    .{ .id = "deno", .group = "lang", .source = .project, .kind = .text, .fact = "lang.deno", .icon = DENO, .color = 79, .name = "Deno", .name_zh = "Deno" },
    .{ .id = "python", .group = "lang", .source = .project, .kind = .text, .fact = "lang.python", .icon = PYTHON, .color = 221, .name = "Python", .name_zh = "Python" },
    .{ .id = "python-venv", .group = "lang", .source = .project, .kind = .text, .fact = "lang.venv", .icon = VENV, .color = 221, .name = "Python env", .name_zh = "Python 虚拟环境" },
    .{ .id = "go", .group = "lang", .source = .project, .kind = .text, .fact = "lang.go", .icon = GO, .color = 81, .name = "Go", .name_zh = "Go" },
    .{ .id = "rust", .group = "lang", .source = .project, .kind = .text, .fact = "lang.rust", .icon = RUST, .color = 209, .name = "Rust", .name_zh = "Rust" },
    .{ .id = "java", .group = "lang", .source = .project, .kind = .text, .fact = "lang.java", .icon = JAVA, .color = 167, .name = "Java", .name_zh = "Java" },
    .{ .id = "ruby", .group = "lang", .source = .project, .kind = .text, .fact = "lang.ruby", .icon = RUBY, .color = 160, .name = "Ruby", .name_zh = "Ruby" },
    .{ .id = "php", .group = "lang", .source = .project, .kind = .text, .fact = "lang.php", .icon = PHP, .color = 104, .name = "PHP", .name_zh = "PHP" },
    .{ .id = "swift", .group = "lang", .source = .project, .kind = .text, .fact = "lang.swift", .icon = SWIFT, .color = 208, .name = "Swift", .name_zh = "Swift" },
    .{ .id = "zig", .group = "lang", .source = .project, .kind = .text, .fact = "lang.zig", .icon = ZIG, .color = 214, .name = "Zig", .name_zh = "Zig" },
    .{ .id = "dotnet", .group = "lang", .source = .project, .kind = .text, .fact = "lang.dotnet", .icon = DOTNET, .color = 99, .name = ".NET SDK", .name_zh = ".NET SDK" },

    // package
    .{ .id = "pkg-name", .group = "project", .source = .project, .kind = .text, .fact = "proj.name", .icon = PACKAGE, .color = 252, .name = "Package name", .name_zh = "包名" },
    .{ .id = "pkg-version", .group = "project", .source = .project, .kind = .text, .fact = "proj.version", .icon = TAG_TEXT, .color = 180, .name = "Package version", .name_zh = "包版本" },
    .{ .id = "pkg-manager", .group = "project", .source = .project, .kind = .text, .fact = "proj.pm", .icon = PACKAGE_VARIANT, .color = 146, .name = "Package manager", .name_zh = "包管理器" },

    // cloud & environment: the context a CLI would act on, read from env vars and config files
    .{ .id = "k8s-context", .group = "cloud", .source = .cloud, .kind = .text, .fact = "cloud.k8s_context", .icon = K8S, .color = 69, .name = "Kubernetes context", .name_zh = "Kubernetes context" },
    .{ .id = "k8s-namespace", .group = "cloud", .source = .cloud, .kind = .text, .fact = "cloud.k8s_namespace", .icon = K8S, .color = 111, .name = "Kubernetes namespace", .name_zh = "Kubernetes 命名空间" },
    .{ .id = "docker-context", .group = "cloud", .source = .cloud, .kind = .text, .fact = "cloud.docker_context", .icon = DOCKER, .color = 39, .name = "Docker context", .name_zh = "Docker context" },
    .{ .id = "aws-profile", .group = "cloud", .source = .cloud, .kind = .text, .fact = "cloud.aws_profile", .icon = AWS, .color = 214, .name = "AWS profile", .name_zh = "AWS profile" },
    .{ .id = "aws-region", .group = "cloud", .source = .cloud, .kind = .text, .fact = "cloud.aws_region", .icon = AWS, .color = 180, .name = "AWS region", .name_zh = "AWS 区域" },
    .{ .id = "gcloud-project", .group = "cloud", .source = .cloud, .kind = .text, .fact = "cloud.gcloud_project", .icon = GCLOUD, .color = 75, .name = "Google Cloud project", .name_zh = "Google Cloud 项目" },
    .{ .id = "terraform", .group = "cloud", .source = .cloud, .kind = .text, .fact = "cloud.terraform", .icon = TERRAFORM, .color = 99, .name = "Terraform workspace", .name_zh = "Terraform workspace" },
    .{ .id = "nix-shell", .group = "cloud", .source = .cloud, .kind = .flag, .fact = "cloud.nix", .on = "nix", .icon = NIX, .color = 110, .name = "Nix shell", .name_zh = "Nix shell" },
    .{ .id = "ssh", .group = "cloud", .source = .cloud, .kind = .flag, .fact = "cloud.ssh", .on = "ssh", .icon = SSH, .color = 209, .name = "SSH session", .name_zh = "SSH 会话" },
    .{ .id = "container", .group = "cloud", .source = .cloud, .kind = .flag, .fact = "cloud.container", .on = "container", .icon = CUBE, .color = 39, .name = "In a container", .name_zh = "容器内" },

    // system
    .{ .id = "clock", .group = "system", .source = .system, .kind = .clock, .fmt = "%H:%M", .icon = CLOCK, .color = 252, .name = "Clock", .name_zh = "时钟" },
    .{ .id = "date", .group = "system", .source = .system, .kind = .clock, .fmt = "%m-%d %a", .icon = CALENDAR, .color = 252, .name = "Date", .name_zh = "日期" },
    .{ .id = "hostname", .group = "system", .source = .system, .kind = .text, .fact = "sys.hostname", .icon = SERVER, .color = 146, .name = "Hostname", .name_zh = "主机名" },
    .{ .id = "user", .group = "system", .source = .system, .kind = .text, .fact = "sys.user", .icon = USER, .color = 146, .name = "User", .name_zh = "用户名" },
    .{ .id = "load", .group = "system", .source = .system, .kind = .number, .fact = "sys.load1", .fmt = "raw", .decimals = 2, .icon = GAUGE, .color = 180, .name = "Load average", .name_zh = "系统负载" },
    .{ .id = "mem-avail", .group = "system", .source = .system, .kind = .percent, .fact = "sys.mem_avail", .icon = CHIP, .color = 117, .name = "Memory available", .name_zh = "可用内存 %" },
    .{ .id = "cpu", .group = "system", .source = .system, .kind = .percent, .fact = "sys.cpu", .rules = &[_][2]f64{ .{ 0, 78 }, .{ 60, 220 }, .{ 85, 203 } }, .icon = CPU, .color = 78, .name = "CPU usage", .name_zh = "CPU 占用" },
    .{ .id = "mem-used", .group = "system", .source = .system, .kind = .bytes, .fact = "sys.mem_used", .total = "sys.mem_total", .icon = MEMORY, .color = 117, .name = "Memory used", .name_zh = "已用内存" },
    .{ .id = "mem-used-pct", .group = "system", .source = .system, .kind = .percent, .fact = "sys.mem_used_pct", .rules = &[_][2]f64{ .{ 0, 78 }, .{ 75, 220 }, .{ 90, 203 } }, .icon = MEMORY, .color = 78, .name = "Memory used %", .name_zh = "内存占用 %" },
    .{ .id = "swap-used", .group = "system", .source = .system, .kind = .bytes, .fact = "sys.swap_used", .icon = SWAP, .color = 180, .name = "Swap used", .name_zh = "已用交换区" },
    .{ .id = "disk-free", .group = "system", .source = .system, .kind = .bytes, .fact = "sys.disk_free", .icon = HARDDISK, .color = 110, .name = "Disk free", .name_zh = "磁盘剩余" },
    .{ .id = "disk-used-pct", .group = "system", .source = .system, .kind = .percent, .fact = "sys.disk_used_pct", .rules = &[_][2]f64{ .{ 0, 78 }, .{ 80, 220 }, .{ 92, 203 } }, .icon = HARDDISK, .color = 78, .name = "Disk used %", .name_zh = "磁盘占用 %" },
    .{ .id = "fan", .group = "system", .source = .system, .kind = .number, .fact = "sys.fan", .fmt = "raw", .suffix = " rpm", .icon = FAN, .color = 117, .name = "Fan speed", .name_zh = "风扇转速" },
    .{ .id = "uptime", .group = "system", .source = .system, .kind = .duration, .fact = "sys.uptime", .unit = .s, .fmt = "compact", .icon = UPTIME, .color = 244, .name = "Uptime", .name_zh = "开机时长" },
    .{ .id = "battery", .group = "system", .source = .system, .kind = .percent, .fact = "sys.battery", .rules = &[_][2]f64{ .{ 0, 203 }, .{ 20, 220 }, .{ 50, 78 } }, .icon = BATTERY, .color = 78, .name = "Battery", .name_zh = "电量" },

    // disk usage: directory sizes are measured by a background process and cached,
    // so a refresh never waits on a directory walk; the first refresh shows nothing
    .{ .id = "dir-size", .group = "disk", .source = .disk, .kind = .bytes, .fact = "size.dir", .icon = FOLDER_SIZE, .color = 110, .name = "Directory size", .name_zh = "当前目录占用" },
    .{ .id = "node-modules", .group = "disk", .source = .disk, .kind = .bytes, .fact = "size.node_modules", .icon = NODE, .color = 113, .name = "node_modules", .name_zh = "node_modules" },
    .{ .id = "rust-target", .group = "disk", .source = .disk, .kind = .bytes, .fact = "size.rust_target", .icon = RUST, .color = 209, .name = "Rust target/", .name_zh = "Rust target 目录" },
    .{ .id = "go-cache", .group = "disk", .source = .disk, .kind = .bytes, .fact = "size.go_cache", .icon = GO, .color = 81, .name = "Go caches", .name_zh = "Go 构建与模块缓存" },
    .{ .id = "pods", .group = "disk", .source = .disk, .kind = .bytes, .fact = "size.pods", .icon = PACKAGE, .color = 208, .name = "CocoaPods Pods/", .name_zh = "iOS Pods 目录" },
    .{ .id = "xcode-derived", .group = "disk", .source = .disk, .kind = .bytes, .fact = "size.xcode_derived", .icon = SWIFT, .color = 75, .name = "Xcode DerivedData", .name_zh = "Xcode DerivedData" },
    .{ .id = "gradle-cache", .group = "disk", .source = .disk, .kind = .bytes, .fact = "size.gradle_cache", .icon = JAVA, .color = 114, .name = "Gradle caches (Android / Java)", .name_zh = "Gradle 缓存（Android / Java）" },
    .{ .id = "maven-repo", .group = "disk", .source = .disk, .kind = .bytes, .fact = "size.maven_repo", .icon = JAVA, .color = 167, .name = "Maven repository", .name_zh = "Maven 本地仓库" },

    // custom
    .{ .id = "text", .group = "custom", .source = .custom, .kind = .text, .icon = "", .color = 252, .name = "Static text", .name_zh = "静态文字" },
    .{ .id = "env", .group = "custom", .source = .custom, .kind = .text, .icon = "", .color = 252, .name = "Environment variable", .name_zh = "环境变量" },
    .{ .id = "command", .group = "custom", .source = .custom, .kind = .text, .icon = CONSOLE, .color = 252, .name = "Command output", .name_zh = "命令输出" },
};

pub fn find(id: []const u8) ?*const Def {
    for (&defs) |*d| {
        if (std.mem.eql(u8, d.id, id)) return d;
    }
    return null;
}

/// JSON form of the catalogue for the web editor.
pub fn writeJson(w: *std.Io.Writer) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("groups");
    try s.write(groups);
    try s.objectField("segments");
    try s.beginArray();
    for (defs) |d| {
        try s.beginObject();
        inline for (.{ "id", "group", "fact", "icon", "name", "name_zh", "fmt", "suffix", "on", "off", "used", "total", "gate", "since" }) |f| {
            const v = @field(d, f);
            if (v.len > 0) {
                try s.objectField(f);
                try s.write(v);
            }
        }
        try s.objectField("source");
        try s.write(@tagName(d.source));
        try s.objectField("kind");
        try s.write(@tagName(d.kind));
        try s.objectField("color");
        try s.write(d.color);
        if (d.off_color) |c| {
            try s.objectField("off_color");
            try s.write(c);
        }
        if (d.decimals > 0) {
            try s.objectField("decimals");
            try s.write(d.decimals);
        }
        if (d.rules.len > 0) {
            try s.objectField("rules");
            try s.write(d.rules);
        }
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("codex");
    try codex.writeJson(&s);
    try s.endObject();
}

test "ids are unique and groups exist" {
    for (defs, 0..) |a, i| {
        for (defs[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.id, b.id));
        var ok = false;
        for (groups) |g| ok = ok or std.mem.eql(u8, g.id, a.group);
        try std.testing.expect(ok);
    }
}
