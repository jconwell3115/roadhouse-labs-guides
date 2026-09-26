---
layout: post
title: "Why I Expose Home Services Through a Cloudflare Tunnel (With Zero Open Ports)"
date: 2026-09-25
categories: networking self-hosting security
tags: [cloudflare, cloudflared, tunnel, zero-trust, podman, quadlet, dns]
author: "Roadhouse Labs"
---

Every self-hosted service eventually hits the same question: how do I reach it from outside the house?

The traditional answer is a port forward. Open 443 on the router, point it at a reverse proxy, get a certificate, and hope nothing behind it has a bad week. It works, but it means your home IP is listening on the internet and showing up in every mass scan. Your security then depends on every app behind that port staying patched.

I don't forward any web ports anymore. Everything I publish goes through a Cloudflare Tunnel: one small `cloudflared` container that makes an **outbound** connection to Cloudflare and carries requests back down it. The router has nothing open for web traffic.

---

## Why It Matters

- **No inbound attack surface.** There's no listening port on the WAN to scan, fingerprint or brute-force. The connection starts from inside the network.
- **Your IP stays out of DNS.** Tunneled hostnames are CNAMEs to the tunnel, not A records pointing at your house.
- **Dynamic IPs stop mattering.** When the ISP changes the WAN address, the tunnel just reconnects, with no DNS updates or stale records.
- **Identity at the edge.** Cloudflare Access puts a login in front of admin tools like Pi-hole, Portainer and Vault, so a request that isn't mine never reaches my network.
- **One config file is the whole map.** Every public hostname and where it goes lives in a single, version-controlled `config.yml`.

---

## How I Split It

Not everything should be exposed the same way:

- **Public apps with their own clients** (Nextcloud, Immich) go straight through the tunnel. They have their own authentication, and their mobile apps need direct API access.
- **Admin interfaces** (Pi-hole, Portainer, Vault, Cockpit, wg-easy, Uptime Kuma) go through the tunnel **and** sit behind a Cloudflare Access policy that only allows my email address.
- **WireGuard** stays a forwarded UDP port, because a tunnel only carries web traffic. The VPN is the one deliberate hole, and it only answers clients holding a valid key.

The tradeoff is real: you're trusting Cloudflare to terminate TLS for those hostnames, and proxied uploads are capped at 100 MB on the free plan. For a home lab, I think that's a good deal compared to running the edge myself.

---

## What You'll Need

- A domain on Cloudflare DNS (moving an existing one takes a few minutes of registrar work)
- A free Cloudflare account, with Zero Trust enabled for Access
- A Linux host running Podman with quadlet support
- The services you want to publish, already running locally
- About 30 to 45 minutes for the first setup

---

## Get Started

The full setup guide covers:

- moving a domain to Cloudflare and the zone settings worth changing
- creating a locally managed tunnel with the `cloudflared` container, with nothing installed on the host
- the `config.yml` ingress rules and the rootful quadlet, explained line by line
- routing DNS through the tunnel and locking admin UIs behind Cloudflare Access
- verification, troubleshooting (1033s, 502s, 404s) and the gotchas I actually hit

**[Cloudflare Tunnel with Podman Quadlets: Full Setup Guide ->]({{ '/guides/cloudflare-tunnel-quadlet-guide' | relative_url }})**

---

## Further Reading

- **Cloudflare Tunnel Documentation**: [developers.cloudflare.com](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- **Cloudflare Access**: [developers.cloudflare.com](https://developers.cloudflare.com/cloudflare-one/applications/configure-apps/self-hosted-apps/)
- **Podman Quadlet Documentation**: [docs.podman.io](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
