# torrd.sh

> One-command deployment of a static website as a **Tor hidden service** (.onion) on Debian/Ubuntu.

torrd.sh installs and configures **nginx** + **Tor**, deploys your site files, and optionally mines a **vanity .onion address** — all from a single script with no manual steps.

---

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/youruser/torrd/main/install.sh | sudo bash
```

Or download and run manually:

```bash
curl -fsSL https://raw.githubusercontent.com/youruser/torrd/main/torrd.sh -o torrd.sh
chmod +x torrd.sh
sudo ./torrd.sh --site /path/to/your/site
```

---

## Requirements

| Requirement | Notes |
|-------------|-------|
| Debian 10 / 11 / 12 | or Ubuntu 20.04 / 22.04 / 24.04 |
| Root / sudo | Required for apt, nginx, tor, systemctl |
| Internet access | To fetch packages and the Tor signing key |
| `bash` ≥ 4 | Pre-installed on all supported distros |

---

## Usage

```
sudo ./torrd.sh --site <path> [OPTIONS]
```

### Required

| Flag | Description |
|------|-------------|
| `--site <path>` | Path to your website folder (HTML / CSS / JS / assets) |

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--vanity <prefix>` | _(none)_ | Mine a custom `.onion` address starting with `<prefix>` |
| `--hs-dir <path>` | `/var/lib/tor/hidden_service` | Where Tor stores the hidden service keys |
| `--port <n>` | `80` | Local port nginx binds to (forwarded from Tor) |
| `--threads <n>` | all cores | CPU threads used during vanity mining |
| `--out <file>` | `./onion_address.txt` | File to write the final `.onion` address to |
| `--skip-nginx` | `false` | Skip nginx install/config (use your own web server) |
| `--skip-tor-repo` | `false` | Use the distro's `tor` package instead of torproject.org |
| `--yes` / `-y` | `false` | Non-interactive: skip the confirmation prompt |
| `--help` / `-h` | | Print help and exit |

---

## Examples

```bash
# Minimal — auto-generated .onion address
sudo ./torrd.sh --site /home/user/mysite

# With a vanity prefix (mines an address starting with "mysite")
sudo ./torrd.sh --site /home/user/mysite --vanity mysite

# Custom local port + save address to a specific file
sudo ./torrd.sh --site ./dist --port 8080 --out /root/my.onion

# Already have nginx running — just configure Tor
sudo ./torrd.sh --site ./dist --skip-nginx

# Fully non-interactive (CI / cloud-init)
sudo ./torrd.sh --site ./dist --yes

# All options at once
sudo ./torrd.sh \
  --site ./dist \
  --vanity mysite \
  --port 8080 \
  --hs-dir /var/lib/tor/mysite \
  --threads 8 \
  --out /root/mysite.onion \
  --yes
```

---

## What the script does

```
Step 1  Install packages      nginx, wget, gpg, gcc, libsodium, git, make …
Step 2  Deploy site files     cp -r <site> /var/www/<name>, set ownership
Step 3  Configure nginx       Binds to 127.0.0.1:<port> only (no clearnet exposure)
Step 4  Install Tor           Adds torproject.org apt repo + GPG key, installs tor
Step 5  Configure torrc       Writes HiddenServiceDir / HiddenServicePort, restarts Tor
Step 6  Vanity mining         (optional) Builds mkp224o, mines prefix, installs keys
Step 7  Verify & summarise    Checks services, prints .onion URL, saves to --out
```

---

## Vanity address timing

Vanity address mining is brute-force — each extra character multiplies time by ~32.

| Prefix length | Approx. time (8 cores) |
|:---:|---|
| ≤ 4 chars | Seconds |
| 5 chars | Minutes |
| 6 chars | Hours |
| 7 chars | Days |
| 8+ chars | Weeks / months |

The script uses [mkp224o](https://github.com/cathugger/mkp224o) compiled from source with all available CPU threads. Pass `--threads <n>` to limit CPU usage on a shared machine.

---

## File layout after deployment

```
/var/www/<site-name>/          ← Your site files (served by nginx)
/etc/nginx/sites-available/    ← nginx vhost config
/var/lib/tor/hidden_service/   ← Tor hidden service keys  ⚠ keep private
  ├── hostname                 ← Your .onion address (plain text)
  ├── hs_ed25519_secret_key    ← SECRET KEY — back this up
  └── hs_ed25519_public_key
./onion_address.txt            ← Final .onion URL (or path from --out)
```

> ⚠ **Back up `hs_ed25519_secret_key`.** This file is your site's identity on the Tor network. If you lose it, your `.onion` address is gone forever.

---

## Uninstalling / removing a site

```bash
# Stop services
systemctl stop tor nginx

# Remove site files
rm -rf /var/www/<site-name>
rm /etc/nginx/sites-{available,enabled}/<site-name>

# Remove hidden service (loses the .onion address!)
rm -rf /var/lib/tor/hidden_service

# Remove torrc entries
sed -i '/^HiddenServiceDir/d; /^HiddenServicePort/d' /etc/tor/torrc

# Restart services
systemctl restart nginx tor
```

---

## Troubleshooting

**Tor doesn't start / hostname never appears**
```bash
journalctl -u tor --no-pager -n 50
```
The most common cause is wrong ownership on the hidden service directory:
```bash
chown -R debian-tor:debian-tor /var/lib/tor/hidden_service
chmod 700 /var/lib/tor/hidden_service
systemctl restart tor
```

**nginx fails config test**
```bash
nginx -t            # shows the exact error line
cat /etc/nginx/sites-available/<site-name>
```

**Site not loading in Tor Browser**
- Tor takes 30–90 seconds to publish a new hidden service descriptor. Wait and retry.
- Make sure Tor Browser is configured to use the Tor network (not a VPN bypass).
- Run `curl --socks5-hostname 127.0.0.1:9050 http://<your>.onion` from the server to test locally.

**Vanity mining produced no output**
- Ensure `libsodium-dev` is installed (`apt install libsodium-dev`).
- Try a shorter prefix — longer ones can appear to hang for hours.

---

## Security notes

- nginx is bound to `127.0.0.1` only — your site is **not accessible on the clearnet**.
- `server_tokens off` prevents nginx version leakage.
- Security headers (`X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`) are set by default.
- No TLS is needed — Tor provides end-to-end encryption between client and hidden service.
- The hidden service directory is `chmod 700` and owned by the `debian-tor` / `tor` user.

---

## License

MIT — do whatever you want, no warranty implied.