# 📖 PHLS Technical Manual & Usage Guide

Welcome to the **Pi-hole Latency Stats (PHLS)** manual. This guide is designed to help everyone—from first-time Raspberry Pi users to advanced sysadmins—get the most out of their DNS analysis.

---

## 1. Installation & The "Where" Factor

One of the most important concepts for new users is the **Installation Directory**. By default, the installer suggests `/home/<your-username>/phls/`.

### How to Install

Run the following command. It will ask if you want a custom path; if you are unsure, just type `n` for the default.

```bash
wget -O install_phls.sh https://github.com/panoc/pihole-latency-stats/releases/latest/download/install_phls.sh && sudo bash install_phls.sh

```

###  Maintenance & Uninstallation

If you ever want to change your setup or remove the project, you **must** be inside your installation folder.

1. **Go to your folder:** `cd ~/phls` (The `~` is a shortcut for your home folder).
2. **Run the uninstaller:** `sudo ./install_phls.sh -un`.

The installer is "smart"—it keeps a hidden list of every file it created so it can clean up perfectly.

---

## 2. Running the Analysis

Because this script interacts with the Pi-hole system database, it **requires** `sudo` (admin) permissions.

### The Two Ways to Run:

* **From inside the folder:**
```bash
cd ~/phls
sudo ./pihole_stats.sh

```


* **From anywhere (Full Path):**
```bash
# Replace 'pi' with your actual username
sudo /home/pi/phls/pihole_stats.sh

```

---

## 3. Usage

You can run the script with various flags to customize the analysis.

```bash
sudo ./pihole_stats.sh [OPTIONS]

```

### 🕒 Time Filters

* `-24h` : Analyze the last 24 hours (Default).
* `-7d`  : Analyze the last 7 days.
* `-<number>h` : Analyze the last N hours (e.g., `-12h`).
* `-<number>d` : Analyze the last N days (e.g., `-30d`).
* `-from "date"` : Start analysis from a specific date/time (e.g., `-from "yesterday"`, `-from "2024-01-01"`).
* `-to "date"` : End analysis at a specific date/time (e.g., `-to "2 hours ago"`, `-to "14:00"`).

### 🔍 Query Modes

* **Default** : Analyzes all "normal" queries (Forwarded + Cached).
* `-up` : **Upstream Mode.** Analyzes *only* queries forwarded to upstream DNS (Cloudflare, Google, Unbound). Use this to test your ISP/Provider speed.
* `-pi` : **Pi-hole Mode.** Analyzes *only* cached/local answers. Use this to test the speed of the Pi-hole hardware itself.
* `-nx` : **Exclude Blocked.** Removes blocked queries (0.0ms) from the calculation to prevent skewing the average.

### 🎯 Filtering

* `-dm <string>` : **Domain Filter.** Analyze only domains containing this string (e.g., `-dm google` matches `google.com`, `drive.google.com`).
* `-edm <string>` : **Exact Domain.** Analyze only this exact domain (e.g., `-edm google.com`).

### 📦 Unbound Integration

* `-unb` : **Force Unbound.** Appends Unbound statistics to the standard Pi-hole report. (Note: The script usually auto-detects this).
* `-unb-only` : **Unbound Only.** Runs *only* the Unbound health check. This skips the Pi-hole database entirely (faster, useful for checking Unbound status).
* `-no-unb` : **Disable Unbound.** Forces the script to skip Unbound checks, even if detected or enabled in config.
* `-ucc` : **Cache Count.** Counts the exact number of Messages and RRsets in RAM. *See Performance Note below.*

### 🖥️ Display Options

* `-hor`, `--horizontal` : **Force Horizontal.** Forces the split-pane dashboard view (ideal for large screens).
* `-ver`, `--vertical` : **Force Vertical.** Forces the standard vertical list view (ideal for mobile/logs).

### 💾 Output & Automation

* `-f <filename>` : **Save to File.** Writes the output to the specified file.
* `-j` : **JSON Mode.** Outputs raw JSON instead of the text report.
* `-s` : **Silent Mode.** Suppresses screen output. Essential for cron jobs.
* `-rt <days>` : **Retention/Rotation.** Deletes report files in your `SAVE_DIR` older than X days.
* `-snap` : **Snapshot Mode.** Creates a temporary copy of the DB to avoid "Database Locked" errors. Auto-detects if RAM is sufficient (fast); falls back to disk if needed (safe).

