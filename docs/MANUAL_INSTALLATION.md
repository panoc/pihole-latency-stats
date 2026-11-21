# 📦 Pi-hole Latency Stats 5.0: Manual and Offline Installation

**Most people don't need this page.** The one-line install in the [README](../README.md) does everything:

```bash
curl -sSL https://github.com/panoc/pihole-latency-stats/releases/latest/download/install_phls.sh | sudo bash
```

This page is for when you want to:

- [look at the files before installing, or install without piping from the internet](#1-install-from-downloaded-files)
- [install without asking any questions](#2-install-without-questions)
- [install without the web dashboard](#3-without-the-web-dashboard)
- [use a different dashboard port](#4-a-different-dashboard-port)
- [install from a copy of the repository](#5-from-a-copy-of-the-repository)
- [use only the analysis script, without installing anything](#6-only-the-script-no-installation)

It also explains [what the installer does](#what-the-installer-does) and [how to check that everything works](#check-that-everything-works).

---

## Before you start

- **Pi-hole v6**, installed directly on the machine (not in Docker). Check with `pihole -v`.
- A Debian-based system with **systemd**: Raspberry Pi OS, Debian, Ubuntu, DietPi…
- A terminal on the Pi (over SSH or directly), and a user that can use `sudo`.

---

## 1. Install from downloaded files

1. On the [latest release page](https://github.com/panoc/pihole-latency-stats/releases/latest), download these three files:
   - `install_phls.sh`
   - `phls_assets.tar.gz`
   - `phls_assets.tar.gz.sha256`
2. Copy them to the Pi, for example into `/tmp`. From Windows PowerShell:
   ```powershell
   scp install_phls.sh phls_assets.tar.gz phls_assets.tar.gz.sha256 pi@192.168.1.2:/tmp/
   ```
3. On the Pi, check that the download is complete. It must say **OK**:
   ```bash
   cd /tmp
   sha256sum -c phls_assets.tar.gz.sha256
   ```
4. Install:
   ```bash
   sudo bash install_phls.sh --local phls_assets.tar.gz
   ```

The same command also **updates** an existing install, or **upgrades** a v4 install.

> **No internet on the Pi?** The installer then can't install missing packages. Install `sqlite3` (and `lighttpd` for the dashboard) first, from your usual source. The dashboard's chart library can't be downloaded either, so your **browser** loads it from the internet instead. That works as long as the computer you view the dashboard on has internet.

---

## 2. Install without questions

Add `--yes` to use the default answers (install the dashboard, switch off old v4 cron jobs):

```bash
curl -sSL https://github.com/panoc/pihole-latency-stats/releases/latest/download/install_phls.sh | sudo bash -s -- --yes
```
or, with downloaded files:
```bash
sudo bash install_phls.sh --local phls_assets.tar.gz --yes
```

---

## 3. Without the web dashboard

Answer **n** when the installer asks *"Install the web dashboard?"*. PHLS then installs no web server and opens no port. Everything still runs on its schedule, and you use it with the [`phls` command](COMMAND_LINE.md):

- `phls status` shows each profile's last run.
- [Report profiles](USAGE.md#6-reports) print their reports with `sudo phls run <name>`.
- The results are still saved as JSON in `/var/www/phls/`, for other tools to read.

To add the dashboard later, change the line `DASHBOARD="no"` to `DASHBOARD="yes"` in `/etc/phls/phls.conf`, then run `sudo phls update`. That reinstalls with the dashboard.

---

## 4. A different dashboard port

The installer uses the first free port of 8080, 8081, 8088, 8090, 8888, 8008, 8181, 8282 and 9080, and never one of Pi-hole's own ports. To choose your own:

1. Edit the settings file:
   ```bash
   sudo nano /etc/phls/phls.conf
   ```
   and change the line `WEB_PORT="8080"` to the port you want, e.g. `WEB_PORT="8095"`.
2. Apply it by reinstalling:
   ```bash
   sudo phls update
   ```
3. Check the new address with `phls status`.

---

## 5. From a copy of the repository

If you cloned or downloaded the repository (for example to try changes), run the setup from its `phls_assets` folder:

```bash
git clone https://github.com/panoc/pihole-latency-stats.git
cd pihole-latency-stats
sudo bash phls_assets/phls setup
```

---

## 6. Only the script, no installation

The analysis script `pihole_stats.sh` also works on its own, like in v4: no schedule, no dashboard, nothing installed. That's handy for a quick look:

```bash
curl -sSLO https://raw.githubusercontent.com/panoc/pihole-latency-stats/main/phls_assets/pihole_stats.sh
sudo bash pihole_stats.sh -24h
```

The first run creates `pihole_stats.conf` next to the script, with the default tiers. Edit that file to change them. All options are in the [Command Line guide](COMMAND_LINE.md#3-advanced-pihole_statssh-directly). It needs `sqlite3`.

---

## What the installer does

1. **Checks the system:** Pi-hole v6, systemd, and an earlier PHLS (v4 or 5.x).
2. **Reads Pi-hole's own settings:** the database location, how many days Pi-hole keeps, and Pi-hole's web ports. The web ports are used to check your password and to avoid using one of Pi-hole's ports for the dashboard.
3. **Asks** whether to install the dashboard, and, when upgrading from v4, whether to switch off the old cron jobs.
4. **Installs what is missing:** `sqlite3`, and `lighttpd` for the dashboard. lighttpd runs as **its own instance** on its own port. Pi-hole's web server and any other web site on the machine are not touched.
5. **Copies the files:**

   | Where | What |
   |---|---|
   | `/opt/phls/` | The program |
   | `/etc/phls/` | Settings (`phls.conf`, `profiles/<name>.conf`) |
   | `/var/www/phls/` | Dashboard, results and history |
   | `/var/lib/phls/` | Cache, last reports |
   | `/var/log/phls/` | Logs |
   | `/usr/local/bin/phls` | The `phls` command |

6. **Moves a v4 install over** (if found): profiles, history, cache and schedule. The old folder is left as it is.
7. **Sets up the schedule** with systemd timers, plus a daily update check.
8. **Starts the dashboard's web server** and **runs the first analysis**. This reads the whole Pi-hole database once, which can take up to a minute on a Pi Zero with millions of queries.

---

## Check that everything works

```bash
phls status
```

You should see the version, the dashboard address, **Web server: running**, and the `default` profile with its schedule. Then:

1. Open the dashboard address in your browser. The header shows **Last Analysis** with a recent time.
2. Click **▶ Run now**. After a few seconds the time updates.
3. Click **⚙ Manage** to see your profiles.

Something wrong? See [Troubleshooting](USAGE.md#14-troubleshooting).
