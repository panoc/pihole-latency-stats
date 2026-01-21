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

## 3. Understanding the Metrics

### Pi-hole Metrics

* **Average Latency:** The mathematical mean of all query times.
* **Median Latency (p50):** The "middle" query. 50% of your queries were faster than this.
* **95th Percentile (p95):** The "worst case" for most users. 95% of your queries were faster than this; only the slowest 5% took longer.
* **Tiers:**
* **Tier 1 (< 0.1ms):** Instant answers. Usually cached by Pi-hole or Blocked.
* **Tier 2-4 (1ms - 50ms):** Healthy upstream responses.
* **Tier 7+ (> 300ms):** Slow queries. These might be timeouts or packet loss.



### Unbound Metrics

* **Cache Hit Ratio (CHR):** The percentage of queries answered purely from Unbound's RAM. Higher is better (usually >80% after a few days).
* **Prefetch Jobs:** The number of times Unbound refreshed a cached item *before* it expired. This means the client got an instant answer instead of waiting.
* **Cache Memory Usage:** Shows how much RAM is actually being used vs the limit you set in `msg-cache-size` and `rrset-cache-size`.
* **Cache Count (`-ucc`):** A deep inspection of the items currently locked in RAM.
* **Messages:** The number of cached *questions* (e.g., "What is the IP of google.com?").
* **RRsets:** The number of cached *records/answers* (e.g., "A Record: 192.168.1.1"). One Message can link to multiple RRsets (like CNAME chains).

---

## 4. Usage

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

## 5. The Web Dashboard

* **View it at:** `http://<your-pi-ip>/admin/img/dash/dash.html?p=default`.
* **How it works:** The script writes a data file (`dash_default.json`) to your web server, and the dashboard reads it.
* **Autoupdate:** Dashboard auto updates every 1 minute.
* 
---

## 6. Automation (Cron for Beginners)

If you want the dashboard to update automatically without you typing commands, you use a "Cron Job."

1. Type `sudo crontab -e`.
2. If asked, choose `1` (for nano).
3. Scroll to the very bottom and add this line (adjust the path to your username!):
```bash
# Update the dashboard every 5 minutes silently
*/5 * * * * /home/pi/phls/pihole_stats.sh -j -s

```


4. Press `Ctrl+O` then `Enter` to save, and `Ctrl+X` to exit.

> **ℹ️ Layout Note:** When running via Cron, the script cannot detect a screen width and will automatically default to the **Vertical** layout for text reports. This ensures logs are readable and don't wrap incorrectly.
> * **JSON output** is structured data and is never affected by layout settings.
> * If you specifically require a wide text report from Cron, you can force it by adding `-hor` to the command.


---

## 7. The Configuration File (`pihole_stats.conf`)

Inside your `phls` folder, you will find `pihole_stats.conf`. You can open this with `nano pihole_stats.conf` to change settings permanently:

* **MAX_LOG_AGE:** Set this to `7` to automatically delete old text reports after a week.
* **JSON_NAME:** If you want to create different dashboards for different devices, change this name.
* **Auto-Repair:** If you mess up the file, don't worry! Running the script will detect missing parts and fix the file for you.

---

## 🛡️ 8. Unbound Deep Dive

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

## 10. Example Output

<details>
<summary><strong>Click to expand Text Report (Horizontal Layout)</strong></summary>

*Automatically generated on terminals wider than 100 columns (or with `-hor`).*

```text
====================================================================================================
                                     Pi-hole Latency Stats v3.1
====================================================================================================
                                Analysis Date : 2026-01-20 12:30:00
---------------- Pi-hole Performance ----------------||---------- Unbound DNS Performance ----------
Time Period   : All Time                             ||Server Status : Active (Integrated)
Query Mode    : All Normal Queries                   ||Config File   : /etc/unbound/unbound.conf
-----------------------------------------------------||---------------------------------------------
Total Queries        : 165,711                       ||Total Queries : 37,129
Unsuccessful Queries : 2,840 (1.7%)                  ||Cache Hits    : 27,513 (74.10%)
Total Valid Queries  : 162,871                       ||Cache Misses  : 9,616 (25.90%)
Blocked Queries      : 23,329 (14.3%)                ||Prefetch Jobs : 16,437 (59.74% of Hits)
Analyzed Queries     : 139,542 (85.7%)               ||
Average Latency      : 6.55 ms                       ||----- Cache Memory Usage (Used / Limit) -----
Median  Latency      : 0.03 ms                       ||Msg Cache   : 3.29MB / 64.00MB  (5.13%)
95th Percentile      : 14.96 ms                      ||RRset Cache : 3.51MB / 128.00MB (2.74%)
                                                     ||Messages (Queries): 288
                                                     ||RRsets (Records)  : 486
----------------------------------------------------------------------------------------------------
--- Latency Distribution of Pi-Hole Analyzed Queries ---
Tier 1 (< 0.009ms)       :   7.91%  (11032)
Tier 2 (0.009 - 0.1ms)   :  66.96%  (93433)
Tier 3 (0.1 - 1ms)       :  15.97%  (22286)
Tier 4 (1 - 10ms)        :   3.37%  (4703)
Tier 5 (10 - 50ms)       :   3.35%  (4671)
Tier 6 (50 - 100ms)      :   0.91%  (1270)
Tier 7 (100 - 300ms)     :   1.07%  (1500)
Tier 8 (300 - 1000ms)    :   0.37%  (510)
Tier 9 (> 1000ms)        :   0.10%  (137)
====================================================================================================
Total Execution Time: 0.52s

```

