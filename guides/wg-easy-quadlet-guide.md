---
layout: page
title: "WireGuard Easy with Podman Quadlets"
permalink: /guides/wg-easy-quadlet-guide
description: "Full installation guide: running wg-easy as a rootful Podman quadlet with nftables firewall hooks, client setup, and management tips."
author: "Roadhouse Labs"
---

> **New to WireGuard?** Read the [overview post]({% post_url 2026-05-14-wireguard-vpn %}) first for the why before diving into the full setup.

---

## Overview

This guide walks through running [wg-easy](https://wg-easy.github.io/wg-easy/latest/) as a WireGuard VPN server with a web UI, deployed as a rootful Podman container managed by systemd quadlets. WireGuard provides a fast, modern, and auditable VPN, and in this setup I expose it through an ingress firewall that translates external UDP 4500 to the container host's UDP 51820.

The quadlet files live in `~/containers/quadlets/rootful/wg-easy/` and are deployed to `/etc/containers/systemd/wg-easy/`.

---

## Prerequisites

- Linux (systemd-based — Fedora, RHEL, CentOS Stream, Debian, Ubuntu)
- Podman 4.4+ (quadlet support built-in)
- systemd
- Root/sudo access
- `firewalld`
- WireGuard kernel module available (`wireguard` and `nft_masq`)

---

## Directory Structure

```
~/containers/quadlets/rootful/wg-easy/   # Source files — edit here, then deploy
  wg-easy.container
  wg-easy.network

/etc/containers/systemd/wg-easy/         # Deployed quadlet files (systemd reads from here)
  wg-easy.container
  wg-easy.network

/var/lib/containers/storage/volumes/wg-easy/   # WireGuard config and peer data (bind volume)
```

---

## Quadlet Files Explained

### `wg-easy.network`

Defines a dedicated bridge network for wg-easy with IPv6 support.

```ini
[Network]
NetworkName=wg-easy
IPv6=true
```

**Why a dedicated network?**
Isolates wg-easy traffic from other containers and gives it a predictable network context for nftables masquerade rules.

---

### `wg-easy.container`

```ini
[Unit]
Description=wg-easy WireGuard VPN
After=network-online.target
Wants=network-online.target

[Container]
ContainerName=wg-easy
Image=ghcr.io/wg-easy/wg-easy:15
AutoUpdate=registry

Volume=/var/lib/containers/storage/volumes/wg-easy:/etc/wireguard:Z
Network=wg-easy
PublishPort=51820:51820/udp
PublishPort=51821:51821/tcp

# Allows access over plain HTTP.
# Remove this line when you put a reverse proxy (Caddy, nginx) in front.
Environment=INSECURE=true

AddCapability=NET_ADMIN
AddCapability=SYS_MODULE
AddCapability=NET_RAW
Sysctl=net.ipv4.ip_forward=1
Sysctl=net.ipv4.conf.all.src_valid_mark=1
Sysctl=net.ipv6.conf.all.disable_ipv6=0
Sysctl=net.ipv6.conf.all.forwarding=1
Sysctl=net.ipv6.conf.default.forwarding=1

[Service]
Restart=on-failure
RestartSec=10s
TimeoutStartSec=900

[Install]
WantedBy=default.target
```

**Key settings explained:**

| Setting | Purpose |
|---|---|
| `AutoUpdate=registry` | Pulls updated image automatically (requires `podman-auto-update` timer) |
| `Volume=...:/etc/wireguard:Z` | Bind-mounts peer configs and keys; `:Z` sets SELinux label for rootful containers |
| `PublishPort=51820/udp` | WireGuard tunnel traffic on the host |
| `PublishPort=51821/tcp` | wg-easy web UI |
| `INSECURE=true` | Enables plain HTTP access — remove when using HTTPS via reverse proxy |
| `NET_ADMIN` / `SYS_MODULE` / `NET_RAW` | Required capabilities for WireGuard interface management |
| `Sysctl=net.ipv4.ip_forward=1` | Enables kernel IP forwarding so VPN clients can reach the internet |

---

## Installation

### 1. Load Kernel Modules

Create `/etc/modules-load.d/wg-easy.conf` to load modules on every boot:

```bash
sudo tee /etc/modules-load.d/wg-easy.conf <<EOF
wireguard
nft_masq
EOF
```

Load them immediately without rebooting:

```bash
sudo modprobe wireguard
sudo modprobe nft_masq
```

Verify:

```bash
lsmod | grep -E 'wireguard|nft_masq'
```

### 2. Create the Data Volume

The volume is a plain directory bind-mount — create it manually so Podman treats it as a bind volume rather than a named volume:

```bash
sudo mkdir -p /var/lib/containers/storage/volumes/wg-easy
```

> If you prefer Podman to track the volume: `sudo podman volume create wg-easy`

### 3. Deploy Quadlet Files

```bash
sudo mkdir -p /etc/containers/systemd/wg-easy
sudo cp ~/containers/quadlets/rootful/wg-easy/wg-easy.container \
        ~/containers/quadlets/rootful/wg-easy/wg-easy.network \
        /etc/containers/systemd/wg-easy/
sudo systemctl daemon-reload
```

### 4. Configure the Host Firewall

```bash
# WireGuard tunnel on the container host
sudo firewall-cmd --permanent --add-port=51820/udp

# wg-easy web UI (only if accessing directly without a reverse proxy)
sudo firewall-cmd --permanent --add-port=51821/tcp

sudo firewall-cmd --reload
```

If your edge firewall or router translates external UDP 4500 to this host's UDP 51820, do that on the ingress device, not on the server itself. The host only needs UDP 51820 open locally.

Verify:

```bash
sudo firewall-cmd --list-ports
```

### 5. Start the Service

```bash
sudo systemctl start wg-easy
sudo systemctl status wg-easy
```

To enable on boot:

```bash
sudo systemctl enable wg-easy
```

Verify the container is running:

```bash
sudo podman ps
```

---

## Configure WireGuard NAT (nftables Hooks)

wg-easy handles NAT through PostUp/PostDown hooks configured in its web UI. These hooks add and remove nftables rules when the WireGuard interface comes up and down.

### Access the Web UI

Navigate to `http://your-server-ip:51821` and log in.

Go to the **Hooks** tab and add the following:

**PostUp Hook:**

```bash
nft add table inet wg_table; nft add chain inet wg_table prerouting { type nat hook prerouting priority 100 \; }; nft add chain inet wg_table postrouting { type nat hook postrouting priority 100 \; }; nft add rule inet wg_table postrouting ip saddr {{ipv4Cidr}} oifname {{device}} masquerade; nft add rule inet wg_table postrouting ip6 saddr {{ipv6Cidr}} oifname {{device}} masquerade; nft add chain inet wg_table input { type filter hook input priority 0 \; policy accept \; }; nft add rule inet wg_table input udp dport {{port}} accept; nft add rule inet wg_table input tcp dport {{uiPort}} accept; nft add chain inet wg_table forward { type filter hook forward priority 0 \; policy accept \; }; nft add rule inet wg_table forward iifname "wg0" accept; nft add rule inet wg_table forward oifname "wg0" accept;
```

**PostDown Hook:**

```bash
nft delete table inet wg_table
```

The `{{ipv4Cidr}}`, `{{ipv6Cidr}}`, `{{device}}`, `{{port}}`, and `{{uiPort}}` placeholders are substituted by wg-easy at runtime.

---

## Client Setup

### Create a Client

1. Click **"+ New"** in the web UI
2. Enter a descriptive name (e.g., `john-iphone`, `work-laptop`)
3. Click **"Create"**

### Configure the Endpoint (Port Forwarding)

If your ingress firewall or router forwards a non-standard external port such as `4500` to this host's `51820`, configure clients to use the external port:

1. Click the **Administrator** icon (top right)
2. Go to **Config -> Connection**
3. Set the endpoint to `your-public-ip-or-domain:4500`
4. Click **Save**

> **Why port 4500?** It is the standard IPsec NAT traversal port and is commonly allowed through corporate and public firewalls. To restrictive networks, your WireGuard traffic looks like IPsec.

### Connect a Device

| Method | Best for |
|---|---|
| **QR code** | Phones and tablets — scan directly in the WireGuard app |
| **Download `.conf`** | Desktops and laptops — import the file into the WireGuard app |
| **Copy config text** | Advanced/scripted setups |

**Linux client:**

```bash
sudo cp wg0.conf /etc/wireguard/wg0.conf
sudo wg-quick up wg0

# Enable on boot
sudo systemctl enable wg-quick@wg0
```

### Verify the Connection

```bash
# Your public IP should show the VPN server's IP
curl ifconfig.me

# Ping the WireGuard gateway (default: 10.8.0.1)
ping 10.8.0.1
```

In the wg-easy UI, a green indicator and updating "Last Seen" timestamp confirm the client is connected.

---

## Useful Management Commands

### Service

```bash
sudo systemctl restart wg-easy
sudo systemctl stop wg-easy
sudo systemctl status wg-easy
```

### Logs

```bash
sudo journalctl -u wg-easy -f
sudo journalctl -u wg-easy -n 200 --no-pager
sudo podman logs wg-easy --tail 200
```

### Container & Network

```bash
# List running containers
sudo podman ps -a

# Check active WireGuard peers
sudo podman exec wg-easy wg show wg0

# Check interface addresses
sudo podman exec wg-easy ip -4 -6 addr show dev wg0

# Check listening ports
sudo ss -tulpn | grep -E '51820|51821'

# Verify nftables rules are active
sudo nft list ruleset | grep -A 20 wg_table
```

---

## Troubleshooting

### Network won't start

If systemd reports it can't find the `wg-easy` network, create it manually then restart:

```bash
sudo podman network create wg-easy --ipv6
sudo systemctl daemon-reload
sudo systemctl start wg-easy
```

### Clients connect but have no internet

- Confirm the PostUp hook ran: `sudo nft list ruleset | grep wg_table`
- Confirm IP forwarding is active: `sysctl net.ipv4.ip_forward` (should be `1`)
- Check container logs: `sudo journalctl -u wg-easy -n 100 --no-pager`

### Verify firewall rules

```bash
sudo firewall-cmd --list-all
sudo nft list ruleset
```

### Full teardown (destructive)

Use this to wipe everything and start clean:

```bash
sudo systemctl stop wg-easy
sudo systemctl disable wg-easy
sudo podman rm -f wg-easy
sudo podman network rm wg-easy
sudo rm -rf /var/lib/containers/storage/volumes/wg-easy
sudo rm -rf /etc/containers/systemd/wg-easy
sudo rm -f /etc/modules-load.d/wg-easy.conf
sudo systemctl daemon-reload
sudo nft delete table inet wg_table 2>/dev/null || true
sudo podman system prune -f
```

---

## Security Notes

- Remove `Environment=INSECURE=true` once you have a reverse proxy with HTTPS in front of port 51821
- Change the default admin password immediately after first login
- Disable unused clients rather than deleting them — easier to re-enable if needed
- Enable `AutoUpdate=registry` + `podman-auto-update.timer` to keep the image patched
- The `wg0` interface is only as secure as the private keys stored in `/var/lib/containers/storage/volumes/wg-easy` — restrict access to that directory

---

## References

- [wg-easy Official Documentation](https://wg-easy.github.io/wg-easy/latest/)
- [Podman Quadlet Documentation](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
- [WireGuard Official Site](https://www.wireguard.com/)
- [WireGuard Client Apps](https://www.wireguard.com/install/)
