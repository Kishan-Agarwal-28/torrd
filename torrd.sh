#!/usr/bin/env bash
# =============================================================================
# torrd.sh — Deploy a static site as a Tor hidden service
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
cat <<EOF
${BOLD}tor-deploy.sh${RESET} — Deploy a static website as a Tor hidden service

${BOLD}USAGE${RESET}
  sudo ./tor-deploy.sh --site <path> [OPTIONS]

${BOLD}REQUIRED${RESET}
  --site <path>          Path to your website folder (HTML/CSS/JS, etc.)

${BOLD}OPTIONS${RESET}
  --vanity <prefix>      Mine a vanity .onion address starting with <prefix>.
                         Omit to use the auto-generated address.
                         WARNING: longer prefixes take exponentially more time.
                           ≤4 chars  → seconds
                           5 chars   → minutes
                           6 chars   → hours
                           7+ chars  → days/weeks

  --hs-dir <path>        Tor hidden service directory.
                         Default: /var/lib/tor/hidden_service

  --threads <n>          CPU threads for vanity mining.
                         Default: all available cores ($(nproc))

  --port <n>             Local port nginx listens on (must match torrc).
                         Default: 80

  --out <file>           File to write the final .onion address to.
                         Default: ./onion_address.txt

  --skip-nginx           Skip nginx install/config (use if you already have a
                         web server running on --port).

  --skip-tor-repo        Skip adding the Tor Project apt repo (use the distro
                         package instead).

  --yes                  Non-interactive: skip all confirmation prompts.

  -h, --help             Show this help and exit.

${BOLD}EXAMPLES${RESET}
  # Minimal — auto-generated .onion
  sudo ./tor-deploy.sh --site /home/user/mysite

  # With a vanity prefix
  sudo ./tor-deploy.sh --site /home/user/mysite --vanity mysite

  # Custom port + save address to a specific file
  sudo ./tor-deploy.sh --site ./dist --port 8080 --out /root/my.onion

  # Already have nginx; just set up Tor
  sudo ./tor-deploy.sh --site ./dist --skip-nginx

${BOLD}NOTES${RESET}
  • Must be run as root (or with sudo).
  • Tested on Debian 10/11/12 and Ubuntu 20.04/22.04/24.04.
  • Your secret key lives in <hs-dir>/hs_ed25519_secret_key — back it up!
  • The final .onion URL is printed at the end and saved to --out.

EOF
}

# ── Defaults ──────────────────────────────────────────────────────────────────
SITE_DIR=""
VANITY_PREFIX=""
TOR_HS_DIR="/var/lib/tor/hidden_service"
THREADS="$(nproc)"
PORT=80
OUT_FILE="$(dirname "$0")/onion_address.txt"
SKIP_NGINX=false
SKIP_TOR_REPO=false
YES=false

# ── Argument parsing ──────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && { usage; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --site)
            [[ -z "${2:-}" ]] && die "--site requires a value"
            SITE_DIR="${2%/}"; shift 2 ;;
        --vanity)
            [[ -z "${2:-}" ]] && die "--vanity requires a value"
            VANITY_PREFIX="$2"; shift 2 ;;
        --hs-dir)
            [[ -z "${2:-}" ]] && die "--hs-dir requires a value"
            TOR_HS_DIR="$2"; shift 2 ;;
        --threads)
            [[ -z "${2:-}" ]] && die "--threads requires a value"
            THREADS="$2"; shift 2 ;;
        --port)
            [[ -z "${2:-}" ]] && die "--port requires a value"
            PORT="$2"; shift 2 ;;
        --out)
            [[ -z "${2:-}" ]] && die "--out requires a value"
            OUT_FILE="$2"; shift 2 ;;
        --skip-nginx)    SKIP_NGINX=true;    shift ;;
        --skip-tor-repo) SKIP_TOR_REPO=true; shift ;;
        --yes|-y)        YES=true;           shift ;;
        -h|--help)       usage; exit 0 ;;
        *)  die "Unknown option: $1  (try --help)" ;;
    esac
done

# ── Validate ──────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]]    && die "Run this script as root: sudo $0 $*"
[[ -z "$SITE_DIR" ]] && die "--site is required. Try: $0 --help"
[[ -d "$SITE_DIR" ]] || die "Directory not found: $SITE_DIR"
[[ "$THREADS" =~ ^[0-9]+$ && "$THREADS" -ge 1 ]] \
                     || die "--threads must be a positive integer"
[[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]] \
                     || die "--port must be 1–65535"

SITE_NAME="$(basename "$SITE_DIR")"
WEB_ROOT="/var/www/${SITE_NAME}"
NGINX_CONF="/etc/nginx/sites-available/${SITE_NAME}"
VANITY_KEY_DIR="/tmp/supremeonionkey"