</details>

<details>
<summary><strong>Click to expand Text Report (Vertical Layout)</strong></summary>

*Standard layout for mobile, cron logs, or `-ver` flag.*

```text
========================================================
              Pi-hole Latency Stats v3.1
========================================================
Analysis Date : 2026-01-20 12:30:00
Time Period   : All Time
Query Mode    : All Normal Queries
--------------------------------------------------------
Total Queries         : 165,711
Unsuccessful Queries  : 2,840 (1.7%)
Total Valid Queries   : 162,871
Blocked Queries       : 23,329 (14.3%)
Analyzed Queries      : 139,542 (85.7%)
Average Latency       : 6.55 ms
Median  Latency       : 0.03 ms
95th Percentile       : 14.96 ms

--- Latency Distribution of Pi-Hole Analyzed Queries ---
Tier 1 (< 0.009ms)       :   7.91%  (11032)
Tier 2 (0.009 - 0.1ms)   :  66.96%  (93433)
Tier 3 (0.1 - 1ms)       :  15.97%  (22286)
Tier 4 (1 - 10ms)        :   3.37%  (4703)
Tier 5 (10 - 50ms)       :   3.35%  (4671)
Tier 6 (50 - 100ms)      :   0.91%  (1270)
Tier 7 (100 - 300ms)     :   1.07%  (1500)
Tier 8 (300 - 1000ms)    :   0.37%  (510)
Tier 9 (> 1000ms)        :   0.10%  (137)

========================================================
              Unbound DNS Performance
========================================================
Server Status     : Active (Integrated)
Config File       : /etc/unbound/unbound.conf
--------------------------------------------------------
Total Queries     : 37,129
Cache Hits        : 27,513 (74.10%)
Cache Misses      : 9,616 (25.90%)
Prefetch Jobs     : 16,437 (59.74% of Hits)

       --- Cache Memory Usage (Used / Limit) ---
Message Cache     : 3.29 MB / 64.00 MB   (5.13%)
RRset Cache       : 3.51 MB / 128.00 MB  (2.74%)
Messages (Queries): 288
RRsets (Records)  : 486
========================================================
Total Execution Time: 0.52s

```

</details>

<details>
<summary><strong>Click to expand JSON Structure</strong></summary>

```json
{
  "version": "3.1",
  "date": "2026-01-20 12:30:00",
  "time_period": "All Time",
  "mode": "All Normal Queries",
  "stats": {
    "total_queries": 165711,
    "unsuccessful": 2840,
    "total_valid": 162871,
    "blocked": 23329,
    "analyzed": 139542
  },
  "latency": {
    "average": 6.55,
    "median": 0.03,
    "p95": 14.96
  },
  "tiers": [
    {"label": "Tier 1 (< 0.009ms)", "count": 11032, "percentage": 7.91},
    {"label": "Tier 2 (0.009 - 0.1ms)", "count": 93433, "percentage": 66.96},
    {"label": "Tier 3 (0.1 - 1ms)", "count": 22286, "percentage": 15.97},
    {"label": "Tier 4 (1 - 10ms)", "count": 4703, "percentage": 3.37},
    {"label": "Tier 5 (10 - 50ms)", "count": 4671, "percentage": 3.35}
  ],
  "unbound": {
    "status": "active",
    "total": 37129,
    "hits": 27513,
    "miss": 9616,
    "prefetch": 16437,
    "ratio": 74.10,
    "memory": {
        "msg": { "used_mb": 3.29, "limit_mb": 64.00, "percent": 5.13 },
        "rrset": { "used_mb": 3.51, "limit_mb": 128.00, "percent": 2.74 }
    },
    "cache_count": {
        "messages": 288,
        "rrsets": 486
    }
  }
}

```

</details>



