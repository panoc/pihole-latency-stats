# Pi-hole Latency Stats
![Pi-Hole](https://img.shields.io/badge/pihole-%2396060C.svg?style=for-the-badge&logo=pi-hole&logoColor=white) ![Unbound](https://img.shields.io/badge/Unbound-341893?style=for-the-badge&logo=data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAUCAYAAACEYr13AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAAYdEVYdFNvZnR3YXJlAFBhaW50Lk5FVCA1LjEuN4vW9zkAAAC2ZVhJZklJKgAIAAAABQAaAQUAAQAAAEoAAAAbAQUAAQAAAFIAAAAoAQMAAQAAAAMAAAAxAQIAEAAAAFoAAABphwQAAQAAAGoAAAAAAAAAo5MAAOgDAACjkwAA6AMAAFBhaW50Lk5FVCA1LjEuNwADAACQBwAEAAAAMDIzMAGgAwABAAAAAQAAAAWgBAABAAAAlAAAAAAAAAACAAEAAgAEAAAAUjk4AAIABwAEAAAAMDEwMAAAAAA02IfdCSajZAAAAoZJREFUOE+Vk89LVFEUxz/3jk9tdOUf0NyIMGonaYv+AGnTpn0EgYsQRGhTLWwhgSDhpogghKBaBEmbiChdhQYZRv7IwLyJjDLajKOj4/jeu6fF3BeTKdUXLu+cd873e+45917Gxt4rEdFU0ZTN5q45J6Vc7sdWa2uXAZifX7gZhpGsrOSmpqbmTvtclpdX6hKbubmFS/n8RsE5JyIia2t5GRwcPgcwMfHxk3hUKnti7fLzvr67JwHo7b0XbG6WXsRxnOTsiUi8vp6XgYGHHQDj45MfREScc3siEjvnZHu7XAnD6Kzu7798prk5fUFrHYmIE5Hg17ZA1dgAGtBKqXI63Vivte7W6fSRUCmFDySz2I/9QgGA1qqkDwj+D1KHVfxn/E1Aqh/l9gcSHCYgIqC1rqs6LjnvP9o9SCAGUqmUplDY2gBoaGgoAiilQhG/qQQi0u7PP/ZLyuWKLC1lbyQ5o6Pv2vL5je9RFCd5oec8wDnX4Z1oZ2dbstnVpZGRN+0A2Wy2bmbmS0MiNDv79UmhUJAoiiqJgBKRtjAMJ4vFoiuVSto5txkEwWsRGc5kMi8BFha+HauvD7qiKLronDsRBEHY0tISNDU13Ve5XK5zd3f3VRRFTmutlFKqps87wDRwCzhKdQ4452Ig1djY+EwtLi72KKWGlFJ7IlLviTGQSlQ8Iv9PebtOROa11votsOrJUkMWwNWs5CjjxFZKPdKZTGYaaAcee/WELMnjqamaxJeBbmPMbWWt1cYYB2Ct7QR6gPM11ahpp+TnMWyMyVtrq8/QWqsBMcaI968A14HjnlgGngJDxpjPPidljIl/u5rW2hTgjDFirU0DV4FTwKAxZnZ/DsBPrDKEljYmwJEAAAAASUVORK5CYII=&logoColor=white)
 ![Bash Script](https://img.shields.io/badge/bash_script-%23121011.svg?style=for-the-badge&logo=gnu-bash&logoColor=white)

A lightweight, zero-dependency Bash script that analyzes your **Pi-hole**'s performance. It calculates latency percentiles (Median, 95th), groups query speeds into "Tiers" (buckets), and—optionally—monitors your **Unbound** recursive DNS server statistics and memory usage.

This tool helps you answer: *"Is my DNS slow because of my upstream provider, or is it just my local network?"* and *"Is Unbound performing efficiently?"*

## Features

* **Latency Analysis:** Calculates Average, Median, and 95th Percentile latency.
* **Tiered Grouping:** Groups queries into buckets (e.g., <1ms, 10-50ms) to easily spot outliers.
* **Domain Filtering:** Supports **Wildcards** (`*`, `?`).
* **Unbound Integration:** Auto-detects Unbound to report Cache Hit Ratio, Prefetch jobs, and Cache Memory Usage.
* **Snapshot Mode:** Safely copies the database before analysis to prevent "Database Locked" errors. Includes **Smart RAM Safety** to choose between RAM (fast) or Disk (safe) snapshots automatically.
* **Locale Safe:** Forces standard formatting to prevent crashes on non-English systems (fixes comma vs dot decimal issues).
* **Flexible Filtering:** Filter by time (last 24h, 7 days), specific date ranges (`-from`, `-to`), status (Blocked/Forwarded), or specific domains.
* **JSON Support:** Native JSON output for dashboards (Home Assistant, Grafana, Node-RED).
* **Resilient:** Handles database locks (waits if Pi-hole is writing) and strictly validates arguments.
* **Configuration Profiles:** Define default arguments inside the config file to create preset "Profiles" that override CLI flags.
* **Sequential Saving:** Automatically number your saved reports (e.g., `report_1.txt`) to prevent overwrites.
* **Auto-Cleanup:** Built-in log rotation to delete old report files automatically.
* **Flexible Paths:** Load configurations and save reports to **any folder** on your system.
* **Zero Dependencies:** Uses standard tools (`sqlite3`, `bc`, `awk`, `sed`) pre-installed on most Pi-hole distros.

## Requirements

* Pi-hole (v5 or v6)
* `sqlite3` (usually installed by default)
* *(Optional)* `unbound` and `unbound-host` (for Unbound statistics)

## Quick Start

Download and run:

```bash
wget -O pihole_stats.sh https://github.com/panoc/pihole-latency-stats/releases/latest/download/pihole_stats.sh
chmod +x pihole_stats.sh
sudo ./pihole_stats.sh

```

## Usage

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

## Configuration File

On the first run, the script creates `pihole_stats.conf` in the same directory. You can edit this file to permanently set your preferences:

1. **Define Latency Tiers:** Customize your buckets (e.g., `L01="0.5"` for 0.5ms).
2. **Default Save Directory:** Set `SAVE_DIR` to a folder where `-f` files will be saved automatically.
3. **Unbound Settings:** Set `ENABLE_UNBOUND` to `auto` (default), `true` (always on), or `false`.
4. **Auto-Delete:** Set `MAX_LOG_AGE` to automatically delete old reports every time the script runs.

## Unbound Integration

The script attempts to **Auto-Detect** Unbound. It checks if:

1. Unbound is installed and the service is active.
2. Pi-hole is configured to use it.

* **Pi-hole v5:** Checks `setupVars.conf` or `dnsmasq.d` configs.
* **Pi-hole v6:** Checks `pihole.toml` for localhost upstreams.

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

## Understanding the Metrics

### Pi-hole Metrics

* **Average Latency:** The mathematical mean of all query times.
* **Median Latency (p50):** The "middle" query. 50% of your queries were faster than this.
* **95th Percentile (p95):** The "worst case" for most users. 95% of your queries were faster than this; only the slowest 5% took longer.
* **Tiers:**
* **Tier 0 (< 0.1ms):** Instant answers. Usually cached by Pi-hole or Blocked.
* **Tier 1-3 (1ms - 50ms):** Healthy upstream responses.
* **Tier 6+ (> 300ms):** Slow queries. These might be timeouts or packet loss.

### Unbound Metrics

* **Cache Hit Ratio (CHR):** The percentage of queries answered purely from Unbound's RAM. Higher is better (usually >80% after a few days).
* **Prefetch Jobs:** The number of times Unbound refreshed a cached item *before* it expired. This means the client got an instant answer instead of waiting.
* **Cache Memory Usage:** Shows how much RAM is actually being used vs the limit you set in `msg-cache-size` and `rrset-cache-size`.

## Automated Reports (Cron)

To generate a daily report at 11:55 PM and auto-delete logs older than 30 days:

```bash
# Open crontab
crontab -e

# Add this line:
55 23 * * * /home/pi/pihole_stats.sh -24h -j -f "daily_stats.json" -rt 30 -s

```

## Example Output

<details>
<summary><strong>Click to expand Text Report</strong></summary>

```text
=========================================================
              Pi-hole Latency Analysis v3.0
=========================================================
Analysis Date : 2026-01-18 12:30:00
Time Period   : Last 24 Hours
Query Mode    : All Normal Queries
---------------------------------------------------------
Total Queries         : 45,200
Unsuccessful Queries  : 500 (1.1%)
Total Valid Queries   : 44,700
Blocked Queries       : 8,500 (19.0%)
Analyzed Queries      : 36,200 (81.0%)
Average Latency       : 12.50 ms
Median  Latency       : 0.85 ms
95th Percentile       : 45.20 ms

--- Latency Distribution of Analyzed Queries ---
Tier 0 (< 0.009ms)        :  10.50%  (3801)
Tier 1 (0.009 - 0.1ms)    :  65.20%  (23602)
Tier 2 (0.1 - 1ms)        :  15.10%  (5466)
Tier 3 (1 - 10ms)         :   5.20%  (1882)
Tier 4 (10 - 50ms)        :   3.00%  (1086)
Tier 5 (> 50ms)           :   1.00%  (363)

=========================================================
              Unbound DNS Performance
=========================================================
Server Status     : Active (Integrated)
Config File       : /etc/unbound/unbound.conf
---------------------------------------------------------
Total Queries     : 145,200
Cache Hits        : 112,750 (77.65%)
Cache Misses      : 32,450 (22.35%)
Prefetch Jobs     : 15,200 (13.48% of Hits)

       --- Cache Memory Usage (Used / Limit) ---
Message Cache     : 4.20 MB / 50.00 MB   (8.40%)
RRset Cache       : 8.50 MB / 100.00 MB  (8.50%)
=========================================================
Total Execution Time: 0.85s

```

</details>

<details>
<summary><strong>Click to expand JSON Structure</strong></summary>

```json
{
  "version": "3.0",
  "date": "2026-01-18 12:30:00",
  "time_period": "Last 24 Hours",
  "mode": "All Normal Queries",
  "stats": {
    "total_queries": 45200,
    "unsuccessful": 500,
    "total_valid": 44700,
    "blocked": 8500,
    "analyzed": 36200
  },
  "latency": {
    "average": 12.50,
    "median": 0.85,
    "p95": 45.20
  },
  "tiers": [
    {"label": "Tier 0 (< 0.009ms)", "count": 3801, "percentage": 10.50},
    {"label": "Tier 1 (0.009 - 0.1ms)", "count": 23602, "percentage": 65.20}
  ],
  "unbound": {
    "status": "active",
    "total": 145200,
    "hits": 112750,
    "miss": 32450,
    "prefetch": 15200,
    "ratio": 77.65,
    "memory": {
        "msg": { "used_mb": 4.20, "limit_mb": 50.00, "percent": 8.40 },
        "rrset": { "used_mb": 8.50, "limit_mb": 100.00, "percent": 8.50 }
    }
  }
}

```

</details>

