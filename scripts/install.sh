#!/usr/bin/env bash
#
# Equium CLI miner — one-liner installer.
#
# Quick start:
#   curl -sSL https://raw.githubusercontent.com/FASHAKING/equium-cli/master/scripts/install.sh | bash
#
# Downloads a prebuilt equium-miner binary from the latest GitHub Release,
# verifies its SHA-256, and writes a wallet keypair + launcher into ~/.equium.
# Prompts for: private key (raw JSON array or base58 secret), RPC URL
# (defaults to mainnet-beta), and optional max-blocks. Threads default to 0
# (= all CPU cores at runtime).
#
# Non-interactive overrides via env:
#   EQUIUM_PRIVATE_KEY        — Solana secret as base58 string or JSON byte array
#   EQUIUM_RPC_URL            — RPC endpoint (default: https://api.mainnet-beta.solana.com)
#   EQUIUM_THREADS            — solver threads (default: 0 = all cores)
#   EQUIUM_MAX_BLOCKS         — stop after N blocks (default: 0 = forever)
#   EQUIUM_HOME               — install dir (default: ~/.equium)
#   EQUIUM_NO_RUN=1           — install only, don't launch the miner
#   EQUIUM_YES=1              — accept all defaults, no prompts
#
# Binary-download path (default):
#   EQUIUM_REPO_SLUG          — GitHub owner/repo (default: FASHAKING/equium-cli)
#   EQUIUM_RELEASE_TAG        — release tag to install (default: latest)
#
# Source-build fallback:
#   EQUIUM_BUILD_FROM_SOURCE=1 — compile from source instead of downloading
#   EQUIUM_REPO               — git remote (default: https://github.com/FASHAKING/equium-cli.git)
#   EQUIUM_REF                — branch/tag/sha to build (default: master)

set -euo pipefail

EQUIUM_HOME="${EQUIUM_HOME:-$HOME/.equium}"
EQUIUM_REPO_SLUG="${EQUIUM_REPO_SLUG:-FASHAKING/equium-cli}"
EQUIUM_RELEASE_TAG="${EQUIUM_RELEASE_TAG:-latest}"
EQUIUM_REPO="${EQUIUM_REPO:-https://github.com/${EQUIUM_REPO_SLUG}.git}"
EQUIUM_REF="${EQUIUM_REF:-master}"
DEFAULT_RPC="https://api.mainnet-beta.solana.com"

if [ -t 1 ]; then
  C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
  C_ROSE='\033[35m'; C_GOLD='\033[33m'; C_SAGE='\033[32m'; C_RED='\033[31m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_ROSE=''; C_GOLD=''; C_SAGE=''; C_RED=''
fi

say()  { printf "${C_ROSE}equium${C_RESET} ${C_DIM}·${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_SAGE}✓${C_RESET} %s\n" "$*"; }
warn() { printf "${C_GOLD}!${C_RESET} %s\n" "$*" >&2; }
die()  { printf "${C_RED}✗${C_RESET} %s\n" "$*" >&2; exit 1; }

if [ -t 0 ]; then TTY=/dev/stdin; else TTY=/dev/tty; fi
prompt_ok() { [ -e "$TTY" ] && [ -z "${EQUIUM_YES:-}" ]; }

ask() {
  local __var="$1" __q="$2" __default="${3:-}" __reply=""
  if ! prompt_ok; then
    printf -v "$__var" '%s' "$__default"; return
  fi
  if [ -n "$__default" ]; then
    printf "${C_BOLD}?${C_RESET} %s ${C_DIM}[%s]${C_RESET}: " "$__q" "$__default" > /dev/tty
  else
    printf "${C_BOLD}?${C_RESET} %s: " "$__q" > /dev/tty
  fi
  IFS= read -r __reply < "$TTY" || true
  printf -v "$__var" '%s' "${__reply:-$__default}"
}

ask_secret() {
  local __var="$1" __q="$2" __reply=""
  if ! prompt_ok; then
    printf -v "$__var" '%s' ""; return
  fi
  printf "${C_BOLD}?${C_RESET} %s ${C_DIM}(input hidden)${C_RESET}: " "$__q" > /dev/tty
  stty -echo < "$TTY" 2>/dev/null || true
  IFS= read -r __reply < "$TTY" || true
  stty echo < "$TTY" 2>/dev/null || true
  printf "\n" > /dev/tty
  printf -v "$__var" '%s' "$__reply"
}

need() { command -v "$1" >/dev/null 2>&1; }

# ── banner ───────────────────────────────────────────────────────────────────
printf "\n${C_ROSE}${C_BOLD}"
cat <<'EOF'
   ███████╗ ██████╗ ██╗   ██╗██╗██╗   ██╗███╗   ███╗
   ██╔════╝██╔═══██╗██║   ██║██║██║   ██║████╗ ████║
   █████╗  ██║   ██║██║   ██║██║██║   ██║██╔████╔██║
   ██╔══╝  ██║▄▄ ██║██║   ██║██║██║   ██║██║╚██╔╝██║
   ███████╗╚██████╔╝╚██████╔╝██║╚██████╔╝██║ ╚═╝ ██║
   ╚══════╝ ╚══▀▀═╝  ╚═════╝ ╚═╝ ╚═════╝ ╚═╝     ╚═╝
