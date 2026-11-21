# ⌨️ Pi-hole Latency Stats 5.0: Command Line

Everything here can also be done in the dashboard (see the [User Guide](USAGE.md)). The command line is for those who prefer a terminal, for scripts, and for advanced use.

## 📑 Contents

1. [The `phls` command](#1-the-phls-command)
2. [Changing settings from the command line](#2-changing-settings-from-the-command-line)
3. [Advanced: `pihole_stats.sh` directly](#3-advanced-pihole_statssh-directly)
4. [Automation and JSON output](#4-automation-and-json-output)
5. [System services](#5-system-services)

---

## 1. The `phls` command

`phls` manages everything: profiles, settings, runs, updates. Commands that change something need `sudo`.

### The menu

```bash
sudo phls
```

It shows the status and a menu:

```
 1) Change settings      4) Add a profile        7) Update PHLS
 2) Run analysis now     5) Delete a profile     8) Uninstall
 3) Show settings        6) Logs of a profile    0) Exit
```

### All commands

| Command | What it does |
|---|---|
| `phls status` | Version, dashboard address, web server, and each profile's schedule, last run and domains. Also says when an update is available. |
| `phls url` | Prints the dashboard address. |
| `phls version` | Prints the installed version. |
| `sudo phls run [profile]` | Runs a profile now (default: `default`). For a **report** profile it prints the report. |
| `sudo phls run all` | Runs every dashboard profile, one after the other. |
| `sudo phls run <profile> --debug` | Same, with a detailed timing log in `/var/log/phls/`. |
| `phls show <profile>` | Lists a profile's settings with their current values. |
| `sudo phls edit [profile]` | Interactive settings editor (same settings and checks as the dashboard). |
| `sudo phls set <profile> KEY=value …` | Changes settings in one line; see [section 2](#2-changing-settings-from-the-command-line). |
| `sudo phls add <name>` | Adds a profile. It asks whether it's a report profile and which domains to use. |
| `sudo phls add <name> --report` | Adds a report profile without asking. |
| `sudo phls add <name> --domains youtube.com,googlevideo.com` | Adds a profile for those domains (forms: see [Domains](USAGE.md#domains)). |
| `sudo phls delete <profile>` | Deletes a profile and its history (asks first). |
| `sudo phls clear <profile\|all>` | Starts the history charts over. Pi-hole's data is not touched. Add `--yes` to skip the question. |
| `sudo phls reset` | **Reset everything**: Pi-hole's stored queries and logs, Unbound's cache and counters, and all PHLS history. It asks about each part. `--yes` takes the defaults without asking. See [the User Guide](USAGE.md#9-starting-over-clear-history-and-reset-everything). |
| `sudo phls logs [profile]` | The last log lines of a profile's runs. |
| `sudo phls check-update` | Checks GitHub for a new release now (it also runs daily by itself). |
| `sudo phls update` | Downloads the latest release, checks it, and reinstalls. Settings and history are kept. |
| `sudo phls uninstall` | Removes PHLS. It asks whether to keep settings and history. |

### Examples

```bash
# How is everything doing?
phls status

# Make a report profile for the last 7 days of upstream queries, and run it
sudo phls add weekly --report
sudo phls set weekly REPORT_RANGE=7d REPORT_COUNT=upstream
sudo phls run weekly

# Save the report to a file
sudo phls run weekly > weekly_report.txt
```

---

## 2. Changing settings from the command line

```bash
sudo phls set <profile> KEY=value [KEY=value …]
```

The values are checked exactly as in the dashboard, then applied, and the profile runs again with them. To empty a setting, give it no value (`MIN_LATENCY_CUTOFF=`).

| KEY | Setting | Values |
|---|---|---|
| `PROFILE_TYPE` | Profile type | `dashboard`, `report` |
| `FILTER_DOMAIN` | Domains | e.g. `youtube`, `github.com`, `=youtube.com`, `a.com,b.com` (empty = all) |
| `REPORT_RANGE` | Time range (reports) | `all`, `custom`, or a number + `h` / `d` (`24h`, `7d`) |
| `REPORT_FROM`, `REPORT_TO` | From / To (reports) | `2026-11-01` or `2026-11-01 08:00` |
| `REPORT_COUNT` | Queries (reports) | `all`, `upstream`, `pihole` |
| `REPORT_NX` | Leave out special blocks (reports) | `true`, `false` |
| `REPORT_UNBOUND` | Unbound section (reports) | `include`, `only`, `none` |
| `RUN_EVERY` | Run every (minutes) | 1–1440 |
| `UCC` | Unbound cache counts | `true`, `false` |
| `MAX_DB_DAYS` | Days to analyze | 1–365 |
| `ENABLE_UNBOUND` | Unbound stats | `auto`, `true`, `false` |
| `EXCLUDE_PTR` | Ignore reverse lookups | `true`, `false` |
| `MIN_LATENCY_CUTOFF`, `MAX_LATENCY_CUTOFF` | Ignore replies faster / slower than (ms) | number, or empty = off |
| `L01` … `L20` | Tiers (ms) | numbers in any order, empty = unused |
| `ENABLE_MATH_ALL_TIME`, `ENABLE_MATH_30D`, `ENABLE_MATH_7D`, `ENABLE_MATH_24H`, `ENABLE_MATH_12H` | Median & P95 per window | `true`, `false` |
| `ENABLE_UPSTREAM_DIST` | Upstream chart | `true`, `false` |
| `ENABLE_UPSTREAM_MATH_ALL_TIME` | Upstream median/P95 (whole range) | `true`, `false` |
| `UPSTREAM_DIST_MIN_CUTOFF` | Unbound cache limit (ms) | number, `0` = count everything |
| `UPSTREAM_BY_PROVIDER` | Group upstream servers by provider | `true`, `false` |
| `MAX_HISTORY_ENTRIES` | History points kept | 100–200000 |
| `ENABLE_CACHE` | Daily cache | `true`, `false` |

```bash
sudo phls set default RUN_EVERY=60
sudo phls set default L01=0.5 L02=5 L03=20
sudo phls set netflix FILTER_DOMAIN=netflix.com,nflxvideo.net
```

The settings live in `/etc/phls/profiles/<name>.conf`. You can edit that file by hand too, but `phls set` / `phls edit` check the values for you.

---

## 3. Advanced: `pihole_stats.sh` directly

`/opt/phls/pihole_stats.sh` is the analysis engine that `phls` runs. You can call it yourself for a quick one-off report:

```bash
sudo /opt/phls/pihole_stats.sh -c /etc/phls/profiles/default.conf -24h
```

`-c` uses a profile's tiers and other settings. Without it, the built-in defaults are used.

> A profile's **Domains** and **report** settings are applied by `phls`, not by the engine. When you call the engine directly, give the domains with `-dm` / `-edm` / `-xdm` yourself. For everyday reports, a [report profile](USAGE.md#6-reports) with `sudo phls run <name>` is easier.

### Time range

| Option | Meaning |
|---|---|
| *(none)* | All data in the database |
| `-24h`, `-7d`, `-12h`, `-30d` … | The last N hours (`h`) or days (`d`) |
| `-from "…"` / `-to "…"` | A custom range. Anything `date` understands works: `"2026-11-01"`, `"2026-11-01 08:00"`, `"yesterday"`, `"2 hours ago"`. |

### Which queries

| Option | Meaning |
|---|---|
| *(none)* | Every answered query |
| `-up` | Upstream only: queries Pi-hole forwarded |
| `-pi` | Pi-hole only: answered from Pi-hole's cache or local records |
| `-nx` | Leave out special-domain and stale-cache replies (statuses 16 and 17) |
| `-dm "text"` | Domains **containing** the text (`*` = any text, `?` = one character) |
| `-edm "domain"` | That domain **and its subdomains** |
| `-xdm "domain"` | **Exactly** that domain |

Domain options can be repeated, or take a comma list (`-edm a.com,b.com`). A query counts if it matches any of them.

### Unbound

| Option | Meaning |
|---|---|
| `-unb` | Always include Unbound's stats |
| `-no-unb` | Never include them |
| `-unb-only` | Only Unbound's stats (can't be combined with a domain filter) |
| `-ucc` | Also count the messages and RRsets in Unbound's cache |

### Output

| Option | Meaning |
|---|---|
| `-j [file]` | Also save the results as JSON |
| `-f [file]` | Also save the text report to a file |
| `-s` | Silent: no screen output (for scripts) |
| `-ts` | Add date and time to the file names |
| `-seq` | Add a number to the file names instead of overwriting (`stats_1.json`, `stats_2.json`, …) |
| `-rt <days>` | Delete saved reports older than this many days, in the folders set by `SAVE_DIR_TXT` / `SAVE_DIR_JSON` in the settings file |
| `-hor` / `-ver` | Side-by-side or one-column text layout (default: chosen by the terminal width) |

### Other

| Option | Meaning |
|---|---|
| `-c <file>` | Use this settings file |
| `-mc <file>` | Create a settings file with the defaults |
| `-db <file>` | Read another Pi-hole database file |
| `-debug` | Write a detailed timing log |
| `-dash <name>`, `-nh`, `-clear` | Dashboard runs. These are used by `phls`, so use `phls run` / `phls clear` instead. |
| `-snap` | No longer needed; accepted for old scripts and ignored. |
| `-h` | Help |

---

## 4. Automation and JSON output

**Live values:** every dashboard profile's latest results are a JSON file served by the dashboard's web server:

```
http://<pi>:8080/dash_default.json
```

Home Assistant (REST sensor), Node-RED or Grafana can read it directly, with no extra jobs.

**Your own reports on a schedule**, e.g. a JSON file every night for the last 24 hours, with the date in its name:

```bash
sudo mkdir -p /var/log/phls/daily
sudo crontab -e
```
```cron
5 0 * * * /opt/phls/pihole_stats.sh -c /etc/phls/profiles/default.conf -24h -s -j /var/log/phls/daily/stats.json -ts
```

This gives `stats_2026-11-21_0005.json`, `stats_2026-11-22_0005.json`, and so on. To have old ones deleted automatically, copy the profile's settings file, set `SAVE_DIR_JSON="/var/log/phls/daily"` in the copy, use it with `-c`, and add `-rt 30`.

---

## 5. System services

PHLS runs as a few small systemd services. You normally never need to touch them.

| Unit | What it does |
|---|---|
| `phls@<profile>.timer` / `.service` | Runs a dashboard profile on its schedule. Two runs never overlap, and profiles run one after the other. |
| `phls-web.service` | The dashboard's own web server (lighttpd, on its own port) |
| `phls-apply.path` / `.service` | Applies changes made in the dashboard (as root, after checking every value again) |
| `phls-update-check.timer` | Checks GitHub for a new release once a day |

```bash
systemctl list-timers 'phls*'          # when each profile runs next
sudo systemctl status phls-web          # is the dashboard's web server running?
journalctl -u phls@default.service -n 20   # the last runs of the default profile
```
