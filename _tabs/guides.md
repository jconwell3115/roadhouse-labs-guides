---
title: Guides
icon: fas fa-book
order: 1
---

Technical self-hosting guides with full configurations and real-world gotchas documented.

---

### DNS & Networking

- **[Pi-hole with Podman Quadlets]({{ '/guides/pihole-quadlet-guide' | relative_url }})** —
  Network-wide DNS sinkhole running as a rootful Podman container managed by
  systemd quadlets. Covers full quadlet file breakdown, firewall configuration,
  automated gravity updates, and optional Unbound integration.

### VPN

- **[WireGuard Easy with Podman Quadlets]({{ '/guides/wg-easy-quadlet-guide' | relative_url }})** —
  Full installation guide: running wg-easy as a rootful Podman quadlet with
  nftables firewall hooks, client setup, and management tips.

### Remote Access (No Open Ports)

- **[Cloudflare Tunnel with Podman Quadlets]({{ '/guides/cloudflare-tunnel-quadlet-guide' | relative_url }})** —
  Expose self-hosted services without port forwarding: moving a domain to Cloudflare
  DNS, running `cloudflared` as a rootful Podman quadlet, routing hostnames through
  the tunnel, and gating admin UIs with Cloudflare Access.