EOF
printf "${C_RESET}${C_DIM}   CPU-mineable token on Solana — CLI installer${C_RESET}\n\n"

# ── platform detection ──────────────────────────────────────────────────────
detect_platform_label() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Linux)
      case "$arch" in
        x86_64|amd64) echo "linux-x64" ;;
        *) echo "" ;;
      esac
      ;;
    Darwin)
      case "$arch" in
        arm64|aarch64) echo "macos-arm64" ;;
        x86_64) echo "macos-x64" ;;
        *) echo "" ;;
      esac
      ;;
    *) echo "" ;;
  esac
}

PLATFORM_LABEL="$(detect_platform_label)"

# ── prompt for config (same regardless of install path) ────────────────────
PRIVATE_KEY="${EQUIUM_PRIVATE_KEY:-}"
if [ -z "$PRIVATE_KEY" ]; then
  printf "${C_GOLD}Wallet${C_RESET} — paste a Solana secret key.\n"
  printf "${C_DIM}Accepts a base58 string (Phantom/Solflare export) or a JSON byte array (id.json).${C_RESET}\n"
  ask_secret PRIVATE_KEY "private key"
fi
[ -n "$PRIVATE_KEY" ] || die "private key is required"

RPC_URL="${EQUIUM_RPC_URL:-}"
if [ -z "$RPC_URL" ]; then
  printf "\n${C_GOLD}RPC${C_RESET} — Solana endpoint. Public mainnet rate-limits hard; a free Helius key is recommended.\n"
  ask RPC_URL "rpc url" "$DEFAULT_RPC"
fi
RPC_URL="${RPC_URL:-$DEFAULT_RPC}"

# Threads default to 0 → miner uses all logical cores at runtime.
THREADS="${EQUIUM_THREADS:-0}"
case "$THREADS" in ''|*[!0-9]*) die "EQUIUM_THREADS must be a non-negative integer";; esac

MAX_BLOCKS="${EQUIUM_MAX_BLOCKS:-}"
if [ -z "$MAX_BLOCKS" ]; then
  ask MAX_BLOCKS "stop after N blocks (0 = run forever)" "0"
fi
case "$MAX_BLOCKS" in ''|*[!0-9]*) die "max-blocks must be a non-negative integer";; esac

# ── normalize key → keypair JSON ─────────────────────────────────────────────
mkdir -p "$EQUIUM_HOME"
KEYPAIR_FILE="$EQUIUM_HOME/wallet.json"

normalize_key() {
  python3 - "$KEYPAIR_FILE" <<'PY'
import json, os, sys, re
raw = os.environ["PRIVATE_KEY"].strip()
out_path = sys.argv[1]
def b58decode(s):
    alphabet = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    n = 0
    for ch in s.encode():
        i = alphabet.find(bytes([ch]))
        if i < 0:
            raise ValueError(f"invalid base58 char: {chr(ch)!r}")
        n = n * 58 + i
    full = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    pad = 0
    for ch in s:
        if ch == "1": pad += 1
        else: break
    return b"\x00" * pad + full
if raw.startswith("["):
    arr = json.loads(raw)
    if not isinstance(arr, list) or not all(isinstance(x, int) and 0 <= x < 256 for x in arr):
        sys.exit("private key JSON must be an array of bytes 0..255")
    data = bytes(arr)
elif re.fullmatch(r"[1-9A-HJ-NP-Za-km-z]+", raw):
    data = b58decode(raw)
else:
    sys.exit("unrecognized key format — expected JSON array or base58 string")
if len(data) == 32:
    sys.exit("got 32 bytes — that's a seed/public key, not a 64-byte secret. Export the full secret key.")
if len(data) != 64:
    sys.exit(f"expected 64-byte secret key, got {len(data)} bytes")
with open(out_path, "w") as f:
    json.dump(list(data), f)
os.chmod(out_path, 0o600)
print("ok")
PY
}

need python3 || die "python3 is required to parse the private key"
PRIVATE_KEY="$PRIVATE_KEY" normalize_key >/dev/null || die "failed to parse private key"
chmod 600 "$KEYPAIR_FILE"
ok "wallet written to $KEYPAIR_FILE (mode 600)"
unset PRIVATE_KEY

# ── install path: download prebuilt OR build from source ────────────────────
BIN_DIR="$EQUIUM_HOME/bin"
BIN_DST="$BIN_DIR/equium-miner"
mkdir -p "$BIN_DIR"

# Pick the URL prefix for the chosen release tag.
release_asset_url() {
  local asset="$1"
  if [ "$EQUIUM_RELEASE_TAG" = "latest" ]; then
    echo "https://github.com/${EQUIUM_REPO_SLUG}/releases/latest/download/${asset}"
  else
    echo "https://github.com/${EQUIUM_REPO_SLUG}/releases/download/${EQUIUM_RELEASE_TAG}/${asset}"
  fi
}

