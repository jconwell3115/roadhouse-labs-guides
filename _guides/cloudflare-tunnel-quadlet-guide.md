---
layout: post
date: 2026-09-25
title: "Cloudflare Tunnel with Podman Quadlets"
permalink: /guides/cloudflare-tunnel-quadlet-guide
description: "Full setup guide: moving a domain to Cloudflare, running cloudflared as a rootful Podman quadlet, routing DNS through the tunnel, and locking admin UIs behind Cloudflare Access — with zero inbound ports open."
author: "Roadhouse Labs"
---

> **Why do it this way?** Read the [overview post]({% post_url 2026-09-25-cloudflare-tunnel %}) first for the reasoning before diving into the full setup.

---

## Overview

This guide exposes self-hosted web services to the internet **without opening a single inbound port** on your router or firewall. It uses three Cloudflare pieces together:

1. **Your domain on Cloudflare DNS**, so Cloudflare is authoritative for every hostname.
2. **A Cloudflare Tunnel**, run by the `cloudflared` daemon in a rootful Podman container managed by a systemd quadlet. `cloudflared` makes *outbound* connections to Cloudflare's edge and holds them open, and requests for your hostnames travel back down that connection.
3. **Cloudflare Access** in front of anything administrative, so management UIs need an identity check at the edge before a request ever reaches your network.

```
Browser ──HTTPS──▶ Cloudflare edge ──(existing outbound tunnel)──▶ cloudflared on your host ──▶ 127.0.0.1:<port>
                     │
                     └─ Access policy checked here for admin hostnames
```

Nothing listens on your WAN IP. There's no port forward to maintain and nothing for internet scanners to find. Your home IP doesn't appear in public DNS for the tunneled hostnames either.

The quadlet file lives in `~/containers/quadlets/rootful/` and is deployed to `/etc/containers/systemd/`. The tunnel config and credentials live in `~/containers/cloudflared/`.

**What a tunnel is not:** it only carries HTTP(S) (and a few other protocols through extra client software). It **cannot** carry a WireGuard UDP listener. For that, see the [WireGuard guide]({{ '/guides/wg-easy-quadlet-guide' | relative_url }}). In my setup the two sit side by side: web apps go through the tunnel, and the VPN keeps its one forwarded UDP port.

---

## Prerequisites

