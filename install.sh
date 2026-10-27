#!/bin/sh
# Install the latest query release:
#   curl -fsSL https://raw.githubusercontent.com/R44VC0RP/query/main/install.sh | sh
# Installs to ~/.local/bin; set QUERY_INSTALL_DIR to choose another folder.
set -eu

repo="R44VC0RP/query"
dir="${QUERY_INSTALL_DIR:-$HOME/.local/bin}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "query runs on macOS only." >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading query..."
curl -fsSL "https://github.com/$repo/releases/latest/download/query-macos.tar.gz" | tar -xz -C "$tmp"

mkdir -p "$dir"
install -m 755 "$tmp/query" "$dir/query"
xattr -d com.apple.quarantine "$dir/query" 2>/dev/null || true

echo "Installed $dir/query"
case ":$PATH:" in
  *":$dir:"*) ;;
  *) echo "Add $dir to your PATH, for example: echo 'export PATH=\"$dir:\$PATH\"' >> ~/.zshrc" ;;
esac
