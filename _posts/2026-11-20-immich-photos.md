---
layout: post
title: "Why I Self-Host My Photos With Immich"
date: 2026-11-20
categories: self-hosting storage
tags: [immich, photos, podman, quadlet, backups, postgres]
author: "Roadhouse Labs"
---
Photos are the one thing in my house I can't regenerate. Configs live in Git, media can be re-ripped, and a dead
container just gets pulled again. But a decade of phone pictures exists once. For a long time that "once" was someone
else's cloud, on someone else's storage tiers and pricing.

Immich changed that. It's a self-hosted photo and video library with a phone app that backs up automatically, a fast
timeline, face recognition, and natural-language search ("beach at sunset"), all running on my own server. The
machine-learning models run locally, so nothing about my photos leaves the house to get tagged.

---

## Why It Matters

- **I own the originals.** Uploaded files land on my disk in plain date folders (`2026/2026-07-04/IMG_1234.jpg`).
  If Immich disappeared tomorrow, the library is still just files.
- **The smart features stay local.** Faces, smart search, OCR and duplicate detection run in a machine-learning
  container on the same box.
- **The phone app works like the big-name apps.** Background backup, shared albums, and browsing from anywhere.
- **It's backed up the way I want.** Two nightly layers, monitored, staged for my normal off-box backup.

---

## How I Run It

Immich isn't one container, it's four: the server, machine learning, a Postgres database with a vector-search
extension, and a Redis-compatible cache (Valkey). I run all four as **rootful Podman quadlets**, so they're plain
systemd services. They are ordered with `Requires=` and `After=`, and one command starts the whole stack:

```bash
sudo systemctl start immich-server.service
```

systemd brings up Postgres and Valkey first, then machine learning, then the server.

A few decisions that came from running it for real:

- **Updates are automatic, but only inside a major version.** The images use the `:v3` tag with
  `AutoUpdate=registry`, so patch and minor releases arrive on their own. A jump to v4 never happens by itself. I
  learned that one on the v2 to v3 upgrade: a major version can change the API, the mobile app and the CLI, so I
  want to read the release notes and check backups before it happens.
- **Big uploads go over the LAN, not the tunnel.** The web UI and phone app are published through my
  [Cloudflare Tunnel]({% post_url 2026-09-25-cloudflare-tunnel %}), but Cloudflare rejects request bodies over
  100 MB with `HTTP 413`. Phone videos blow past that easily. Bulk uploads go straight to the server on the LAN
  with the Immich CLI.
- **Backups are two layers.** Immich dumps its own database every night. An hour later, a systemd timer takes a
  fresh `pg_dump`, syncs the original files into a staging folder for the main backup, and checks in with Uptime
  Kuma. If the check-in doesn't arrive, I hear about it.
- **SELinux stays on.** That made the backup job harder to write (more on that in the guide), but it's still a
  better trade than turning SELinux off.
- **A shared env file can bite.** All the containers read one `immich.env`. I'd put the server's port in it,
  and the machine-learning container read the same variable and moved off its own port. Face detection and OCR
  failed quietly for two weeks while everything else looked fine. Now the shared file holds only what every
  container needs, and the ML port is pinned in its own quadlet.

---

## What You'll Need

- A Linux host with Podman 4.4+ and systemd (I use Fedora)
- Enough disk for your library, plus room for thumbnails and transcoded video
- An SSD for the Postgres data if you can
- 4 GB of RAM at minimum; the machine-learning container wants more on a big first import
- About an hour for setup, then hours (or days) for the first import to finish processing

---

## Get Started

The full guide covers:

- the network and all four quadlets, explained line by line
- why `Requires=` chains matter, and what they do when you restart one piece
- uploading from a workstation with the Immich CLI, and how duplicates are handled
- the nightly backup timer, including the SELinux context it needs
- updates: automatic within a major, and the checklist for the next major jump
- the troubleshooting table I wish I'd had

**[Immich with Podman Quadlets: Full Setup Guide ->]({{ '/guides/immich-quadlet-guide' | relative_url }})**

---

## Further Reading

- **Immich Documentation**: [immich.app/docs](https://immich.app/docs/overview/introduction)
- **Immich Releases**: [github.com/immich-app/immich/releases](https://github.com/immich-app/immich/releases)
- **Podman Quadlet Documentation**: [docs.podman.io](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