# ── Pre-flight summary ────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}tor-deploy.sh — pre-flight check${RESET}"
echo -e "  --site        : ${SITE_DIR}"
echo -e "  --vanity      : ${VANITY_PREFIX:-"(none — auto-generated)"}"
echo -e "  --hs-dir      : ${TOR_HS_DIR}"
echo -e "  --port        : ${PORT}"
echo -e "  --threads     : ${THREADS}"
echo -e "  --out         : ${OUT_FILE}"
echo -e "  --skip-nginx  : ${SKIP_NGINX}"
echo -e "  --skip-tor-repo: ${SKIP_TOR_REPO}"
echo ""

if ! $YES; then
    read -rp "Proceed? [y/N] " _confirm
    [[ "$_confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
fi

# ── Step 1: System packages ───────────────────────────────────────────────────
info "Step 1/7 — Installing base packages …"
apt-get update -qq
if $SKIP_NGINX; then
    apt-get install -y curl wget gpg gcc libc6-dev libsodium-dev \
                       make autoconf git &>/dev/null
    info "--skip-nginx set; skipping nginx install."
else
    apt-get install -y nginx curl wget gpg gcc libc6-dev libsodium-dev \
                       make autoconf git &>/dev/null
fi
success "Packages installed."

# ── Step 2: Deploy site files ─────────────────────────────────────────────────
info "Step 2/7 — Copying site files to ${WEB_ROOT} …"
rm -rf "$WEB_ROOT"
cp -r "$SITE_DIR" "$WEB_ROOT"
chown -R www-data:www-data "$WEB_ROOT"
chmod -R 755 "$WEB_ROOT"
success "Site files copied."

# ── Step 3: Configure nginx ───────────────────────────────────────────────────
if $SKIP_NGINX; then
    info "Step 3/7 — Skipping nginx config (--skip-nginx)."
    info "          Make sure your web server serves ${WEB_ROOT} on 127.0.0.1:${PORT}"
else
    info "Step 3/7 — Configuring nginx (localhost only, no TLS needed for Tor) …"

    # Disable the default site
    rm -f /etc/nginx/sites-enabled/default

    cat > "$NGINX_CONF" <<NGINXEOF
server {
    listen 127.0.0.1:${PORT};
    server_name localhost;

    root ${WEB_ROOT};
    index index.html index.htm;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN"     always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer"    always;

    # Never leak the real server; only reachable via .onion anyway
    server_tokens off;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Deny dot-files
    location ~ /\. {
        deny all;
    }

    access_log /var/log/nginx/${SITE_NAME}_access.log;
    error_log  /var/log/nginx/${SITE_NAME}_error.log;
}
NGINXEOF

    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/"${SITE_NAME}"

    nginx -t || die "nginx config test failed — check ${NGINX_CONF}"
    systemctl enable --now nginx &>/dev/null
    systemctl reload nginx
    success "nginx configured and reloaded (listening on 127.0.0.1:${PORT})."
fi

# ── Step 4: Add Tor official repo ────────────────────────────────────────────
info "Step 4/7 — Installing Tor …"

# Detect Debian/Ubuntu codename
DISTRO_ID="$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
DEBIAN_VERSION_FILE="/etc/debian_version"
case "$DISTRO_ID" in
    ubuntu)
        DISTRIBUTION="$(grep '^UBUNTU_CODENAME=' /etc/os-release \
                        | cut -d= -f2 || lsb_release -cs)"
        ;;
    debian)
        RAW_VER="$(cat "$DEBIAN_VERSION_FILE")"
        case "${RAW_VER%%.*}" in
            12) DISTRIBUTION="bookworm" ;;
            11) DISTRIBUTION="bullseye" ;;
            10) DISTRIBUTION="buster"   ;;
            *)  DISTRIBUTION="$(lsb_release -cs 2>/dev/null || echo stable)" ;;
        esac
        ;;
    *)
        DISTRIBUTION="$(lsb_release -cs 2>/dev/null || echo stable)"
        warn "Unknown distro '${DISTRO_ID}', guessing codename: ${DISTRIBUTION}"
        ;;
esac
info "Detected distribution: ${DISTRIBUTION}"

if $SKIP_TOR_REPO; then
    info "--skip-tor-repo set; installing tor from distro packages."
    apt-get install -y tor &>/dev/null
else
    # Import Tor Project signing key
    KEYRING="/usr/share/keyrings/tor-archive-keyring.gpg"
    wget -qO- "https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc" \
      | gpg --dearmor | tee "$KEYRING" >/dev/null

    # Write sources.list entry
    cat > /etc/apt/sources.list.d/tor.list <<TOREOF
deb     [signed-by=${KEYRING}] https://deb.torproject.org/torproject.org ${DISTRIBUTION} main
deb-src [signed-by=${KEYRING}] https://deb.torproject.org/torproject.org ${DISTRIBUTION} main
TOREOF

    apt-get update -qq
    apt-get install -y tor deb.torproject.org-keyring &>/dev/null
    success "Tor installed from official Tor Project repo."
