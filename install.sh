#!/usr/bin/env bash
# =============================================================================
# install.sh — installer for torrd.sh
#
# Usage (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/Kishan-Agarwal-28/torrd/main/install.sh | sudo bash
#
# Or with arguments passed through to torrd.sh after install:
#   curl -fsSL https://raw.githubusercontent.com/Kishan-Agarwal-28/torrd/main/install.sh \
#     | sudo bash -s -- --site /path/to/site --vanity mysite
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REPO_RAW="https://raw.githubusercontent.com/Kishan-Agarwal-28/torrd/main"
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="torrd.sh"
INSTALL_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[torrd installer]${RESET} $*"; }
success() { echo -e "${GREEN}[torrd installer]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[torrd installer]${RESET} $*"; }
die()     { echo -e "${RED}[torrd installer]${RESET} $*" >&2; exit 1; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Please run as root:  curl ... | sudo bash"

# ── Dependency check ──────────────────────────────────────────────────────────
info "Checking dependencies …"
for cmd in curl bash; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
done

# ── OS check ─────────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu|linuxmint|pop|kali|raspbian) : ;;  # supported
        *) warn "Unsupported OS '${ID:-unknown}'. torrd.sh targets Debian/Ubuntu." ;;
    esac
else
    warn "Cannot detect OS. Proceeding anyway."
fi

# ── Download ──────────────────────────────────────────────────────────────────
info "Downloading ${SCRIPT_NAME} …"

TMP="$(mktemp /tmp/torrd.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

HTTP_CODE="$(curl -fsSL \
    --retry 3 --retry-delay 2 \
    -w "%{http_code}" \
    -o "$TMP" \
    "${REPO_RAW}/${SCRIPT_NAME}")"

if [[ "$HTTP_CODE" != "200" ]]; then
    die "Download failed (HTTP ${HTTP_CODE}). Check the URL or your internet connection."
fi

# ── Sanity check the downloaded file ─────────────────────────────────────────
info "Verifying download …"
head -1 "$TMP" | grep -q "bash" \
    || die "Downloaded file does not look like a bash script. Aborting."
bash -n "$TMP" \
    || die "Downloaded script has syntax errors. Aborting."

# ── Install ───────────────────────────────────────────────────────────────────
info "Installing to ${INSTALL_PATH} …"
install -m 755 "$TMP" "$INSTALL_PATH"
success "${SCRIPT_NAME} installed to ${INSTALL_PATH}"

# ── PATH reminder ─────────────────────────────────────────────────────────────
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    warn "${INSTALL_DIR} is not in your PATH. You may need to:"
    warn "  export PATH=\"\$PATH:${INSTALL_DIR}\""
fi

# ── Done or auto-run ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════${RESET}"
echo -e "${BOLD} torrd.sh installed successfully!${RESET}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════${RESET}"
echo ""

# If arguments were passed after `-- ...`, run torrd.sh with them now
if [[ $# -gt 0 ]]; then
    info "Arguments detected — running: ${SCRIPT_NAME} $*"
    echo ""
    exec "$INSTALL_PATH" "$@"
else
    echo -e "  Run it:  ${BOLD}sudo torrd.sh --help${RESET}"
    echo -e "  Example: ${BOLD}sudo torrd.sh --site /path/to/mysite${RESET}"
    echo -e "  Vanity:  ${BOLD}sudo torrd.sh --site /path/to/mysite --vanity mysite${RESET}"
    echo ""
fi