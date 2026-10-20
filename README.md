# omnitt-statusline

A configurable status line for [Claude Code](https://docs.claude.com/en/docs/claude-code/statusline): about 80 segments in 12 groups (model, context window, tokens, prompt cache, cost and time, rate limits, session, transcript activity, git, workspace, system, custom). Each segment's icon, label, colors, number format, thresholds and progress-bar style can be changed, segments can be dragged into any order over several lines, and the plain and powerline layouts both adapt to the terminal width.

Design it visually at **https://omnitt.com/statusline**. The page gives you a config code; one command installs it.

**Codex CLI.** Codex cannot run a status line command; it only shows its own built-in items, chosen and ordered in `~/.codex/config.toml`. The same config code can include a Codex selection, and `setup` writes it there. See [Codex](#codex).

## Install

```sh
curl -fsSL https://omnitt.com/statusline/install.sh | sh -s -- '<config code>'
```

Without a config code you get the default layout. The installer:

1. picks the binary for your OS and CPU (macOS / Linux, arm64 / x64);
2. downloads it from this repository's GitHub Release;
3. checks it against the sha256 written into the installer, and stops on any mismatch;
4. installs it to `~/.claude/bin/omnitt-statusline`;
5. runs `omnitt-statusline setup`. Setup prints the decoded config, writes `~/.config/omnitt-statusline/config.json`, backs up `~/.claude/settings.json`, changes only its `statusLine` key, and prints every change it made.

Undo everything:

```sh
~/.claude/bin/omnitt-statusline uninstall
```

This restores your previous `statusLine` and removes the binary and its config. The `settings.json` backups are kept.

## Why you can trust the binary

| What | Guarantee | Check it yourself |
|---|---|---|
| Source | MIT, no network code, no auto-update | Read `src/`; `std.net` and `std.http` appear nowhere |
| Build | Built only by [the release workflow](.github/workflows/release.yml), from the tagged commit, with pinned actions | `gh attestation verify <file> --repo imatrixme/statusline` |
| Reproducible | Same Zig version and flags give byte-identical binaries | `zig build -Dtarget=<target> -Doptimize=ReleaseFast`, then compare against `SHA256SUMS` |
| Integrity | The installer pins each platform's sha256 | Compare with the Release's `SHA256SUMS` |
| Footprint | Writes only its binary, its config, the `statusLine` key, Codex's two `[tui]` status line keys, and backups | The change list printed by `setup` |

The omnitt.com installer is byte-identical to the `install.sh` in the Release. You can use the Release copy directly:

```sh
curl -fsSL https://github.com/imatrixme/statusline/releases/latest/download/install.sh | sh -s -- '<config code>'
```

A config that contains `command` segments (shell commands run on every refresh) lists each command and asks before installing it. Without a terminal to ask on, those segments are dropped.

## Codex

Codex (0.163.0) reads `[tui] status_line`, an ordered list of built-in item ids, and `status_line_use_colors`, which switches theme colours on or off. Icons, labels, colours, bars and custom segments are not possible there. A config can carry a Codex part:

```json
{ "v": 1, "lines": [...], "codex": { "items": ["model-with-reasoning", "git-branch", "context-used"], "colors": true } }
```

Either part may be left out; setup only touches the tools the config names. For Codex it:

- skips Codex entirely when `~/.codex` (or `$CODEX_HOME`) does not exist;
- drops item ids Codex `0.163.0` does not know, which Codex would otherwise warn about on every start;
- backs up `config.toml` and changes only those two keys under `[tui]`, adding the table if needed. Every other byte stays as it was, except a trailing comment on those two lines;
- leaves the file alone if `tui` is written as an inline table or with dotted keys, and prints the two lines to add by hand.

`uninstall` puts both keys back exactly as they were. `omnitt-statusline registry` lists the Codex items and which of our segments each one corresponds to.

## Commands

| Command | Does |
|---|---|
| `omnitt-statusline` | Render: reads Claude Code's JSON on stdin (what `statusLine` runs) |
| `setup [code]` | Install a config code (default layout without one) for Claude Code and/or Codex |
| `decode <code>` | Print the JSON inside a config code without installing it |
| `edit` | Print an editor link preloaded with your current config |
| `doctor` | Timing per collector, and why each hidden segment is hidden |
| `uninstall` | Restore the previous status line (Claude Code and Codex) and remove everything |
| `registry` | Print the segment catalog as JSON |

The config is plain JSON at `~/.config/omnitt-statusline/config.json` (or `$XDG_CONFIG_HOME/omnitt-statusline/`). You can edit it by hand.

## Build

Requires Zig 0.15.2.

```sh
zig build test
zig build -Doptimize=ReleaseFast        # zig-out/bin/omnitt-statusline
zig build wasm                          # zig-out/wasm/render.wasm, the renderer behind the web preview
```

The web preview runs the same renderer compiled to WebAssembly. Given the same config and input, it produces byte-identical output to the native binary.

Release targets: `aarch64-macos`, `x86_64-macos`, `aarch64-linux-musl`, `x86_64-linux-musl`. Linux binaries are static.

## License

MIT
