---
layout: home
title: "Roadhouse Labs"
---

**Field Notes from the Network** — practical self-hosting guides from Roadhouse Labs.
Written by an engineer whose background includes time as a Senior Network Engineer
at NASA and current work as a Senior Network DevOps Engineer at an international
organization with 10,000+ sites. These aren't toy examples — they're the actual
configs and lessons learned from building and maintaining real infrastructure at scale.

Everything here is documented to be reproducible, not just illustrative. Expect
full config files with every option explained, known gotchas called out, and
troubleshooting based on things that actually broke.

---

## Guides

- **[Pi-hole with Podman Quadlets]({{ '/guides/pihole-quadlet-guide' | relative_url }})** —
  Full installation guide: quadlet files explained line by line, firewall
  configuration, automated gravity updates, and Unbound integration.
- **[WireGuard Easy with Podman Quadlets]({{ '/guides/wg-easy-quadlet-guide' | relative_url }})** —
  Full installation guide: running wg-easy as a rootful Podman quadlet with
  nftables firewall hooks, client setup, and management tips.

---

## Latest Posts

- **[Why I Run My Own WireGuard VPN Server at Home]({% post_url 2026-05-14-wireguard-vpn %})** —
  Why I use WireGuard and wg-easy for clean remote access, safer travel connectivity,
  and predictable self-hosted VPN operations.
- **[Why I Run Pi-hole on My Home Network (And You Should Too)]({% post_url 2026-04-13-pihole-home-network %})** —
  Why DNS control matters at home, from ad blocking and malware prevention to
  privacy and network visibility.
