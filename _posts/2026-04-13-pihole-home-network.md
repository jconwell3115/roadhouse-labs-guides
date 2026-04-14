---
layout: post
title: "Why I Run Pi-hole on My Home Network (And You Should Too)"
date: 2026-04-13
categories: networking dns self-hosting
tags: [pihole, dns, podman, security, networking]
author: "Roadhouse Labs"
---

I spent years as a Senior Network Engineer at NASA, where controlling DNS wasn't
a preference — it was a security requirement. Every device on a managed network,
from workstations to infrastructure hardware, had its DNS tightly controlled and
monitored. Uncontrolled DNS resolution was treated as a network hygiene failure,
not an acceptable gap.

I'm now working as a Senior Network DevOps Engineer at an international
organization supporting infrastructure across 10,000+ sites. The environment is
different, but the discipline is the same. I apply the same rigor to the
infrastructure I run at home as I do to production systems at work.

Most home networks hand DNS off entirely to whatever the ISP provides, or at
best point everything at Cloudflare or Google. That works, but it means you have
zero visibility into what your devices are querying, zero ability to block
malicious domains before a connection is made, and you're placing full trust in
a third party for something as foundational as name resolution.

Pi-hole changes that. It's what I run at home, and this post explains why it
matters and how to get it set up properly.

---

## What Is Pi-hole?

Pi-hole is a **network-wide DNS sinkhole**. It runs on your local network and acts
as the DNS server for all your devices. When a device tries to look up an ad
network, tracking domain, or known malware host, Pi-hole returns nothing — the
request dies before it ever leaves your network.

Unlike browser extensions that block ads on a single device, Pi-hole works at the
network level. That means every device benefits automatically: phones, TVs, game
consoles, smart home devices — anything that uses DNS.

---

## Why Does This Matter?

**Ads and tracking** are the obvious win, but that's just the start.

Most malware, ransomware, and spyware rely on DNS to communicate with
attacker-controlled servers (called command-and-control, or C2). By routing all
DNS through a resolver you control, you gain:

- **Visibility** — a query log of every domain every device on your network has
  tried to reach
- **Blocking** — malware and phishing domains stopped before a connection is made
- **Hardcoded DNS bypass prevention** — when combined with a firewall rule that
  redirects all outbound port 53 traffic to Pi-hole, even devices that ignore your
  DHCP DNS setting get filtered
- **Privacy** — with Unbound added alongside Pi-hole, DNS queries go directly to
  root servers instead of Cloudflare or Google

This is especially important for network devices like routers, switches, and IoT
hardware. Many of these hardcode public DNS servers in their firmware, meaning they
bypass whatever DNS you configure via DHCP. Pi-hole plus a firewall DNS intercept
rule closes that gap entirely.

---

## How It Works

```
Your Device
    │
    ▼  DNS query: "what's the IP for ads.example.com?"
Pi-hole
    │
    ├─ Blocked domain? → Return NXDOMAIN (nothing) ──► Request dies here
    │
    └─ Legitimate domain? → Forward upstream
           │
           ├─ Option A: Cloudflare / Google (simple, less private)
           │
           └─ Option B: Unbound (recursive resolver, queries root servers directly)
                   │
                   ▼
             Authoritative DNS → IP returned → Pi-hole → Your Device
```

Pi-hole maintains a **gravity database** — a compiled list of millions of known
ad, tracking, and malicious domains. You can add additional blocklists and it
updates automatically on a schedule.

---

## What You'll Need

- A Linux server or mini PC on your network (a Raspberry Pi, an old NUC, a VM, a
  VPS — anything that stays on)
- About 15–30 minutes for initial setup

The setup guide uses **Podman** (a daemonless, rootless-capable container runtime)
and **systemd quadlets** to manage Pi-hole as a system service. This approach is
more maintainable than bare `docker run` commands and integrates cleanly with the
rest of your Linux system.

---

## Get Started

Ready to set it up? The full installation guide covers:

- The quadlet files with every option explained
- Firewall configuration (including a known gotcha with masquerade rules and
  container restarts)
- Automated weekly blocklist updates with logging
- Adding Unbound for full DNS privacy
- Troubleshooting common issues

**[Pi-hole with Podman Quadlets — Full Setup Guide →]({{ '/guides/pihole-quadlet-guide' | relative_url }})**

---

## Further Reading

- **Linux installation** — [Ubuntu Server](https://ubuntu.com/tutorials/install-ubuntu-server)
  or [Fedora Server](https://docs.fedoraproject.org/en-US/fedora-server/)
- **Pi-hole Documentation** — [docs.pi-hole.net](https://docs.pi-hole.net/)
- **Podman Documentation** — [podman.io/docs/installation](https://podman.io/docs/installation)