fi

# ── Step 5: Configure Tor hidden service ─────────────────────────────────────
info "Step 5/7 — Configuring Tor hidden service …"

TORRC="/etc/tor/torrc"

# Remove any existing hidden service config for this site then append fresh
sed -i '/^HiddenServiceDir/d; /^HiddenServicePort/d' "$TORRC"

cat >> "$TORRC" <<TOREOF

## Hidden service — added by tor-deploy.sh
HiddenServiceDir ${TOR_HS_DIR}
HiddenServicePort 80 127.0.0.1:${PORT}
TOREOF

# Ensure correct ownership
mkdir -p "$TOR_HS_DIR"
chown -R debian-tor:debian-tor "$TOR_HS_DIR" 2>/dev/null \
  || chown -R tor:tor "$TOR_HS_DIR" 2>/dev/null \
  || true
chmod 700 "$TOR_HS_DIR"

systemctl enable --now tor
systemctl restart tor

# Give Tor a moment to generate keys
info "Waiting for Tor to generate hidden service keys …"
for i in {1..30}; do
    [[ -f "${TOR_HS_DIR}/hostname" ]] && break
    sleep 2
done
[[ -f "${TOR_HS_DIR}/hostname" ]] || die "Tor did not generate hostname after 60 s. Check: journalctl -u tor"

AUTO_ONION="$(cat "${TOR_HS_DIR}/hostname")"
success "Hidden service is up: ${BOLD}${AUTO_ONION}${RESET}"

# ── Step 6: Optional vanity address ──────────────────────────────────────────
FINAL_ONION="$AUTO_ONION"

if [[ -n "$VANITY_PREFIX" ]]; then
    info "Step 6/7 — Mining vanity address with prefix '${VANITY_PREFIX}' …"
    warn "This can take minutes to hours depending on prefix length. Ctrl-C to skip."

    # Build mkp224o if not already present
    MKP="$(command -v mkp224o || true)"
    if [[ -z "$MKP" ]]; then
        BUILD_DIR="/tmp/mkp224o_build"
        rm -rf "$BUILD_DIR"
        git clone --depth=1 https://github.com/cathugger/mkp224o.git "$BUILD_DIR" &>/dev/null
        pushd "$BUILD_DIR" >/dev/null
        ./autogen.sh &>/dev/null
        ./configure  &>/dev/null
        make -j"$(nproc)" &>/dev/null
        MKP="${BUILD_DIR}/mkp224o"
        popd >/dev/null
        success "mkp224o compiled."
    fi

    rm -rf "$VANITY_KEY_DIR"
    mkdir -p "$VANITY_KEY_DIR"

    # Mine — use all available threads
    THREADS="$(nproc)"
    "$MKP" "$VANITY_PREFIX" -v -n 1 -d "$VANITY_KEY_DIR" -t "$THREADS" \
      && MINED=true || MINED=false

    if $MINED; then
        MINED_DIR="$(find "$VANITY_KEY_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
        if [[ -n "$MINED_DIR" ]]; then
            # Install new keys
            cp -r "$MINED_DIR/." "$TOR_HS_DIR/"
            chown -R debian-tor:debian-tor "$TOR_HS_DIR" 2>/dev/null \
              || chown -R tor:tor "$TOR_HS_DIR" 2>/dev/null \
              || true
            chmod 700 "$TOR_HS_DIR"
            systemctl restart tor
            sleep 5
            FINAL_ONION="$(cat "${TOR_HS_DIR}/hostname")"
            success "Vanity address installed: ${BOLD}${FINAL_ONION}${RESET}"
        else
            warn "mkp224o ran but produced no output directory. Using auto address."
        fi
    else
        warn "Vanity mining failed or was cancelled. Using auto address."
    fi
else
    info "Step 6/7 — Vanity prefix not requested; skipping."
fi

# ── Step 7: Summary ───────────────────────────────────────────────────────────
info "Step 7/7 — Verifying services …"
systemctl is-active --quiet nginx && success "nginx  → running" \
                                  || warn    "nginx  → NOT running"
systemctl is-active --quiet tor   && success "tor    → running" \
                                  || warn    "tor    → NOT running"

echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════${RESET}"
echo -e "${BOLD} Deployment complete!${RESET}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════${RESET}"
echo -e "  Site directory : ${SITE_DIR}"
echo -e "  Web root       : ${WEB_ROOT}"
echo -e "  .onion address : ${BOLD}${CYAN}${FINAL_ONION}${RESET}"
echo -e ""
echo -e "  Open in Tor Browser:"
echo -e "  ${BOLD}http://${FINAL_ONION}${RESET}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════${RESET}"

# Save address to --out file
echo "$FINAL_ONION" > "$OUT_FILE"
info "Address also saved to: ${OUT_FILE}"
echo ""
warn "Keep ${TOR_HS_DIR}/hs_ed25519_secret_key PRIVATE — it is your site's identity."