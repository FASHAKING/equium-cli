#!/usr/bin/env bash
#
# Equium CLI miner — one-liner installer.
#
# Quick start:
#   curl -sSL https://raw.githubusercontent.com/HannaPrints/equium/main/scripts/install.sh | bash
#
# Builds the reference CLI miner from source and writes a wallet keypair +
# launch script into ~/.equium. Prompts for: private key (raw JSON array or
# base58 secret), RPC URL (defaults to mainnet-beta), optional thread count
# and max-blocks.
#
# Non-interactive overrides via env:
#   EQUIUM_PRIVATE_KEY   — Solana secret as base58 string or JSON byte array
#   EQUIUM_RPC_URL       — RPC endpoint (default: https://api.mainnet-beta.solana.com)
#   EQUIUM_THREADS       — solver threads (default: 0 = all cores)
#   EQUIUM_MAX_BLOCKS    — stop after N blocks (default: 0 = forever)
#   EQUIUM_REPO          — git remote (default: https://github.com/HannaPrints/equium.git)
#   EQUIUM_REF           — branch/tag/sha to build (default: main)
#   EQUIUM_HOME          — install dir (default: ~/.equium)
#   EQUIUM_NO_RUN=1      — install only, don't launch the miner
#   EQUIUM_YES=1         — accept all defaults, no prompts

set -euo pipefail

EQUIUM_HOME="${EQUIUM_HOME:-$HOME/.equium}"
EQUIUM_REPO="${EQUIUM_REPO:-https://github.com/HannaPrints/equium.git}"
EQUIUM_REF="${EQUIUM_REF:-main}"
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

# When piped (curl | bash), stdin is the pipe — read prompts from /dev/tty.
if [ -t 0 ]; then TTY=/dev/stdin; else TTY=/dev/tty; fi
prompt_ok() { [ -e "$TTY" ] && [ -z "${EQUIUM_YES:-}" ]; }

ask() {
  # ask VAR "Question" "default"
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
  # ask_secret VAR "Question"
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

# ── prereqs ──────────────────────────────────────────────────────────────────
say "checking prerequisites"

need() { command -v "$1" >/dev/null 2>&1; }

if ! need cargo; then
  warn "rustc/cargo not found — installing rustup (stable toolchain)"
  if ! need curl; then die "curl is required to install rustup"; fi
  curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
fi
need cargo || die "cargo still not on PATH; re-open your shell and rerun"
need git   || die "git is required (install via your package manager)"
need cc || need gcc || need clang || die "a C compiler is required (apt: build-essential · brew: xcode-select --install · dnf: gcc)"

ok "toolchain ready ($(cargo --version))"

# ── prompt for config ────────────────────────────────────────────────────────
PRIVATE_KEY="${EQUIUM_PRIVATE_KEY:-}"
if [ -z "$PRIVATE_KEY" ]; then
  printf "\n${C_GOLD}Wallet${C_RESET} — paste a Solana secret key.\n"
  printf "${C_DIM}Accepts either a base58 string (Phantom/Solflare export) or a JSON byte array (id.json).${C_RESET}\n"
  ask_secret PRIVATE_KEY "private key"
fi
[ -n "$PRIVATE_KEY" ] || die "private key is required"

RPC_URL="${EQUIUM_RPC_URL:-}"
if [ -z "$RPC_URL" ]; then
  printf "\n${C_GOLD}RPC${C_RESET} — Solana endpoint. Public mainnet rate-limits hard; a free Helius key is recommended.\n"
  ask RPC_URL "rpc url" "$DEFAULT_RPC"
fi
RPC_URL="${RPC_URL:-$DEFAULT_RPC}"

# Threads: default to 0, which the miner resolves to all available cores.
# Overridable via EQUIUM_THREADS if you want to leave headroom for other work.
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
  # Read $PRIVATE_KEY (env), write a Solana JSON byte array to $KEYPAIR_FILE.
  # Accepts either a JSON array of 64 bytes or a base58-encoded 64-byte secret.
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

if ! need python3; then die "python3 is required to parse the private key"; fi
PRIVATE_KEY="$PRIVATE_KEY" normalize_key >/dev/null || die "failed to parse private key"
chmod 600 "$KEYPAIR_FILE"
ok "wallet written to $KEYPAIR_FILE (mode 600)"

# ── build (or reuse cached source) ──────────────────────────────────────────
SRC_DIR="$EQUIUM_HOME/src"
if [ -d "$SRC_DIR/.git" ]; then
  say "updating sources in $SRC_DIR"
  git -C "$SRC_DIR" fetch --depth 1 origin "$EQUIUM_REF" \
    || git -C "$SRC_DIR" fetch origin
  git -C "$SRC_DIR" checkout -q FETCH_HEAD 2>/dev/null \
    || git -C "$SRC_DIR" checkout -q "$EQUIUM_REF"
else
  say "cloning $EQUIUM_REPO@$EQUIUM_REF → $SRC_DIR"
  # Try shallow-clone the ref as a branch/tag first; fall back to full clone +
  # checkout for arbitrary SHAs.
  if ! git clone --depth 1 --branch "$EQUIUM_REF" "$EQUIUM_REPO" "$SRC_DIR" 2>/dev/null; then
    git clone "$EQUIUM_REPO" "$SRC_DIR"
    git -C "$SRC_DIR" checkout -q "$EQUIUM_REF"
  fi
fi

say "building equium-miner (this takes a few minutes on first run)"
( cd "$SRC_DIR" && cargo build -p equium-cli-miner --release )

BIN_SRC="$SRC_DIR/target/release/equium-miner"
BIN_DST="$EQUIUM_HOME/bin/equium-miner"
mkdir -p "$EQUIUM_HOME/bin"
install -m 0755 "$BIN_SRC" "$BIN_DST"
ok "installed $BIN_DST"

# ── persist config + launch script ──────────────────────────────────────────
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

RUN_SCRIPT="$EQUIUM_HOME/bin/equium"
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

printf "\n${C_SAGE}${C_BOLD}done.${C_RESET} add ${C_BOLD}%s${C_RESET} to your PATH or run directly:\n" "$EQUIUM_HOME/bin"
printf "  ${C_BOLD}%s${C_RESET}\n\n" "$RUN_SCRIPT"

if [ -z "${EQUIUM_NO_RUN:-}" ] && prompt_ok; then
  ask START_NOW "start mining now? (y/N)" "n"
  case "$START_NOW" in
    y|Y|yes|YES) exec "$RUN_SCRIPT" ;;
    *) say "skipping launch — run \`$RUN_SCRIPT\` whenever you're ready" ;;
  esac
fi
