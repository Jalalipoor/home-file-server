# Home File Server

A self-hosted family NAS built from a repurposed desktop PC, running Ubuntu Server 26.04 LTS with Samba.

It provides:

- Private per-user folders and a shared family drive over SMB (LAN-only)
- A pre-outage graceful shutdown that powers the server down cleanly before the daily scheduled power cut

This repository documents the setup and configuration. It is a documentation and configuration repo, not an application.

## Table of Contents

- [Hardware & OS](#hardware--os)
- [Storage layout](#storage-layout)
- [Samba shares](#samba-shares)
- [Security & maintenance](#security--maintenance)
- [Pre-outage graceful shutdown](#pre-outage-graceful-shutdown)
- [Installation](#installation)
- [Known limitations](#known-limitations)
- [Repository structure](#repository-structure)

## Hardware & OS

| Component | Details |
| --- | --- |
| Host | Old ASUS P8B75-M LX desktop, repurposed as a headless server (`jserver`) |
| OS | Ubuntu Server 26.04 LTS |
| System disk | LVM + ext4 (`/`), with separate `/boot` and `/boot/efi` |
| Data disk | 2 TB WD Purple HDD, ext4, mounted at `/srv/data` |
| Access | Headless, managed over SSH; Wake-on-LAN enabled |

## Storage layout

```text
/srv/data/
├── personal/<username>/   # private per-user folders (0700, owner-only)
└── shared/                # family shared storage (group jfamily)
    └── .recycle/          # Samba recycle bin instead of hard deletes
```

## Samba shares

Configured in [`configs/smb.conf`](configs/smb.conf).

- SMB3 minimum protocol, no guest access, LAN-only (`hosts allow`)
- `[Personal]` — private per-user share with `0600`/`0700` masks
- `[Shared]` — family share, group-writable (`jfamily`), with a Samba recycle
  bin (`vfs objects = recycle`) instead of permanent deletes
- Both shares include a soft-close toggle (`/run/samba-availability.conf`) so they can be set `available = no` before shutdown

## Security & maintenance

- UFW restricted to the home LAN subnet (`192.168.100.0/24`)
- SMB3 minimum protocol, anonymous access disabled
- `unattended-upgrades` enabled for automatic security patching
- `smartctl` (SMART) monitors the data drive's health

## Pre-outage graceful shutdown

Power to the house is cut daily around 16:00.
[`scripts/pre-outage-shutdown.sh`](scripts/pre-outage-shutdown.sh) runs at 15:45
via a root cron entry and shuts the server down cleanly beforehand:

| Time | Step |
| --- | --- |
| T-10 (15:45) | Write a visible warning file into the shared folder and broadcast a `wall` message to logged-in users |
| T-5 (15:50) | Set both shares to `available = no` so no new connections start |
| T-2 (15:53) | Log active SMB sessions, then stop `smbd`/`nmbd`/`wsdd` |
| T-1 (15:54) | Flush write caches (`sync`, `hdparm -F`), remount the data volume read-only, then power off |

Safety features:

- `flock` prevents concurrent runs
- A manual override file (`/run/no-auto-shutdown` or `/etc/no-auto-shutdown`) cancels that day's shutdown

Scheduling (root cron):

```text
45 15 * * * /usr/local/bin/pre-outage-shutdown.sh
```

## Installation

1. Install Ubuntu Server; partition the data HDD as ext4 and mount it at `/srv/data` (UUID-based, see [`configs/fstab.txt`](configs/fstab.txt)).
2. Create the `jfamily` group and per-user accounts; lay out `personal/<user>` and `shared/` under `/srv/data`.
3. Install and configure Samba with [`configs/smb.conf`](configs/smb.conf); enable the recycle-bin VFS module.
4. Lock down UFW to the LAN subnet and enable `unattended-upgrades`.
5. Add SMART monitoring for the data drive.
6. Install and schedule the shutdown script:

```bash
sudo install -m 0755 scripts/pre-outage-shutdown.sh /usr/local/bin/pre-outage-shutdown.sh
sudo crontab -e   # add: 45 15 * * * /usr/local/bin/pre-outage-shutdown.sh
```

## Known limitations

- **No off-disk backup.** With a single data HDD and no spare bay, a real
  backup (second disk or offsite) isn't currently possible. If a second drive
  is added, a nightly `rsync` job is the recommended next step.

## Repository structure

```text
.
├── configs/
│   ├── fstab.txt        # /etc/fstab (UUIDs redacted)
│   ├── netplan.yaml     # Netplan network config (Wake-on-LAN)
│   └── smb.conf         # Samba configuration
├── scripts/
│   └── pre-outage-shutdown.sh   # Pre-outage graceful shutdown script
├── .gitignore
├── LICENSE
└── README.md
```
