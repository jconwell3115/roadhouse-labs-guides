---
layout: post
date: 2026-11-20
title: "Immich with Podman Quadlets"
permalink: /guides/immich-quadlet-guide
description: "Full setup guide: four rootful quadlets ordered with Requires=, CLI uploads over the LAN, a nightly backup timer under SELinux, and safe major-version upgrades."
author: "Roadhouse Labs"
---
> **New to Immich?** Read the [overview post]({% post_url 2026-11-20-immich-photos %}) first for the what and why
> before diving into this guide.

---

## Overview

This guide runs [Immich](https://immich.app), a self-hosted photo and video library, as four rootful Podman
containers managed by systemd quadlets:

| Unit                                | Image                                                              | Job                                                  |
| ----------------------------------- | ------------------------------------------------------------------ | ---------------------------------------------------- |
| `immich-postgres.service`         | `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` | Database, with the vector extension for smart search |
| `immich-redis.service`            | `docker.io/valkey/valkey:8`                                      | Job queue cache (Valkey is a drop-in Redis fork)     |
| `immich-machine-learning.service` | `ghcr.io/immich-app/immich-machine-learning:v3`                  | Faces, smart search, OCR, duplicate detection        |
| `immich-server.service`           | `ghcr.io/immich-app/immich-server:v3`                            | Web UI, API, background jobs                         |

All four share a private bridge network. Only the server publishes a port (`2283`); the database, cache and
machine-learning container are reachable only from inside that network.

## Prerequisites

- Linux with systemd (this guide was written on Fedora; RHEL, CentOS Stream, Debian and Ubuntu work too)
- Podman 4.4+ (quadlet support built in)
- Root/sudo access
- SELinux enforcing is fine. The backup section covers the one place it needs attention.
- Disk space for your library, plus roughly 10–20% extra for thumbnails and transcoded video
- An SSD for the Postgres data directory if possible

## Directory Structure

```
/etc/containers/systemd/immich/          # Deployed quadlet files (systemd reads from here)
  immich.network
  immich-postgres.container
  immich-redis.container
  immich-machine-learning.container
  immich-server.container

/path/to/your/containers/immich/         # Data and config (bind mounts)
  immich.env                             # Shared environment, holds DB_PASSWORD (mode 600)
  library/                               # Everything Immich stores: originals, thumbs, DB backups
  postgres/                              # Postgres data directory
  redis/                                 # Valkey data
  model-cache/                           # Downloaded ML models
```

I keep the quadlet sources in a Git repo and copy them into `/etc/containers/systemd/immich/` to deploy. Edit the
sources, never the deployed copies.

---

## Quadlet Files Explained

### `immich.network`

```ini
[Unit]
Description=Immich Network
Documentation=https://docs.podman.io/en/latest/markdown/podman-network-create.1.html

[Network]
NetworkName=immich
# Private subnet for the four containers. Pick one that doesn't clash with
# your LAN or any other Podman network on the host.
Subnet=172.19.0.0/24
Gateway=172.19.0.1
Driver=bridge

[Install]
WantedBy=multi-user.target default.target
```

**Why a dedicated network?** Containers on a Podman bridge network resolve each other by container name. That's
how the server finds `immich-postgres` and `immich-redis` with no IPs hard-coded, and why the database never needs
a published port.

---

### `immich-postgres.container`

```ini
[Unit]
Description=Immich PostgreSQL Database
After=network-online.target
Wants=network-online.target

[Container]
ContainerName=immich-postgres
# Immich's own Postgres build, with the VectorChord extension smart search needs.
# Pinned to an exact tag: only move it when the Immich release notes say to.
Image=ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
AutoUpdate=registry

Network=immich.network
# :Z gives this directory a private SELinux label for this container only
Volume=/path/to/your/containers/immich/postgres:/var/lib/postgresql/data:Z
# The image maps DB_USERNAME / DB_PASSWORD / DB_DATABASE_NAME to the
# POSTGRES_* variables itself, so one env file serves every container.
EnvironmentFile=/path/to/your/containers/immich/immich.env
# Tunes Postgres for SSD storage. Use HDD if the data dir is on spinning disk.
Environment=DB_STORAGE_TYPE=SSD

[Service]
Restart=always
RestartSec=5s
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target default.target
```

---

### `immich-redis.container`

```ini
[Unit]
Description=Immich Redis-Compatible Cache
After=network-online.target
Wants=network-online.target

[Container]
ContainerName=immich-redis
# Valkey speaks the Redis protocol, so Immich can't tell the difference
Image=docker.io/valkey/valkey:8
AutoUpdate=registry

Network=immich.network
Volume=/path/to/your/containers/immich/redis:/data:Z

[Service]
Restart=always
RestartSec=5s
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target default.target
```

---

### `immich-machine-learning.container`

```ini
[Unit]
Description=Immich Machine Learning
After=network-online.target immich-redis.service immich-postgres.service
Requires=immich-redis.service immich-postgres.service
Wants=network-online.target

[Container]
ContainerName=immich-machine-learning
# :v3 follows every v3.x release, never v4 (see "Updates" below)
Image=ghcr.io/immich-app/immich-machine-learning:v3
AutoUpdate=registry

Network=immich.network
# Models download here on first use, so they survive container recreation
Volume=/path/to/your/containers/immich/model-cache:/cache:Z
EnvironmentFile=/path/to/your/containers/immich/immich.env

[Service]
Restart=always
RestartSec=5s
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target default.target
```

No `PublishPort=`: only the server talks to machine learning, over the `immich` network. For GPU or other hardware
acceleration, switch to the matching image tag (for example `v3-cuda` or `v3-openvino`) and add the device
mappings from the [upstream hardware acceleration docs](https://immich.app/docs/features/ml-hardware-acceleration).

---

### `immich-server.container`

```ini
[Unit]
Description=Immich Server
After=network-online.target immich-redis.service immich-postgres.service immich-machine-learning.service
Requires=immich-redis.service immich-postgres.service immich-machine-learning.service
Wants=network-online.target

[Container]
ContainerName=immich-server
Image=ghcr.io/immich-app/immich-server:v3
AutoUpdate=registry

Network=immich.network
# The only published port. Plain HTTP; put TLS in front of it (tunnel or proxy).
PublishPort=2283:2283/tcp
# Originals, thumbnails, encoded video, and Immich's own DB backups all live under /data
Volume=/path/to/your/containers/immich/library:/data:Z
EnvironmentFile=/path/to/your/containers/immich/immich.env

[Service]
Restart=always
RestartSec=5s
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target default.target
```

### How the `Requires=` chain behaves

- **Start:** `systemctl start immich-server` pulls in everything it `Requires=`, and `After=` makes it wait.
  Postgres and Valkey start first, then machine learning, then the server.
- **Stop or restart:** systemd propagates these along `Requires=`. Restarting `immich-postgres` also restarts
  machine learning and the server. That's harmless, because `After=` makes them wait for the database, but expect
  the whole stack to bounce.
- **Failure:** if Postgres fails to start, the units that require it don't start either. Check the database's logs
  first.
- **Enable:** quadlet-generated units can't be `systemctl enable`d. The `[Install]` section is read by the quadlet
  generator, which creates the `.wants` links itself on `daemon-reload` and at boot.

---

## Installation

### 1. Create the data directories

```bash
sudo mkdir -p /path/to/your/containers/immich/{library,postgres,redis,model-cache}
```

### 2. Create the environment file

```bash
sudo install -m 600 -o root -g root /dev/null /path/to/your/containers/immich/immich.env
sudo nano /path/to/your/containers/immich/immich.env
```

Contents:

```bash
TZ=America/New_York

DB_HOSTNAME=immich-postgres
DB_PORT=5432
DB_USERNAME=postgres
# Letters and numbers only; set it before the first start
DB_PASSWORD=change-me-to-something-long
DB_DATABASE_NAME=immich

REDIS_HOSTNAME=immich-redis
REDIS_PORT=6379

IMMICH_HOST=0.0.0.0
IMMICH_PORT=2283
IMMICH_LOG_LEVEL=log
```

`DB_PASSWORD` only takes effect when Postgres initializes an empty data directory. Changing it later means
changing it inside the database too.

### 3. Customize the quadlet files

| Setting                             | Description                                                             |
| ----------------------------------- | ----------------------------------------------------------------------- |
| `/path/to/your/containers/immich` | Your data directory, in every `Volume=` and `EnvironmentFile=` line |
| `Subnet=` / `Gateway=`          | A subnet no other network on the host uses                              |
| `DB_STORAGE_TYPE=SSD`             | `HDD` if Postgres lives on spinning disk                              |
| `2283:2283/tcp`                   | Change the host side if port `2283` is taken                          |

### 4. Deploy and start

```bash
sudo mkdir -p /etc/containers/systemd/immich
sudo cp immich.network immich-*.container /etc/containers/systemd/immich/
sudo systemctl daemon-reload
sudo systemctl start immich-server.service
```

The first start pulls four images and can take several minutes. Watch it:

```bash
systemctl list-units 'immich*' --no-pager
{% raw %}sudo podman ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep immich{% endraw %}
sudo journalctl -u immich-server -f
```

### 5. Open the firewall (LAN only)

```bash
sudo firewall-cmd --permanent --add-port=2283/tcp
sudo firewall-cmd --reload
```

### 6. Create the admin account

Open `http://<YOUR_SERVER_LAN_IP>:2283`. The first account you create becomes the admin. Then check a few settings
under **Administration → Settings**:

- **Storage Template:** turn it on. I use {% raw %}`{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}`{% endraw %}, so originals land in date
  folders whatever the uploading device called its folders.
- **Backup Settings:** confirm the nightly database dump is on (more in [Backups](#backups)).
- **Trash:** 30 days by default.

### 7. Remote access

Port `2283` is plain HTTP, so don't forward it to the internet. I publish Immich through a
[Cloudflare Tunnel]({{ '/guides/cloudflare-tunnel-quadlet-guide' | relative_url }}) as `https://photos.example.com`,
pointed at `http://127.0.0.1:2283`. Unlike the admin UIs, it doesn't sit behind Cloudflare Access: the phone app
needs direct API access, and Immich has its own login.

**The catch:** Cloudflare rejects request bodies over **100 MB** with `HTTP 413` on the free plan. The web UI, the
phone app's browsing, and API queries are fine through the tunnel. Large video uploads are not. For those, use the LAN.

---

## Uploading from a Workstation

The phone app handles day-to-day backup. For bulk imports (an old phone dump, a folder of exports), use the
[Immich CLI](https://immich.app/docs/features/command-line-interface) from any machine on the LAN, pointed at the
**LAN address**, not the tunnel.

### Install and log in

Keep the CLI on the **same version as the server**:

```bash
curl -s http://<YOUR_SERVER_LAN_IP>:2283/api/server/version     # e.g. {"major":3,"minor":3,"patch":1}
sudo npm install -g @immich/cli@3.3.1                            # match it
```

Create an API key in the web UI (avatar → **Account Settings → API Keys**), then:

```bash
immich login http://<YOUR_SERVER_LAN_IP>:2283/api <API-KEY>
immich server-info
```

The key is saved to `~/.config/immich/auth.yml` (mode 600). Make one key per machine or script, so you can revoke
one without breaking the rest.

### Upload

```bash
immich upload --recursive --dry-run ~/Pictures/phone   # shows new vs. already on the server
immich upload --recursive ~/Pictures/phone
immich upload -r -A "Phone 2026" ~/Pictures/phone      # also add everything to one album
immich upload -r --album ~/Pictures/trips              # one album per subfolder
```

Run big uploads inside `tmux` or `screen` so a dropped SSH session doesn't kill them.

### How duplicates are handled

- **Exact duplicates are skipped.** The CLI hashes each file and asks the server which hashes it already has, so
  re-running an upload is safe. File names don't matter.
- **Near-duplicates are not.** A resized or re-compressed copy (WhatsApp, Messenger) has different bytes and
  uploads as its own asset. Immich's **Duplicate Detection** job flags them for review under **Utilities → Review
  duplicates**.

After a big batch, the server spends hours generating thumbnails, extracting metadata, transcoding video and running
the machine-learning jobs. Watch **Administration → Jobs**.

---

## Backups

Two layers, an hour apart:

| When  | What                                                                                         | Where                                         |
| ----- | -------------------------------------------------------------------------------------------- | --------------------------------------------- |
| 02:00 | Immich's built-in database dump, keeps 14                                                    | `library/backups/immich-db-backup-*.sql.gz` |
| 03:00 | `immich-backup.sh`: fresh `pg_dump` (keeps 3), `rsync` of originals and Immich's dumps | a staging directory                           |

The staging directory is what my regular off-box backup picks up. The 03:00 job then checks in with Uptime Kuma, so
a missed night raises an alert.

**What matters:** `library/library` and `library/upload` hold the originals, plus the database. Thumbnails
(`library/thumbs`) and transcoded video (`library/encoded-video`) can be regenerated, so the script skips them.

### `immich-backup.sh`

```bash
#!/usr/bin/env bash
# Stages Immich data and a fresh pg_dump for pickup by the standard backup.
# Runs as root: the bind-mount directories are owned by root and container users.
set -euo pipefail

IMMICH_DIR="/path/to/your/containers/immich"
STAGE_DIR="/path/to/your/backup-staging/immich"

DB_CONTAINER="immich-postgres"
DB_USER="postgres"
DB_NAME="immich"

mkdir -p "$STAGE_DIR"/{library,upload,backups,db}

# 1. Fresh database dump
echo "[immich-backup] Dumping database..."
podman exec "$DB_CONTAINER" pg_dump -U "$DB_USER" "$DB_NAME" | \
  gzip > "$STAGE_DIR/db/immich-$(date +%Y%m%d%H%M%S).sql.gz"

# Keep only the 3 newest dumps
find "$STAGE_DIR/db" -name '*.sql.gz' -printf '%T@ %p\n' | \
  sort -n | head -n -3 | awk '{print $2}' | xargs -r rm --

# 2. Originals (irreplaceable)
echo "[immich-backup] Syncing library..."
rsync -a --delete "$IMMICH_DIR/library/library/" "$STAGE_DIR/library/"

# 3. Originals still awaiting the storage template
echo "[immich-backup] Syncing uploads..."
rsync -a --delete "$IMMICH_DIR/library/upload/" "$STAGE_DIR/upload/"

# 4. Immich's own nightly DB dumps
echo "[immich-backup] Syncing Immich DB backups..."
rsync -a --delete "$IMMICH_DIR/library/backups/" "$STAGE_DIR/backups/"

echo "[immich-backup] Done."
```

### `immich-backup.service`

```ini
[Unit]
Description=Immich Backup (library + database)

[Service]
Type=oneshot
# See "The SELinux gotcha" below
SELinuxContext=system_u:system_r:unconfined_service_t:s0-s0:c0.c1023
ExecStart=/bin/bash /path/to/your/containers/bin/immich-backup.sh
TimeoutStartSec=3600
# Runs only if the backup succeeded. The leading "-" means a failed ping
# doesn't mark the backup failed. A missing ping is what raises the alert.
ExecStartPost=-/usr/bin/curl -fsS -m 10 --retry 2 "<UPTIME_KUMA_PUSH_URL>"
StandardOutput=journal
StandardError=journal
```

### `immich-backup.timer`

```ini
[Unit]
Description=Run Immich backup daily at 3:00 AM

[Timer]
OnCalendar=*-*-* 03:00:00
# Catch up after the server was off at 3 AM
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
```

In Uptime Kuma, create a **Push** monitor with a heartbeat interval a little over a day (for example 1500 minutes),
and use its URL as `<UPTIME_KUMA_PUSH_URL>`.

### Install the timer

```bash
sudo cp immich-backup.service immich-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now immich-backup.timer
sudo systemctl start immich-backup.service      # test run
sudo journalctl -u immich-backup.service -n 20 --no-pager
```

### The SELinux gotcha

The `:Z` on each `Volume=` gives that directory a **private** SELinux label, `container_file_t` plus a unique pair
of MCS categories (`s0:c123,c456`). Only that one container can touch it. That's the point of `:Z`, but it also
locks out the backup job.

A plain systemd service runs as `init_t:s0`, which has no MCS categories, so `rsync` and `find` get
`Permission denied` even as root. The `SELinuxContext=` line runs the backup as `unconfined_service_t` with the full
category range (`s0-s0:c0.c1023`), which can read every container's private label. It applies only to this
oneshot service, so SELinux stays enforcing for everything else.

### Test a restore

A backup you've never restored is only a hope. Every so often, load the newest dump into a throwaway Postgres
container and check that the tables exist:

```bash
sudo podman run -d --name immich-restore-test -e POSTGRES_PASSWORD=test \
  ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
sleep 15
sudo podman exec immich-restore-test createdb -U postgres immich
gunzip -c /path/to/your/backup-staging/immich/db/immich-<newest>.sql.gz | \
  sudo podman exec -i immich-restore-test psql -U postgres -d immich -q
sudo podman exec immich-restore-test psql -U postgres -d immich -c '\dt' | head
sudo podman rm -f immich-restore-test
```

Then open a few files in the staged `library/` and confirm they're real photos, not zero-byte files.

---

## Updates

### Automatic, within a major version

The server and machine-learning images use the `:v3` tag. Immich moves that tag with every v3.x release, but never
to v4. With `AutoUpdate=registry`, Podman's auto-update timer pulls the new v3.x image and restarts the unit:

```bash
sudo systemctl enable --now podman-auto-update.timer
sudo podman auto-update --dry-run                 # see what's pending
```

`podman auto-update` restarts each updated unit, and the `Requires=` chain restarts the units that depend on it.
If a unit fails to come back after an update, Podman rolls it back to the previous image. The Postgres and Valkey
tags are pinned, so auto-update only picks up rebuilds of those exact tags.

### Manual, across a major version

A major version is where things break. On the v2 to v3 jump, the mobile app, the CLI, and anything calling the API
all had to move together. Because the major is in the tag, auto-update can't make that jump for you. You make it on
purpose:

1. **Read the release notes** for every version up to the target:
   [github.com/immich-app/immich/releases](https://github.com/immich-app/immich/releases).
2. **Check whether Postgres has to move too.** For v2 to v3, the VectorChord image above was already correct. If
   you're on an older `pgvecto.rs` image, you can't jump straight to VectorChord. Go through an intermediate
   release first.
3. **Confirm last night's backups exist:**
   ```bash
   systemctl list-timers immich-backup.timer --no-pager
   sudo journalctl -u immich-backup.service -n 20 --no-pager
   ```
4. **Edit `Image=`** in the server and machine-learning quadlet sources to the new major tag, then deploy:
   ```bash
   sudo cp immich-server.container immich-machine-learning.container /etc/containers/systemd/immich/
   sudo systemctl daemon-reload
   sudo podman pull ghcr.io/immich-app/immich-server:v4 ghcr.io/immich-app/immich-machine-learning:v4
   sudo systemctl restart immich-server immich-machine-learning
   curl -s http://<YOUR_SERVER_LAN_IP>:2283/api/server/version
   ```
5. **Update the clients:** the phone app, and the CLI on every machine that uploads
   (`sudo npm install -g @immich/cli@<version>`).

Only deploy the edited unit files when you're ready to upgrade. Once `Image=` names the new major and `daemon-reload`
has run, the next restart or auto-update run makes the jump.

---

## Troubleshooting

| Symptom                                  | Cause / fix                                                                                                                                                                                             |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `413` on upload                        | Going through the Cloudflare tunnel. Upload to `http://<YOUR_SERVER_LAN_IP>:2283`.                                                                                                                    |
| TLS / `SSL` error on port `2283`     | Port 2283 is plain HTTP. Use `http://`.                                                                                                                                                               |
| `401 Unauthorized` from the CLI        | Wrong or revoked API key. `immich logout`, create a new key, log in again.                                                                                                                            |
| CLI errors right after a server update   | CLI and server versions differ. Reinstall the CLI at the server's version.                                                                                                                              |
| Smart search returns `500`             | Machine-learning container failing. `sudo journalctl -u immich-machine-learning -n 100`.                                                                                                              |
| Whole stack won't start                  | Something in the `Requires=` chain failed. Check `immich-postgres` first.                                                                                                                           |
| Backup service: `Permission denied`    | The service is missing its `SELinuxContext=` line. See [the SELinux gotcha](#the-selinux-gotcha).                                                                                                      |
| New uploads have no thumbnails for hours | Jobs still queued. Check **Administration → Jobs**.                                                                                                                                              |
| Phone app skips some photos              | The app only sees files in the phone's media index, grouped by the folder they really live in. Photos saved from Messenger or a browser often land in **Download**. Select that album in the app. |

### Repair jobs

Under **Administration → Jobs**, run the non-forced version for anything missing:

- Missing thumbnails: **Generate Thumbnails**
- Wrong dates or locations: **Extract Metadata**
- Storage template changed: **Storage Template Migration**
- Faces or smart search missing: **Face Detection** / **Smart Search**

---

## Useful Commands

```bash
# Stack status and logs
systemctl list-units 'immich*' --no-pager
sudo journalctl -u immich-server -n 100 --no-pager
sudo systemctl restart immich-server              # dependencies come along

# Server health from any LAN machine
curl -s http://<YOUR_SERVER_LAN_IP>:2283/api/server/ping       # {"res":"pong"}
immich server-info

# Disk use
sudo du -sh /path/to/your/containers/immich/library/*

# Backups
systemctl list-timers immich-backup.timer --no-pager
sudo journalctl -u immich-backup.service -n 20 --no-pager

# Pending image updates
sudo podman auto-update --dry-run
```

---

## Security Notes

- Keep `immich.env` owned by root with mode `600`. It holds the database password.
- Never forward port `2283` to the internet. Publish it through a tunnel or a TLS reverse proxy.
- Only the server publishes a port. Postgres, Valkey and machine learning stay on the internal network.
- Use one API key per machine or script, with only the permissions it needs.
- Keep the phone app and CLI in step with the server's major version.

---

## References

- [Immich Documentation](https://immich.app/docs/overview/introduction)
- [Immich Releases](https://github.com/immich-app/immich/releases)
- [Immich CLI](https://immich.app/docs/features/command-line-interface)
- [Immich Backup and Restore](https://immich.app/docs/administration/backup-and-restore)
- [Podman Quadlet Documentation](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
- [podman-auto-update](https://docs.podman.io/en/latest/markdown/podman-auto-update.1.html)