### ⚙️ Configuration

* `-c <file>` : Load a specific configuration file.
* `-mc <file>` : Make (generate) a default configuration file.
* `-db <path>` : Manually specify the path to `pihole-FTL.db`.

---

## Configuration File

On the first run, the script creates `pihole_stats.conf` in the same directory. You can edit this file to permanently set your preferences:

1. **Define Latency Tiers:** Customize your buckets (e.g., `L01="0.5"` for 0.5ms).
2. **Default Save Directory:** Set `SAVE_DIR_TXT` to a folder where `-f` files will be saved automatically.
3. **Default Save Directory:** Set `SAVE_DIR_JSON` to a folder where `-f`-j files will be saved automatically.
4. **Default TXT name**: Set `TXT_NAME` as default name for txt report.
5. **Default TXT name**: Set `JSON_NAME` as default name for json report.
6. **Unbound Settings:** Set `ENABLE_UNBOUND` to `auto` (default), `true` (always on), or `false`.
7. **Visual Layout:** Set `LAYOUT` to `auto` (default), `horizontal`, or `vertical`.
8. **Auto-Delete:** Set `MAX_LOG_AGE` to automatically delete old reports every time the script runs.

---

## 🖥️ 4. The Web Dashboard

The **v3.3 Dashboard** is the star of the show. It is a visual webpage that updates whenever you run the script with the `-j` (JSON) flag.

* **View it at:** `http://<your-pi-ip>/admin/img/dash/dash.html?p=default`.
* **How it works:** The script writes a data file (`dash_default.json`) to your web server, and the dashboard reads it.

---

## 🤖 5. Automation (Cron for Beginners)

If you want the dashboard to update automatically without you typing commands, you use a "Cron Job."

1. Type `sudo crontab -e`.
2. If asked, choose `1` (for nano).
3. Scroll to the very bottom and add this line (adjust the path to your username!):
```bash
# Update the dashboard every 5 minutes silently
*/5 * * * * /home/pi/phls/pihole_stats.sh -j -s

```


4. Press `Ctrl+O` then `Enter` to save, and `Ctrl+X` to exit.

---

## ⚙️ 6. The Configuration File (`pihole_stats.conf`)

Inside your `phls` folder, you will find `pihole_stats.conf`. You can open this with `nano pihole_stats.conf` to change settings permanently:

* **MAX_LOG_AGE:** Set this to `7` to automatically delete old text reports after a week.
* **JSON_NAME:** If you want to create different dashboards for different devices, change this name.
* **Auto-Repair:** If you mess up the file, don't worry! Running the script will detect missing parts and fix the file for you.

---

## 🛡️ 7. Unbound Deep Dive

If you use Unbound, PHLS provides "Deep Inspection."

* **Memory Stats:** To see how much RAM Unbound is using, you **must** add `extended-statistics: yes` to your `unbound.conf` file.
* **Cache Count (`-ucc`):** This tells you exactly how many DNS records are in memory. **Note:** On very slow hardware with massive caches, this might cause a 1-second pause in DNS replies, so use it sparingly!

### ⚠️ Prerequisite for Memory Stats

To see the **Memory Usage** breakdown (Message vs RRset cache), you must enable extended statistics in Unbound.

1. Edit your config: `sudo nano /etc/unbound/unbound.conf` (or your specific config file).
2. Add `extended-statistics: yes` inside the `server:` block:

```yaml
server:
    # ... other settings ...
    extended-statistics: yes

```

3. Restart Unbound: `sudo service unbound restart`

*Without this setting, Memory Usage will report 0 MB.*

### ⚠️ Performance Note: Unbound Cache Counting (`-ucc`)

The `-ucc` flag provides deep insights by counting the exact number of items in your Unbound RAM cache. To achieve this, it triggers a cache dump.

**Please use this flag responsibly:**

* **How it works:** Unbound **locks its memory** to read the data.
* **The Impact:** While locked, Unbound momentarily **pauses DNS resolution**.
* For typical home use (1k–50k items), this freeze is instant (milliseconds) and unnoticeable.
* For very large caches (100k+ items), this can cause a 1–2 second delay in DNS replies.


* **Recommendation:** Use this flag for **periodic reporting** (e.g., hourly/daily Cron jobs) or manual spot-checks. **Do not** run it in a rapid "live" loop (e.g., every 5 seconds).

---
