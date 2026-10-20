#!/bin/sh
# omnitt-statusline installer · https://github.com/imatrixme/statusline
#
# Downloads the renderer for this machine from the GitHub Release below, checks it
# against the sha256 written into this file, installs it to ~/.claude/bin, then runs
# `omnitt-statusline setup`, which prints every change it makes to your settings.
#
#   curl -fsSL https://omnitt.com/statusline/install.sh | sh -s -- '<config code>'
#
# Without a config code the default layout is installed. Undo: omnitt-statusline uninstall
#
# The release workflow fills in the version and checksums below; this file in the
# repository is the template and refuses to run.
set -eu

VERSION=@VERSION@
SHA256_darwin_arm64=@SHA256_darwin_arm64@
SHA256_darwin_x64=@SHA256_darwin_x64@
SHA256_linux_arm64=@SHA256_linux_arm64@
SHA256_linux_x64=@SHA256_linux_x64@

die() { echo "omnitt-statusline: $*" >&2; exit 1; }

case $VERSION in @*) die "this is the unreleased template; use install.sh from a release" ;; esac

case $(uname -s) in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) die "unsupported OS: $(uname -s)" ;;
esac
case $(uname -m) in
    arm64 | aarch64) arch=arm64 ;;
    x86_64 | amd64) arch=x64 ;;
    *) die "unsupported CPU: $(uname -m)" ;;
esac
eval "expected=\$SHA256_${os}_${arch}"

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/bin
bin=$dir/omnitt-statusline
mkdir -p "$dir"

if [ -f "$bin" ] && [ "$(sha256 "$bin")" = "$expected" ]; then
    echo "omnitt-statusline $VERSION already installed at $bin"
else
    url=https://github.com/imatrixme/statusline/releases/download/v$VERSION/omnitt-statusline-$os-$arch
    tmp=$bin.download.$$
    trap 'rm -f "$tmp"' EXIT
    echo "Downloading $url"
    curl -fsSL --proto '=https' -o "$tmp" "$url" || die "download failed"
    actual=$(sha256 "$tmp")
    [ "$actual" = "$expected" ] || die "sha256 mismatch (expected $expected, got $actual); nothing was installed"
    chmod 755 "$tmp"
    mv -f "$tmp" "$bin"
    echo "Installed $bin (sha256 $actual)"
fi

echo
exec "$bin" setup "$@"