verify_sha256() {
  local file="$1" expected_line="$2"
  local actual
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$file" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  fi
  local expected
  expected="$(echo "$expected_line" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || die "checksum mismatch: expected $expected, got $actual"
}

install_from_release() {
  need curl || die "curl is required to download the release"
  need tar  || die "tar is required to extract the release"
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
    || die "sha256sum or shasum is required to verify the download"

  local asset="equium-miner-${PLATFORM_LABEL}.tar.gz"
  local url; url="$(release_asset_url "$asset")"
  local sha_url; sha_url="$(release_asset_url "${asset}.sha256")"

  say "downloading prebuilt miner: $asset"
  local tmpdir; tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN
  if ! curl -fsSL -o "$tmpdir/$asset" "$url"; then
    return 1
  fi
  if ! curl -fsSL -o "$tmpdir/$asset.sha256" "$sha_url"; then
    warn "no .sha256 sidecar published — skipping checksum verification"
  else
    verify_sha256 "$tmpdir/$asset" "$(cat "$tmpdir/$asset.sha256")"
    ok "sha256 verified"
  fi

  tar -xzf "$tmpdir/$asset" -C "$tmpdir"
  local extracted="$tmpdir/equium-miner-${PLATFORM_LABEL}/equium-miner"
  [ -f "$extracted" ] || die "expected $extracted in the tarball"
  install -m 0755 "$extracted" "$BIN_DST"
  ok "installed $BIN_DST"
}

install_from_source() {
  say "building from source (this takes a few minutes on first run)"
  need git || die "git is required (install via your package manager)"
  need cc || need gcc || need clang \
    || die "a C compiler is required (apt: build-essential · brew: xcode-select --install · dnf: gcc)"
  if ! need cargo; then
    warn "rustc/cargo not found — installing rustup (stable toolchain)"
    need curl || die "curl is required to install rustup"
    curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
  fi
  need cargo || die "cargo still not on PATH; re-open your shell and rerun"

  local src_dir="$EQUIUM_HOME/src"
  if [ -d "$src_dir/.git" ]; then
    say "updating sources in $src_dir"
    git -C "$src_dir" fetch --depth 1 origin "$EQUIUM_REF" \
      || git -C "$src_dir" fetch origin
    git -C "$src_dir" checkout -q FETCH_HEAD 2>/dev/null \
      || git -C "$src_dir" checkout -q "$EQUIUM_REF"
  else
    say "cloning $EQUIUM_REPO@$EQUIUM_REF → $src_dir"
    if ! git clone --depth 1 --branch "$EQUIUM_REF" "$EQUIUM_REPO" "$src_dir" 2>/dev/null; then
      git clone "$EQUIUM_REPO" "$src_dir"
      git -C "$src_dir" checkout -q "$EQUIUM_REF"
    fi
  fi

  ( cd "$src_dir" && cargo build -p equium-cli-miner --release )
  install -m 0755 "$src_dir/target/release/equium-miner" "$BIN_DST"
  ok "installed $BIN_DST"
}

if [ "${EQUIUM_BUILD_FROM_SOURCE:-0}" = "1" ]; then
  say "EQUIUM_BUILD_FROM_SOURCE=1 — building from source"
  install_from_source
elif [ -z "$PLATFORM_LABEL" ]; then
  warn "no prebuilt binary for $(uname -s)/$(uname -m) — falling back to source build"
  install_from_source
else
  if ! install_from_release; then
    warn "release download failed — falling back to source build"
    install_from_source
  fi
fi

# ── persist config + launcher ───────────────────────────────────────────────
CONFIG_FILE="$EQUIUM_HOME/config.env"
umask 077
cat > "$CONFIG_FILE" <<EOF
# equium miner config — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
EQUIUM_RPC_URL="$RPC_URL"
EQUIUM_KEYPAIR="$KEYPAIR_FILE"
EQUIUM_THREADS="$THREADS"
EQUIUM_MAX_BLOCKS="$MAX_BLOCKS"
EOF
ok "config saved to $CONFIG_FILE"

RUN_SCRIPT="$BIN_DIR/equium"
cat > "$RUN_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$HERE/config.env"
exec "$HERE/bin/equium-miner" \
  --rpc-url "$EQUIUM_RPC_URL" \
  --keypair "$EQUIUM_KEYPAIR" \
  --threads "$EQUIUM_THREADS" \
  --max-blocks "$EQUIUM_MAX_BLOCKS" \
  "$@"
EOF
chmod 0755 "$RUN_SCRIPT"
ok "launcher: $RUN_SCRIPT"

printf "\n${C_SAGE}${C_BOLD}done.${C_RESET} add ${C_BOLD}%s${C_RESET} to your PATH or run directly:\n" "$BIN_DIR"
printf "  ${C_BOLD}%s${C_RESET}\n\n" "$RUN_SCRIPT"

if [ -z "${EQUIUM_NO_RUN:-}" ] && prompt_ok; then
  ask START_NOW "start mining now? (y/N)" "n"
  case "$START_NOW" in
    y|Y|yes|YES) exec "$RUN_SCRIPT" ;;
    *) say "skipping launch — run \`$RUN_SCRIPT\` whenever you're ready" ;;
  esac
fi
