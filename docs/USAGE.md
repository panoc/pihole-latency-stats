# 📘 Pi-hole Latency Stats 5.0: User Guide

This guide covers everything you can do with PHLS 5.0 (dashboard 3.0), from the dashboard to the settings, profiles, reports and updates. You don't need the command line for any of it. Where a command exists, it is mentioned for those who prefer it; all commands are in the [Command Line guide](COMMAND_LINE.md).

## 📑 Contents

1. [How PHLS works](#1-how-phls-works)
2. [The dashboard](#2-the-dashboard)
3. [Managing PHLS from the dashboard](#3-managing-phls-from-the-dashboard)
4. [All settings explained](#4-all-settings-explained)
5. [Profiles](#5-profiles)
6. [Reports](#6-reports)
7. [Upstream statistics](#7-upstream-statistics)
8. [Unbound](#8-unbound)
9. [Starting over: Clear history and Reset everything](#9-starting-over-clear-history-and-reset-everything)
10. [Updating](#10-updating)
11. [Upgrading from v4](#11-upgrading-from-v4)
12. [What the numbers mean](#12-what-the-numbers-mean)
13. [Files and folders](#13-files-and-folders)
14. [Troubleshooting](#14-troubleshooting)
15. [Uninstalling](#15-uninstalling)

---

## 1. How PHLS works

Pi-hole records every DNS query in its database, together with how long the answer took. PHLS reads that database **on a schedule** (every 5 minutes by default) and works out:

- how fast Pi-hole answered: the average, median and 95th percentile, and how many queries fell into each speed tier;
- how fast your **upstream** servers answered, server by server;
- how Unbound is doing, if you use it.

The results go to the dashboard, and every run also adds a point to the **history charts**.

A few things worth knowing:

- **Nothing is estimated.** The numbers are exact, even with millions of queries.
- **It is light.** Days that are over are counted once and kept in a small cache, so a normal run reads only the last few hours. The very first run after installing reads the whole database once; on a Pi Zero with millions of queries that can take up to a minute.
- **It only reads Pi-hole's data.** PHLS never changes Pi-hole, except when you explicitly choose *Reset everything* (see [section 9](#9-starting-over-clear-history-and-reset-everything)).
- **It has its own small web server** on its own port (usually 8080), separate from Pi-hole's. Pi-hole updates can't break it.

---

## 2. The dashboard

Open `http://<your-pi-ip>:8080/` in a browser. If you don't remember the address, run `phls status` on the Pi.

### Header

| Item | What it is |
|---|---|
| **Last Analysis** | When the shown numbers were calculated. If it turns red (**DATA STALE**), the analysis hasn't run for a while; see [Troubleshooting](#14-troubleshooting). |
| **Next run in 37 min** | Countdown to the next scheduled analysis. |
| **▶ Run now** | Runs the analysis right away, without waiting for the schedule. No password needed. While it runs, the header says *Running now…*, and the page refreshes by itself when it's done. It works at most once a minute per profile. |
| **Auto-refresh in 60s** | The page checks for new data every minute. It downloads the history only when a new analysis has run. |
| **default ▾** | Switches between your dashboard profiles (shown when you have more than one). |
| **⚙ Manage** | Profiles, settings, reports and updates. A yellow badge like `⬆ 5.0.1` means an update is available. |

### Cards

- **System performance overview:** Pi-hole's totals (queries, blocked, analyzed) and its average, median and 95th percentile, next to Unbound's hits, misses, prefetch and cache memory.
- **Pi-hole (global) latency distribution:** every answered query, grouped into your speed tiers. Use the buttons **12H · 24H · 7D · 30D · All Time · Custom** to pick the time range.
- **Pi-hole (upstream) latency distribution:** only the queries that Pi-hole sent to an upstream server. With more than one upstream server you get a **server selector** and a **comparison table**; see [section 7](#7-upstream-statistics).
- **Unbound:** Unbound's own response times, cache hit rate, cache memory and cached items. If there is nothing to show, the card says why, e.g. *Not installed* or *Not used*; see [section 8](#8-unbound).
- **History charts:** one point per analysis, for Pi-hole, upstream and Unbound.

### Chart controls

| Button | What it does |
|---|---|
| **Log** | Logarithmic scale, so a few huge spikes don't flatten everything else. |
| **↔** | Scroll through long history instead of squeezing it into the screen. |
| **Bar / Line** | Switch the chart type. |
| **↑ ↓** | Move the card up or down. |
| **−** | Collapse or expand the card. |

Your layout, collapsed cards, chart types and theme are remembered by your browser.

### Themes

Choose **dark**, **light** or **high contrast** at the bottom of the page.

---

## 3. Managing PHLS from the dashboard

Click **⚙ Manage**. The window has two tabs.

### Profiles tab

A list of your profiles, with a row of buttons for each one:

| Button | Dashboard profile | Report profile |
|---|---|---|
| **Settings** | Opens its settings | Opens its settings |
| **▶ Run now / 📄 Run report** | Runs the analysis now | Makes a new text report |
| **Open / View report** | Shows this profile's dashboard | Shows the last report |
| **Clear history** | Starts its history charts over | — |
| **Delete** | Deletes the profile and its history | Deletes the profile and its last report |

Below the list you can **add a profile**; see [section 5](#5-profiles).

### Settings

Click **Settings** on a profile. The bar at the top always stays visible:

`← Profiles · 📄 Run report · View last report` on the left (the report buttons only for report profiles), and **Undo changes · Save & apply** on the right.

- Change anything you like. Changed settings are marked with a yellow dot, **Undo changes** lights up, and **Save & apply** turns green.
- **Save & apply** saves the changes and runs the analysis again with them. For a dashboard profile the window closes, and a notice in the bottom-right corner follows the progress. A report profile stays open, so you can run the report next.

### PHLS tab

The installed version, the latest release, **Check for updates**, **Update**, and **Reset everything**; see [section 9](#9-starting-over-clear-history-and-reset-everything).

### The password

Changes (saving settings, adding or deleting profiles, reports, updates) need your **Pi-hole password**, and the 2FA code if you use one.

- Pi-hole itself checks the password; PHLS never stores it.
- It stays in the field until you close or reload the page, so you type it once per visit.
- *Run now* on a dashboard profile needs no password.
- **If Pi-hole has no password**, anyone on your network can change PHLS's settings. The window warns you about this.
- If Pi-hole is set not to check passwords for requests from the machine itself (`webserver.api.localAPIauth = false`), changing settings from the dashboard is turned off. Use `sudo phls edit` instead.

---

## 4. All settings explained

Each profile has its own settings. Dashboard profiles and report profiles show only the settings that apply to them.

### Profile

| Setting | What it does |
|---|---|
| **Profile type** | **dashboard**: runs on the schedule and fills its charts. **report**: runs only when you ask and gives a text report. The *default* profile is always a dashboard profile. |
| **Domains** | Count only some domains. Empty = all queries. See [Domains](#domains) below. Changing it on a dashboard profile clears that profile's history, because the old points counted other queries. |

### Report *(report profiles only)*

| Setting | What it does |
|---|---|
| **Time range** | **all data**, the **last N hours**, the **last N days**, or **from – to** (fixed dates). |
| **From / To** | Used with *from – to*. An empty **To** means "until now". |
| **Queries** | **all**: every answered query. **upstream**: only queries Pi-hole forwarded to an upstream server. **pihole**: only queries Pi-hole answered itself (from its cache or local records). |
| **Leave out special blocks (-nx)** | Leaves out replies Pi-hole gave for special domains and from its stale cache (statuses 16 and 17). |
| **Unbound section** | **include**: add Unbound's stats (when Pi-hole uses Unbound). **only**: Unbound's stats only. **none**: leave them out. |

### Schedule *(dashboard profiles only)*

| Setting | Default | What it does |
|---|---|---|
| **Run every (minutes)** | 5 | How often the analysis runs. Each run adds one point to the history. 30–60 minutes is plenty for most people; shorter only gives you denser history charts. |
| **Unbound cache counts** | on if Unbound is installed | Also record how many messages and RRsets are in Unbound's cache. |

### Analysis

| Setting | Default | What it does |
|---|---|---|
| **Days to analyze** | Pi-hole's own setting (91) | How far back the analysis looks. Pi-hole keeps 91 days by default. |
| **Unbound stats** | auto | **auto**: only when Unbound is installed, running **and** used by Pi-hole. **true**: always. **false**: never. |
| **Ignore reverse lookups (PTR)** | on | Reverse lookups (IP address → name, mostly for your own devices) are left out of the latency and upstream statistics. They still count in the totals. |
| **Ignore replies faster than / slower than (ms)** | off | Leave out extremely fast or slow replies, for example to hide the occasional 30-second timeout. Empty = off. |

### Tiers

The upper limit of each speed tier, in milliseconds, up to 20 tiers. Type them in **any order**: they are sorted when you save. Leave the rest empty. The default tiers are 0.1, 1, 16, 32, 64, 128, 256 and 512 ms.

### Median & P95

Turns the median and 95th percentile on or off for each time window: the whole range, 30 days, 7 days, 24 hours and 12 hours. They are cheap now, so leaving them on is fine.

### Charts *(dashboard profiles only)*

| Setting | Default | What it does |
|---|---|---|
| **Upstream chart** | on | Show the upstream card. |
| **Upstream median/P95 (whole range)** | on | Median and 95th percentile for the upstream "All Time" view. |
| **Unbound cache limit (ms)** | 4 | Replies from Unbound on this machine that are faster than this came from Unbound's cache, so they are not counted as upstream lookups. **0** = count everything. See [section 7](#7-upstream-statistics). |
| **Group upstream servers by provider** | off | Count servers of the same public provider (e.g. Cloudflare's 1.1.1.1 and 1.0.0.1) as one. |
| **History points kept** | 8640 | 8640 points = 30 days at one run every 5 minutes, or a year at one run per hour. |

### Performance

| Setting | Default | What it does |
|---|---|---|
| **Daily cache** | on | Count finished days only once. The results are identical; runs are much faster. Leave it on. |

---

## 5. Profiles

A **profile** is a separate set of settings with its own results. Every install starts with one dashboard profile called **default**.

There are two kinds:

| | **Dashboard profile** | **Report profile** |
|---|---|---|
| Runs | on its schedule, plus ▶ Run now | only when you press 📄 Run report |
| Result | its own dashboard and history charts | a text report, like the command line prints |
| Good for | watching something continuously (e.g. YouTube's DNS speed) | one-off questions ("how was last weekend?") |
| Costs | one analysis per scheduled run | nothing until you run it |

### Adding a profile

**⚙ Manage → Profiles → Add a profile**:

1. Choose **Dashboard** or **Report**.
2. Type a **profile name** (letters, digits, `-` and `_`).
3. Optionally fill in **domains** (see below).
4. **copy from**: the tiers and other settings are copied from this profile.
5. Click **Add profile** and enter your Pi-hole password.

A new dashboard profile runs its first analysis right away. You can open it from the profile menu in the header, or directly at `http://<pi>:8080/?p=<name>`. A new report profile opens its settings, so you can set its time range.

> **More profiles = more work for the Pi.** Each dashboard profile runs its own analysis on its schedule. Profiles never run at the same time, though: when two are due together, they run one after the other.

### Domains

The **Domains** setting accepts these forms:

| You type | It counts | Examples |
|---|---|---|
| `youtube` | every domain **containing** the word | youtube.com, www.youtube.com, youtubei.googleapis.com |
| `youtube.com` | that domain **and its subdomains** | youtube.com, www.youtube.com, m.youtube.com, but not youtubei.googleapis.com |
| `=youtube.com` | **exactly** that name | youtube.com only, not www.youtube.com |
| `*.netflix.com` | `*` matches any text | www.netflix.com, api.netflix.com, but not netflix.com itself |
| `youtube.com,googlevideo.com,ytimg.com` | **any** of them (up to 10) | the forms above, mixed as you like |

**Tip:** most services use several domains. YouTube's videos come from `googlevideo.com` and its thumbnails from `ytimg.com`, so for "all of YouTube" use `youtube.com,googlevideo.com,ytimg.com,youtubei.googleapis.com`.

**Unbound and domains:** Unbound's own counters (hits, misses, memory and so on) are totals for every domain, so they can't follow a domain filter. On a profile with Domains set:
- the Unbound card says *Not shown*;
- the Unbound settings are greyed out;
- the **upstream** statistics still follow the filter, including "Unbound answered X% from its own cache", because those come from Pi-hole's own records.

---

## 6. Reports

A report is the classic PHLS text report for a time range you choose.

1. Add a **Report** profile (or open an existing one with **Settings**).
2. Set the **Time range**, **Queries** and the other report settings, then **Save & apply**.
3. Click **📄 Run report**.

The report opens in a window with:
- **⬇ Download .txt**: saves it as a file, e.g. `phls_weekly_2026-11-21_0916.txt`;
- **Copy**: copies the text, to paste into a message or forum post;
- **📄 Run again**.

**View report** (in the profile list) or **View last report** (in Settings) shows the last report again, without running it.

### Reading a report

```
Total Queries        : 37442
Unsuccessful Queries : 422 (1.1%)
Total Valid Queries  : 37020
Blocked / Ignored    : 5971 / 12639 (49.7%)
Analyzed Queries     : 18410 (49.2%)
Average Latency      : 20.90 ms
Median  Latency      : 4.23 ms
95th Percentile      : 55.69 ms
```

- **Total Queries** is every query in the time range (and the domains). It is the same whatever you choose under *Queries*.
- **Blocked** are queries Pi-hole blocked. **Ignored** are queries left out by your choices, e.g. the cache answers when *Queries = upstream*, or replies outside the cutoffs.
- **Analyzed Queries** are the queries the latency numbers and tiers are based on. *Analyzed (upstream) + Analyzed (pihole) = Analyzed (all)*.

---

## 7. Upstream statistics

The upstream card answers: **how fast are the servers Pi-hole asks when it doesn't know the answer itself?**

### What counts as an upstream query

A query counts when Pi-hole forwarded it to one of its upstream DNS servers (**Settings → DNS** in Pi-hole). These are kept apart:

- **Unbound's cache answers.** When Unbound runs on the same machine, replies from it faster than the *Unbound cache limit* (4 ms by default) came from Unbound's cache, not from the internet. They are not counted as upstream lookups. The card shows how many there were: *"Unbound answered 84% of its replies from its own cache (under 4 ms)"*. Other servers are always counted in full.
- **Conditional forwarding.** Local names and reverse lookups that Pi-hole sends to your router (Pi-hole's *conditional forwarding*) are not upstream lookups. Such servers are left out, and the card lists them: *"Not counted: conditional forwarding to 192.168.1.1#53"*.
- **Reverse lookups (PTR)** are left out when *Ignore reverse lookups* is on (the default).

> **Why 4 ms?** On real Pi-holes with Unbound, cache answers take about 0.5–1 ms and real lookups start at about 6 ms, so 4 ms separates them cleanly. Set it to **0** to count everything, cache included. That shows what your devices actually experience; 4 ms shows how fast the internet side really is.

### More than one upstream server

- **Server selector:** switch the chart, the average, median and 95th percentile and the upstream history between **all servers** and **one server**.
- **Comparison table:** each server's share of queries, number of replies, average, median, 95th percentile and replies slower than 1 second. Click a row to select that server.
- Servers you no longer use still show up for the days they were used.
- Servers of the same provider are shown separately, because they can perform differently. To combine them, turn on **Group upstream servers by provider**.

---

## 8. Unbound

When Unbound runs on the same machine **and Pi-hole uses it** as an upstream server, PHLS shows its statistics automatically.

### What Unbound needs

PHLS reads Unbound's statistics with `unbound-control`, which must be enabled. Debian's and Raspberry Pi OS's Unbound package enables it by default. If the Unbound card says *Error*, add this to your Unbound configuration (e.g. `/etc/unbound/unbound.conf.d/pi-hole.conf`):

```
server:
    extended-statistics: yes

remote-control:
    control-enable: yes
```

Then run `sudo systemctl restart unbound`. `extended-statistics: yes` is also needed for some of the numbers, such as the cached-items counts and Unbound's response-time chart.

### What the Unbound card can say

| Shows | Meaning |
|---|---|
| numbers | All good. |
| **Not installed** | Unbound isn't installed on this machine. |
| **Not used** | Unbound is installed, but Pi-hole doesn't use it as an upstream server. |
| **Not running** | Unbound is installed but stopped. |
| **Off** | The *Unbound stats* setting is false. |
| **Error** | Unbound didn't answer: see *What Unbound needs* above. |
| **Not shown** | The profile has Domains set; see [Domains](#domains). |

### Unbound's own counters

Hits, misses and prefetch are Unbound's own totals **since Unbound last started**. They include everything Unbound answered, for example Pi-hole's DNSSEC lookups too, so the hit rate there is usually higher than the "answered from its own cache" figure on the upstream card. Both are correct; they measure different things.

> ⚠️ **Hits and prefetch stuck at 0?** Check `serve-expired-client-timeout` in your Unbound configuration. If it is above 0, Unbound counts **every** reply as a cache miss, even when it answered from its cache. Since Unbound 1.22 the default is 1800, so you have to set it to 0 yourself:
> ```
> server:
>     serve-expired: yes
>     serve-expired-client-timeout: 0
> ```
> Then run `sudo systemctl restart unbound`. Your DNS works either way; only the counters are affected.

---

## 9. Starting over: Clear history and Reset everything

### Clear history (one profile)

**⚙ Manage → Profiles → Clear history**, or `sudo phls clear <profile>`.

Clears that profile's **history charts** and starts them again from now. Pi-hole's data is **not touched**, so the 24h / 7d / 30d numbers still include older queries until they age out.

### Reset everything

**⚙ Manage → PHLS → Reset everything**, or `sudo phls reset`.

Starts **all** statistics from zero, the same as wiping Pi-hole's data by hand. You choose what to delete:

- ☑ **Pi-hole's stored queries**: its Query Log and long-term data become empty. The devices list is kept.
- ☐ **Pi-hole's devices list** (Network page): this deletes Pi-hole's whole database file.
- ☑ **Pi-hole's log files** (`/var/log/pihole/pihole.log*`).
- ☑ **Restart Unbound**: empties its cache (lookups are slower for a while) and resets its counters.
- ☑ **The history charts of all PHLS profiles.**

> ⚠️ **This permanently deletes data and cannot be undone.** Pi-hole is stopped and started again, so **DNS stops for a few seconds**. The dashboard lists exactly what will be deleted and asks you to type `RESET`, plus your Pi-hole password.

---

## 10. Updating

**Once a day**, the Pi checks GitHub for a new release. When one is out:

- the **⚙ Manage** button shows a yellow badge, e.g. `⬆ 5.0.1`;
- the footer shows **(NEW 5.0.1)** next to the version;
- `phls status` says *Update available*.

**To update:** **⚙ Manage → PHLS → Update to 5.0.1** and enter your Pi-hole password. The Pi downloads the release, **checks its checksum**, and installs it. Your settings, profiles and history are kept. The dashboard is unavailable for a few seconds and reloads when it's done.

From the command line: `sudo phls update`.

If the download fails or is damaged, nothing is changed.

---

## 11. Upgrading from v4

Run the installer as for a new install:

```bash
curl -sSL https://github.com/panoc/pihole-latency-stats/releases/latest/download/install_phls.sh | sudo bash
```

It finds your v4 folder (usually `~/phls`) and:

- **moves your profiles over:** their tiers, cutoffs, history size, schedule and domain filter;
- **keeps your history:** the charts continue where they were;
- **switches off the old cron jobs:** it shows them and asks first. They are commented out, not deleted, and your other cron jobs are left alone;
- **forwards the old dashboard address** (`/admin/img/dash/dash.html`) to the new one;
- **leaves the old `~/phls` folder untouched**, as a backup. When everything works, delete it: `sudo rm -rf ~/phls`.

### What changed for v4 users

| v4 | 5.0 |
|---|---|
| Dashboard at `http://<pi>/admin/img/dash/dash.html` | `http://<pi>:8080/`, its own web server. Pi-hole updates can no longer delete it. |
| `cronmaker.sh` and cron jobs | `sudo phls`, or the dashboard; scheduling by systemd timers |
| `~/phls/pihole_stats.conf`, `~/phls/cron/*.conf` | `/etc/phls/profiles/<name>.conf`; change them in the dashboard or with `sudo phls edit` |
| `phls_uninstall.sh` | `sudo phls uninstall` |
| `phls_version_check.sh` every 3 days | built in, daily, with a one-click update in the dashboard |
| Profile menu: type `?p=name` in the address bar | profile menu in the header |
| `-snap` copied the whole database | no copy needed any more. The option is still accepted but does nothing. |
| Pi-hole v5 and v6 | **Pi-hole v6 only** |

---

## 12. What the numbers mean

- **Average:** total time ÷ number of queries. Good for general health, but a few very slow queries pull it up.
- **Median:** the middle query. Half of the queries were faster, half slower. Outliers don't move it, so it shows the typical experience.
- **95th percentile (P95):** 95% of the queries were faster than this. It's the "bad moments" number: if the median is 1 ms but the P95 is 300 ms, about one query in twenty is slow.
- **Standard deviation:** how much the times vary ("jitter"). Lower is steadier.
- **Tiers:** how many queries fell into each speed range.

All of them are exact values, not estimates.

---

## 13. Files and folders

| Where | What |
|---|---|
| `/opt/phls/` | The program: `phls`, `pihole_stats.sh` and the web helper |
| `/etc/phls/phls.conf` | Global settings: dashboard port, Pi-hole's database and API address |
| `/etc/phls/profiles/<name>.conf` | Each profile's settings |
| `/var/www/phls/` | The dashboard, plus each profile's results (`dash_<name>.json`) and history (`dash_<name>.h.json`) |
| `/var/lib/phls/cache/` | The daily cache (one small file per profile) |
| `/var/lib/phls/reports/` | The last report of each report profile |
| `/var/log/phls/` | Logs |
| `/usr/local/bin/phls` | The `phls` command |

> **Home Assistant / Grafana:** each profile's latest results are a JSON file the dashboard's web server serves, e.g. `http://<pi>:8080/dash_default.json`. A REST sensor can read it directly.

---

## 14. Troubleshooting

**The dashboard doesn't open.**
- Run `phls status`: it shows the dashboard's address and whether its web server is running.
- If it isn't: `sudo systemctl restart phls-web`, then `sudo systemctl status phls-web` for details.

**"DATA STALE" in the header, or the countdown says "Next run: any moment" for a long time.**
- `phls status` shows each profile's last run.
- `sudo phls logs <profile>` shows what went wrong.
- `sudo phls run <profile>` runs it by hand and shows any error.

**"Wrong Pi-hole password".**
- Use the password you log into Pi-hole's web interface with, plus the 2FA code if you use one.
- An *app password* from Pi-hole's settings also works.

**Saving from the dashboard is disabled.**
- Pi-hole is set not to check passwords for requests from the machine itself (`webserver.api.localAPIauth = false`).
- Turn that back on in Pi-hole's settings (*All settings → Webserver and API*), or use `sudo phls edit`.

**The Unbound card says *Not used* although I have Unbound.**
- Pi-hole doesn't use it. In Pi-hole → *Settings → DNS*, the custom upstream must be Unbound's address on this machine, e.g. `127.0.0.1#5335`.

**Unbound hits and prefetch stay at 0.**
- See the ⚠️ note about `serve-expired-client-timeout` in [section 8](#8-unbound).

**A domain profile shows 0 queries.**
- Check the [Domains](#domains) forms. `youtube` (a word) matches every domain containing it, but `=youtube` (exact) matches only a domain literally named "youtube", which doesn't exist.

**The first run after installing or updating is slow.**
- It reads the whole database once and fills the cache. After that, each run reads only the newest hours and is much faster.

**I want more detail for a bug report.**
- `sudo phls run <profile> --debug` writes a detailed timing log to `/var/log/phls/`.

---

## 15. Uninstalling

```bash
sudo phls uninstall
```

- It asks whether to **keep your settings and history** (handy if you reinstall later). Say no for a full removal.
- It removes the dashboard's web server package (lighttpd) **only if PHLS installed it**, and asks first.
- Pi-hole and Unbound are not touched.
