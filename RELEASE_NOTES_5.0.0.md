# PHLS 5.0.0 · Dashboard 3.0.0

The biggest update so far. PHLS 5.0 has a **new engine** that is several times faster, a **dashboard you manage everything from**, **per-server upstream statistics**, **report profiles**, and **one-click updates**. It installs with one command and needs no cron jobs or folder setup any more.

**Install, or upgrade from v4:**
```bash
curl -sSL https://github.com/panoc/pihole-latency-stats/releases/latest/download/install_phls.sh | sudo bash
```
Then open `http://<your-pi-ip>:8080/`.

> ⚠️ **PHLS 5.0 needs Pi-hole v6**, installed directly on the machine (not in Docker), on a system with systemd. The dashboard moves to its **own address**, `http://<pi>:8080/`; the old address forwards there. See [Upgrading from v4](#-upgrading-from-v4).

---

## ⚡ Much faster, lighter on the Pi

The analysis engine was rewritten from scratch. On a test database with 3 million queries:

| | v4.4 | 5.0 |
|---|---|---|
| Full analysis | 10.0 s | **2.3 s** |
| CPU time | 37 s | **3.2 s** |
| Memory | ~760 MB | **~65 MB** |
| Database copy (`-snap`) | 146 MB | **none** |

- **Reads the database once,** spread over all CPU cores. v4.4 read it about 14 times per run and sorted millions of rows.
- **Exact medians and 95th percentiles without sorting.** Only the few rows that matter are read again. The results are identical to a full sort.
- **Daily cache:** finished days are counted once, so a normal run reads only the newest hours. On 2.7 million queries: 2.1 s → **0.8 s** per run. On a Pi Zero 2 W, v4.4 needed about **1 min 40 s** per dashboard run.
- **Fewer SD-card writes:**
  - no database copy;
  - the history file grows by a few hundred bytes per run instead of being rewritten;
  - temporary data stays in RAM.

## 🚀 One-command install, no setup

- **One command** installs everything and asks at most two questions. It reads Pi-hole's own settings and installs what is missing.
- **Its own small web server** on its own port (usually 8080). Pi-hole updates can no longer delete the dashboard, and Pi-hole's web server isn't touched.
- **Standard locations:** `/opt/phls` (program), `/etc/phls` (settings), `/var/www/phls` (dashboard), `/var/lib/phls` (cache), `/var/log/phls` (logs).
- **systemd timers instead of cron:** runs never overlap, and profiles run one after the other.
- **The `phls` command** replaces `cronmaker.sh` and the uninstaller: `sudo phls` opens a menu; `phls status`, `run`, `edit`, `add`, `delete`, `clear`, `reset`, `update`, `uninstall`.

## ⚙ Manage everything from the dashboard

- **⚙ Manage:** add, delete and switch profiles; change every setting; run reports; update PHLS. Changes are protected by your **Pi-hole password**, which Pi-hole itself checks and PHLS never stores.
- **Next run countdown** in the header, and a **▶ Run now** button (no password needed).
- **Save & apply** reruns the analysis right away. Changed settings are marked, and **Undo** puts them back.
- **Clear history** starts one profile's charts over. **Reset everything** starts all statistics from zero, including Pi-hole's stored queries and logs and Unbound's cache. It shows exactly what will be deleted and asks you to type `RESET`.
- **Tiers in any order:** they are sorted when you save.
- **Themes** (dark, light, high contrast) in the footer, and a **profile menu** in the header.

## 🌐 Upstream statistics, server by server

- **Every upstream server gets its own chart,** with a server selector and a **comparison table**: share, replies, average, median, 95th percentile and replies over 1 s.
- **Real upstream speed:**
  - **Unbound's cache answers** (replies under 4 ms from Unbound on the same machine) are counted separately: *"Unbound answered 84% of its replies from its own cache"*. Other servers are always counted in full. In v4, every fast reply was dropped, whatever the server.
  - **Conditional forwarding** (local names sent to your router) is no longer counted as upstream.
  - **Reverse lookups (PTR)** are left out of the latency statistics by default.
- **Optional:** group servers of the same provider (e.g. Cloudflare's 1.1.1.1 and 1.0.0.1) into one.

## 🔄 Unbound

- Unbound's stats are shown **only when Pi-hole actually uses Unbound**. Otherwise the card says why: *Not installed*, *Not used*, *Not running*, *Off* or *Error*.
- Unbound's cache counts now come from its statistics, without dumping the cache, so they no longer pause DNS.

## 🎯 Profiles and reports

- **Domains** is a normal setting on every profile. It accepts:
  - a word (`youtube`: any domain containing it);
  - a name (`github.com`: it and its subdomains);
  - an exact name (`=youtube.com`);
  - patterns with `*`;
  - **several at once**: `youtube.com,googlevideo.com,ytimg.com`.
- **Report profiles:** they never run on a schedule. Press **📄 Run report** for the classic text report, for **all data**, the **last N hours or days**, or **from – to dates**, with all, upstream or Pi-hole-only queries. **Download** it as a `.txt` file or **copy** it.
- On domain-filtered profiles, Unbound's all-domain counters are hidden (they can't follow a filter), while the upstream statistics still follow it.

## 🔔 Updates in one click

- PHLS checks for a new release **once a day**. A yellow badge on **⚙ Manage** shows it (e.g. `⬆ 5.0.1`).
- **⚙ Manage → PHLS → Update:** downloads the release, **verifies its checksum**, and reinstalls. Settings and history are kept. Or use `sudo phls update`.

## 🛡️ Safer

- Settings files are **read, never executed**.
- The dashboard never writes settings itself. It hands each change to a root service that checks every value again against a fixed list.
- Paths, the database and extra command-line arguments can't be changed from the web at all.

## 🐞 Fixed

- Profiles with extra arguments never updated their dashboard (they silently ran in text mode).
- Domain filters containing `'` caused an error.
- Invalid JSON when Unbound reported zero queries.
- The dashboard retried every second after a failed load; now every 10 seconds.

---

## 📦 Upgrading from v4

Run the install command above. It:

- **moves your profiles over:** tiers, cutoffs, history size, schedule and domain filter;
- **keeps your history**;
- **switches off the old PHLS cron jobs:** it asks first, comments them out rather than deleting them, and leaves your other cron jobs alone;
- **forwards the old dashboard address** to the new one;
- **leaves `~/phls` untouched** as a backup. Delete it when you're happy: `sudo rm -rf ~/phls`.

**Good to know:**
- `cronmaker.sh`, `phls_uninstall.sh` and `phls_version_check.sh` are gone. Use `sudo phls` and the dashboard instead.
- `-snap` is still accepted but does nothing; it isn't needed any more.
- Values in settings files are now taken literally, so `$HOME` and similar are no longer expanded.
- The first run reads the whole database once to fill the cache, which can take up to a minute on a Pi Zero with millions of queries. After that, runs are fast.

📖 **[User Guide](https://github.com/panoc/pihole-latency-stats/blob/main/docs/USAGE.md)** · **[Command Line](https://github.com/panoc/pihole-latency-stats/blob/main/docs/COMMAND_LINE.md)** · **[Manual / Offline Installation](https://github.com/panoc/pihole-latency-stats/blob/main/docs/MANUAL_INSTALLATION.md)**