- A domain name you control (or one you'll register through Cloudflare)
- A free Cloudflare account
- Linux (systemd-based: Fedora, RHEL, CentOS Stream, Debian, Ubuntu)
- Podman 4.4+ (quadlet support built-in)
- Root/sudo access
- Outbound internet access to Cloudflare on port **7844** (TCP and UDP). Most home networks allow this by default.
- The services you want to publish already running and reachable from the host (for example `http://127.0.0.1:8080`)

---

## Directory Structure

```
~/containers/cloudflared/                  # Tunnel state, bind-mounted into the container
  cert.pem                                  # Account origin certificate (from `tunnel login`), management only
  <TUNNEL_UUID>.json                        # Tunnel credentials (from `tunnel create`), needed to run
  config.yml                                # Ingress rules: hostname -> local service

~/containers/quadlets/rootful/              # Source quadlet: edit here, then deploy
  cloudflared.container

/etc/containers/systemd/                    # Deployed quadlet (systemd reads from here)
  cloudflared.container
```

> **Keep `cert.pem` and `<TUNNEL_UUID>.json` out of git.** If `~/containers` is a git repository, add both to `.gitignore` *before* you create them (see [Security Notes](#security-notes)). The credentials file alone is enough for anyone to run your tunnel, and `cert.pem` can create and delete tunnels and DNS records on your account.

---

## Part 1: Put Your Domain on Cloudflare

### Option A: Register the domain at Cloudflare

Cloudflare Registrar sells domains at cost, and the zone is set up on Cloudflare automatically. **Dashboard → Domain Registration → Register Domains**, then skip to [Zone settings](#zone-settings).

### Option B: Keep your existing registrar and point it at Cloudflare

1. **Dashboard → Add a domain** → enter the apex domain (`example.com`) → choose the **Free** plan.
2. Cloudflare scans your current DNS records and imports what it finds. **Review the imported list carefully.** The scan misses records, especially MX, TXT (SPF/DKIM/DMARC) and anything on an uncommon subdomain. Compare against your registrar's zone before moving on.
3. Cloudflare gives you **two nameservers** (for example `ada.ns.cloudflare.com` / `bob.ns.cloudflare.com`).
4. **If DNSSEC is enabled at your current registrar, turn it off first** and wait for the DS record to expire. Changing nameservers with a stale DS record in place makes the domain fail validation for resolvers that check DNSSEC.
5. At your registrar, replace the existing nameservers with the two Cloudflare ones.
6. Wait for Cloudflare to show the zone as **Active**. This usually takes minutes but can take up to 24 hours.

Check the delegation from any machine:

```bash
dig +short NS example.com
# Should return only the two *.ns.cloudflare.com names
```

### Zone settings

Once the zone is active, set these in the Cloudflare dashboard for the domain:

| Setting | Where | Value | Why |
|---|---|---|---|
| SSL/TLS encryption mode | SSL/TLS → Overview | **Full (strict)** | Safe default for any proxied record that isn't a tunnel. Tunnel hostnames are encrypted end-to-end by the tunnel itself. |
| Always Use HTTPS | SSL/TLS → Edge Certificates | **On** | Redirects `http://` to `https://` at the edge |
| Minimum TLS Version | SSL/TLS → Edge Certificates | **TLS 1.2** | Drops legacy clients you don't need |
| DNSSEC | DNS → Settings | **Enable**, then add the DS record at your registrar | Only after the zone is active on Cloudflare nameservers |

You don't need to create any DNS records for the tunneled hostnames by hand. The `cloudflared tunnel route dns` step in Part 2 creates them.

---

## Part 2: Create the Tunnel

This guide uses a **locally managed** tunnel: the ingress rules live in a `config.yml` you keep with the rest of your infrastructure config, not in the Cloudflare dashboard. All management commands run through the same `cloudflared` container image the service uses, so nothing needs installing on the host.

### 1. Create the state directory

```bash
mkdir -p ~/containers/cloudflared
chmod 700 ~/containers/cloudflared
```

### 2. Define a helper for one-off commands

Every management command needs the same volume mount and user settings as the long-running service. A shell function keeps them short:

```bash
cfd() {
  sudo podman run --rm -it \
    --user 0 \
    -e HOME=/home/nonroot \
    -v "$HOME/containers/cloudflared:/home/nonroot/.cloudflared:Z" \
    docker.io/cloudflare/cloudflared:latest "$@"
}
```

- `--user 0` / `HOME=/home/nonroot`: the image runs as an unprivileged `nonroot` user by default, which can't write into a directory owned by your host user. Running as root inside the container fixes that. Pointing `HOME` at `/home/nonroot` keeps `cloudflared` looking in `/home/nonroot/.cloudflared` for its files.
- `:Z` relabels the directory for SELinux so the container can read and write it.
- `"$HOME"` expands to *your* home directory, because the shell expands it before `sudo` runs.

### 3. Authenticate `cloudflared` to your account

```bash
cfd tunnel login
```

This prints a URL. Open it in a browser, log in to Cloudflare, and **pick the zone** (`example.com`) to authorize. When it finishes, `cert.pem` appears in `~/containers/cloudflared/`.

`cert.pem` is only used for **management** (`create`, `route dns`, `delete`, `list`). The running tunnel doesn't need it. It's tied to the zone you picked here, which matters later for `route dns`.

### 4. Create the tunnel

```bash
cfd tunnel create home
```

Output looks like:

```
Tunnel credentials written to /home/nonroot/.cloudflared/<TUNNEL_UUID>.json. ...
Created tunnel home with id <TUNNEL_UUID>
```

Note the UUID. The credentials file `<TUNNEL_UUID>.json` is now in `~/containers/cloudflared/`. Lock both secrets down:

```bash
chmod 600 ~/containers/cloudflared/cert.pem ~/containers/cloudflared/*.json
```

Confirm the tunnel exists on the account:

```bash
cfd tunnel list
```

---

## Part 3: The Tunnel Config

### `config.yml`

`~/containers/cloudflared/config.yml` maps each public hostname to a local service. This is a trimmed version of the one I run:

```yaml
tunnel: <TUNNEL_UUID>
credentials-file: /home/nonroot/.cloudflared/<TUNNEL_UUID>.json

ingress:
  # Public apps: they have their own login and their mobile apps need direct access
  - hostname: nextcloud.example.com
    service: http://127.0.0.1:8080

  - hostname: immich.example.com
    service: http://127.0.0.1:2283

  # Admin UIs: published, but gated by Cloudflare Access (Part 6)
  - hostname: pihole.example.com
    service: http://127.0.0.1:8082

  - hostname: portainer.example.com
    service: http://127.0.0.1:9000

  - hostname: uptime-kuma.example.com
    service: http://127.0.0.1:3001

  # An HTTPS origin with a self-signed certificate (Cockpit on :9090)
  - hostname: server.example.com
    service: https://127.0.0.1:9090
    originRequest:
      noTLSVerify: true

  # A service on a different LAN host: cloudflared can reach anything the host can
  - hostname: nas.example.com
    service: https://192.168.1.50:9090
    originRequest:
      noTLSVerify: true

  # Catch-all: required, and must be last
  - service: http_status:404
```

**Key settings explained:**

| Setting | Purpose |
|---|---|
| `tunnel:` | The tunnel UUID from `tunnel create`. Using the UUID instead of the name avoids ambiguity. |
| `credentials-file:` | Path **inside the container** (`/home/nonroot/.cloudflared/...`), not the host path |
| `ingress:` | Rules are checked **top to bottom**, and the first `hostname` match wins |
| `service: http://127.0.0.1:<port>` | The local origin. `127.0.0.1` works because the container uses host networking (see the quadlet below). |
| `service: https://...` + `noTLSVerify: true` | For origins that only speak HTTPS with a self-signed cert (Cockpit, Proxmox, many appliances). Traffic is still encrypted to the origin, but the certificate isn't validated. |
| `service: http_status:404` | The final rule has no `hostname` and catches everything else. `cloudflared` refuses to start without a catch-all. |

**Why point at `127.0.0.1`?** A service that only needs to be reached through the tunnel can publish its port on loopback only (`PublishPort=127.0.0.1:8080:80` in a quadlet, or `127.0.0.1:8080:80` in compose). That way it isn't even exposed on the LAN. `cloudflared` on the host is its only way in.

**Better than `noTLSVerify`:** if the origin's certificate is issued by a CA you control, use `originServerName: <name on cert>` plus `caPool: /home/nonroot/.cloudflared/ca.pem` instead, so the origin certificate is actually verified.

### Validate the config

```bash
cfd tunnel ingress validate
cfd tunnel ingress rule https://pihole.example.com   # shows which rule a URL would hit
```

---

## Part 4: Quadlet File Explained

### `cloudflared.container`

```ini
[Unit]
Description=cloudflared Tunnel (quadlet)
After=network-online.target
Wants=network-online.target

[Container]
ContainerName=cloudflared-tunnel
Image=docker.io/cloudflare/cloudflared:latest
Network=host

# Run as root inside the container so it can read the bind-mounted files
User=0

# Replace <user> with your username
Volume=/home/<user>/containers/cloudflared:/home/nonroot/.cloudflared:Z

# Make cloudflared look for config.yml and credentials in the mounted directory
Environment=HOME=/home/nonroot

# Run the tunnel by UUID; config.yml is picked up from ~/.cloudflared
Exec=tunnel run <TUNNEL_UUID>

[Service]
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

**Key settings explained:**

| Setting | Purpose |
|---|---|
| `ContainerName=cloudflared-tunnel` | Container name used with `podman logs`/`exec`. It differs from the unit name (`cloudflared.service`), which is a common source of confusion. |
| `Network=host` | Shares the host's network namespace so `127.0.0.1:<port>` in `config.yml` reaches services on the host, and LAN IPs route normally |
| `User=0` | Runs as root inside the container. The default `nonroot` user can't read files owned by your host user in a rootful container. |
| `Volume=...:Z` | Bind-mounts config and credentials; `:Z` applies a private SELinux label |
| `Environment=HOME=/home/nonroot` | With `User=0`, `HOME` would otherwise be `/root`. This keeps `cloudflared`'s default search path on the mounted directory. |
| `Exec=tunnel run <TUNNEL_UUID>` | Arguments passed to the image's `cloudflared` entrypoint |
| `Restart=always` | Brings the tunnel back after crashes and after the Cloudflare side drops the connection |
| `WantedBy=multi-user.target` | Starts at boot. Quadlet units are "enabled" through this section, not with `systemctl enable`. |

**Why rootful?** Running this rootless also works. I run it rootful because it fronts services from both the rootful and rootless sides of the host, starts at boot without lingering a user session, and pairs cleanly with host networking. If you only publish rootless services, a rootless quadlet in `~/.config/containers/systemd/` with `systemctl --user` works the same way.

---

## Part 5: Deploy and Route DNS

### 1. Deploy the quadlet

```bash
sudo cp ~/containers/quadlets/rootful/cloudflared.container /etc/containers/systemd/
sudo systemctl daemon-reload
sudo systemctl start cloudflared.service
sudo systemctl status cloudflared.service
```

Check the logs for four registered connections:

```bash
sudo podman logs cloudflared-tunnel 2>&1 | grep -i "registered tunnel connection"
```

You should see four lines, spread across two Cloudflare data centers.

### 2. Create the DNS records

For each hostname in `config.yml`:

```bash
cfd tunnel route dns <TUNNEL_UUID> nextcloud.example.com
cfd tunnel route dns <TUNNEL_UUID> immich.example.com
cfd tunnel route dns <TUNNEL_UUID> pihole.example.com
# ...one per hostname
```

Each command creates a **proxied** `CNAME` from the hostname to `<TUNNEL_UUID>.cfargotunnel.com`. That record only resolves to something useful through Cloudflare's proxy, so it doesn't reveal your IP.

**Two steps, every time:** publishing a new service always takes *both* an ingress rule in `config.yml` (plus a restart) *and* a `route dns` record. Missing the first gets you a 404 from the catch-all. Missing the second means the name doesn't resolve.

### 3. Firewall

Nothing to open. The tunnel is outbound-only, so there's no `firewall-cmd --add-port` step and no router port forward. If you previously forwarded 80/443 to this host, **remove those forwards now**.

---

## Part 6: Put Admin UIs Behind Cloudflare Access

A tunnel hides your IP and closes your ports, but a hostname like `portainer.example.com` is still reachable by anyone who guesses it. **Cloudflare Access** puts an identity check at Cloudflare's edge, in front of the tunnel. Unauthenticated requests never reach `cloudflared`.

Access is part of **Cloudflare Zero Trust**, which is free for up to 50 users.

### Decide what gets gated

| Gate with Access | Leave public (rely on the app's own auth) |
|---|---|
| Pi-hole, Portainer, Vault, wg-easy UI, Cockpit, Uptime Kuma admin, database UIs (Adminer), dashboards | Apps with **mobile or desktop clients** that can't complete a browser login: Nextcloud, Immich, and similar |

The rule of thumb: **if only you use it, and only from a browser, gate it.** Access in front of Nextcloud or Immich breaks their mobile sync, because the app gets an HTML login page instead of the API response it expects.

### 1. Set up Zero Trust

1. **Dashboard → Zero Trust**. The first time, pick a team name (this becomes `<team>.cloudflareaccess.com`) and the Free plan.
2. **Settings → Authentication → Login methods**: **One-time PIN** is enabled by default and needs no setup (a code is emailed to allowed addresses). You can add GitHub, Google or another identity provider here if you prefer.

### 2. Create an Access application per admin hostname

**Zero Trust → Access → Applications → Add an application → Self-hosted**:

- **Application domain:** `pihole.example.com`
- **Session duration:** 24 hours is reasonable for admin tools
- **Policy:** Action **Allow**, with an Include rule of **Emails** → your address(es)
- **Login methods:** One-time PIN (and any IdP you added)

Repeat for each admin hostname, or add multiple hostnames to one application if they share a policy.

### 3. Test it

In a private browser window, open `https://pihole.example.com`. You should get the Cloudflare Access login page, *not* Pi-hole. Enter an allowed email, use the PIN, and you land on Pi-hole. An email that isn't on the list gets turned away at the edge.

> **Access is a second layer, not a replacement.** Keep strong passwords and MFA on the apps themselves. If an Access policy is ever misconfigured, the app's own login is what's left.

---

## Verification

```bash
# Service is running and has been stable
sudo systemctl status cloudflared.service

# Four registered connections
sudo podman logs cloudflared-tunnel 2>&1 | grep -ci "registered tunnel connection"

# Tunnel health from Cloudflare's side (connectors, edge locations)
cfd tunnel info <TUNNEL_UUID>

# DNS is a proxied CNAME: resolves to Cloudflare IPs, not your WAN IP
dig +short nextcloud.example.com

# Public app responds
curl -sI https://nextcloud.example.com | head -1

# Gated app redirects to Access (expect a 302 to <team>.cloudflareaccess.com)
curl -sI https://pihole.example.com | grep -iE '^(HTTP|location)'

# Unknown hostname on your zone hits the catch-all
curl -sI https://nope.example.com | head -1
```

Then check from **outside your network** (phone on cellular). Hairpin and split-DNS setups can make a broken public path look fine from inside the LAN.

In the dashboard, **Zero Trust → Networks → Tunnels** should show the tunnel as **Healthy**.

---

## Useful Management Commands

### Service

```bash
sudo systemctl restart cloudflared.service
sudo systemctl stop cloudflared.service
sudo systemctl status cloudflared.service
```

### Logs

```bash
sudo journalctl -u cloudflared.service -f
sudo podman logs -f cloudflared-tunnel     # container name, not the unit name
```

### Adding a new service

```bash
# 1. Add an ingress rule ABOVE the catch-all in ~/containers/cloudflared/config.yml
# 2. Validate
cfd tunnel ingress validate
# 3. Create the DNS record
cfd tunnel route dns <TUNNEL_UUID> newapp.example.com
# 4. Restart to load the new config (there is no hot reload)
sudo systemctl restart cloudflared.service
# 5. If it's an admin UI, add an Access application for it
```

### Update the image

```bash
sudo podman pull docker.io/cloudflare/cloudflared:latest
sudo systemctl restart cloudflared.service
```

To automate this, add `AutoUpdate=registry` under `[Container]` and enable `podman-auto-update.timer`.

---

## Troubleshooting

### `podman logs cloudflared` says "no container found"

The unit is `cloudflared.service`, but the container is named `cloudflared-tunnel` (from `ContainerName=`). Use `sudo podman logs cloudflared-tunnel`. `sudo` matters too: rootful containers don't appear in your user's `podman ps`.

### Error 1033 in the browser

Cloudflare has the DNS record but **no running connector** for that tunnel. Check that `cloudflared.service` is running, the logs show registered connections, and the UUID in the CNAME target matches the UUID in `config.yml`.

### 502 Bad Gateway

The tunnel is up, but `cloudflared` can't reach the origin. Test from the host itself:

```bash
curl -sI http://127.0.0.1:8080
```

Common causes: the service isn't running, the port in `config.yml` is wrong, `https://` used against a plain-HTTP origin (or the reverse), or a self-signed HTTPS origin without `noTLSVerify`.

### 404 from a hostname you just added

The request hit the catch-all rule: either the ingress rule is missing or misspelled, or you didn't restart `cloudflared` after editing `config.yml`. Check which rule matches:

```bash
cfd tunnel ingress rule https://newapp.example.com
```

### `route dns` fails: "record with that host already exists"

An `A`/`AAAA`/`CNAME` for that name is already in the zone, often from an earlier setup or a DDNS tool. Delete it in the dashboard, or overwrite it:

```bash
cfd tunnel route dns --overwrite-dns <TUNNEL_UUID> app.example.com
```

### `route dns` created the record in the wrong zone

`route dns` uses the zone chosen during `tunnel login` (stored in `cert.pem`). With several domains on the account, re-run `tunnel login` for the other zone, or create the proxied `CNAME` to `<TUNNEL_UUID>.cfargotunnel.com` by hand in the dashboard.

### Permission denied reading credentials

Usually one of: missing `:Z` on the volume (SELinux denial, check `sudo ausearch -m avc -ts recent`), missing `User=0`, or `HOME` not set to `/home/nonroot`, so `cloudflared` looks in the wrong directory.

### Tunnel connects, then flaps

The default protocol is QUIC over UDP 7844, with a fallback to HTTP/2 over TCP 7844. If a firewall upstream mangles UDP, force HTTP/2:

```ini
Exec=tunnel --protocol http2 run <TUNNEL_UUID>
```

### Large uploads fail (Nextcloud, Immich)

Cloudflare's proxy caps request bodies at **100 MB** on the Free and Pro plans. Nextcloud's clients upload in chunks and are unaffected. Very large single uploads, like long videos from the Immich mobile app, can fail with a 413 error. Options: upload over the LAN or VPN, or use a separate non-tunneled path for bulk uploads.

---

## Gotchas

- **You don't need DDNS for tunneled hostnames.** The CNAME points at the tunnel, not your IP, so your WAN IP can change freely. You still need DDNS for anything that *must* reach your real IP, such as the WireGuard endpoint. Make sure your DDNS tool doesn't manage any hostname you've routed to the tunnel, or the two will fight over the record.
- **Tunnel CNAMEs must stay proxied** (orange cloud). Switching one to "DNS only" breaks it.
- **Order matters in `ingress`.** A broad rule (for example a wildcard hostname) placed above a specific one will swallow it.
- **Config changes need a restart.** Locally managed tunnels don't hot-reload `config.yml`.
- **Deleting a tunnel doesn't delete its DNS records.** Clean up the CNAMEs by hand, or they'll return error 1033.

---

## Security Notes

- **Nothing inbound.** Remove any old router port forwards for 80/443 after moving services to the tunnel. The tunnel only helps if the old path is closed.
- **Secrets stay out of version control.** Add these to the `.gitignore` of whatever repo holds your config:

  ```gitignore
  cloudflared/cert.pem
  cloudflared/*.json
  ```

  If either file has ever been pushed, treat it as compromised. Rotate by creating a new tunnel (`tunnel create`), re-routing DNS to it, and deleting the old one (`tunnel delete`). For `cert.pem`, run `tunnel login` again, and review and revoke old API tokens under **My Profile → API Tokens**.
- **`cert.pem` is more sensitive than the tunnel credentials.** It can create and delete tunnels and DNS records. It's only needed for management, so you can move it off the server entirely between changes.
- **Gate every admin surface with Access**, and keep app-level MFA on as well.
- **Loopback-bind tunnel-only services** so the tunnel is their only path in and they aren't exposed on the LAN either.
- **Prefer `caPool` + `originServerName` over `noTLSVerify`** where you can issue the origin a real certificate.
- **Monitor it.** For a direct health check (for example from Uptime Kuma), add `--metrics 127.0.0.1:2000` to the `Exec=` line (`tunnel --metrics 127.0.0.1:2000 run <TUNNEL_UUID>`) and poll `http://127.0.0.1:2000/ready`.

---

## References

- [Cloudflare Tunnel Documentation](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [Tunnel Configuration File Reference](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/local-management/configuration-file/)
- [Cloudflare Access: Self-hosted Applications](https://developers.cloudflare.com/cloudflare-one/applications/configure-apps/self-hosted-apps/)
- [Changing Nameservers to Cloudflare](https://developers.cloudflare.com/dns/zone-setups/full-setup/setup/)
- [cloudflared Container Image](https://hub.docker.com/r/cloudflare/cloudflared)
- [Podman Quadlet Documentation](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
