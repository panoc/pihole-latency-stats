# Pi-hole Latency Stats

A lightweight Bash script to analyze your Pi-hole's DNS response times. It reads directly from the FTL database to visualize how fast your local DNS is resolving queries.

## Features
- **Dynamic Tiers:** Define your own latency buckets (e.g., <1ms, 1-10ms, >100ms).
- **Time Filtering:** Analyze the last 24h, 7d, or any custom duration.
- **Smart Metrics:** Automatically calculates **Average**, **Median**, and **95th Percentile** latency.
- **JSON Output:** Export data in raw JSON format for dashboards (Home Assistant, Node-RED, etc.).
- **Domain Filtering:** Two modes to analyze specific sites:
  - **Partial Match:** Search for any domain containing a string (e.g., "google").
  - **Exact Match:** Analyze a specific domain and its subdomains only (e.g., "google.com").
- **Sequential Saving:** Automatically number your saved reports (e.g., `report_1.txt`, `report_2.txt`) to prevent accidental overwrites.
- **External Configuration:** All settings (latency tiers, save paths) are stored in a separate `pihole_stats.conf` file, making script updates easy.
- **Query Modes:** Isolate **Upstream** (Internet) latency from **Local** (Pi-hole Cache) latency.

<p align="center">
  <img src="pihole-latency-stats.png" alt="Pi-hole Stats Screenshot">
</p>

## Installation

**Requires sqlite3**

1. Download the script:
```bash
wget -O pihole_stats.sh https://raw.githubusercontent.com/panoc/pihole-latency-stats/main/pihole_stats.sh

```

2. Make it executable:
```bash
chmod +x pihole_stats.sh

```


3. Run it once to generate the configuration file:
```bash
sudo ./pihole_stats.sh

```



## Usage

Run the script using `sudo` (required to read the Pi-hole database). You can mix and match arguments in any order.

### Basic Usage

**Analyze All Time (Default)**

```bash
sudo ./pihole_stats.sh

```

### Time Filtering

**Analyze Last 24 Hours**

```bash
sudo ./pihole_stats.sh -24h

```

**Analyze Last 7 Days**

```bash
sudo ./pihole_stats.sh -7d

```

### Saving Output (Files & Logs)

You can save the output to a file using the `-f` flag. You can also add timestamps or sequential numbering to organize your logs.

**Basic Save (Overwrites if exists)**

```bash
sudo ./pihole_stats.sh -24h -f report.txt

```

**Add Timestamp (`-ts`)**
Automatically inserts the date and time (YYYY-MM-DD_HHMM) into the filename.

* Command: `sudo ./pihole_stats.sh -f report.json -ts`
* Result: `report_2026-01-16_0930.json`

**Add Sequential Numbering (`-seq`)**
Prevents overwriting by adding a number if the file already exists.

* Command: `sudo ./pihole_stats.sh -f report.json -seq`
* Result: `report_1.json` (if `report.json` exists)

**Combine Everything (Best for Cron)**
Combine both for organized, conflict-free logs.

```bash
sudo ./pihole_stats.sh -f daily_log.json -ts -seq

```

* Result: `daily_log_2026-01-16_0930_1.json`



### JSON Output (Automation)

Use the `-j` or `--json` flag to output the results in JSON format. Useful for feeding data into other tools.

**Print JSON to screen**

```bash
sudo ./pihole_stats.sh -j

```

**Save JSON to a file**

```bash
sudo ./pihole_stats.sh -j -f stats.json

```

### Domain Filtering

Use these flags to analyze latency for specific websites.

* **`-dm` or `--domain` (Partial Match):**
Matches any query containing the string. Useful for broad searches.
* *Example:* `-dm google` finds `google.com`, `google.gr`, `google-analytics.com`, `googleapis.com`.


```bash
sudo ./pihole_stats.sh -dm google

```


* **`-edm` or `--exact-domain` (Exact Match):**
Matches the exact domain and its subdomains only. Useful for specific site analysis without "noise."
* *Example:* `-edm google.com` finds `google.com` and `www.google.com`, but **ignores** `google.gr` or `google-analytics.com`.


```bash
sudo ./pihole_stats.sh -edm netflix.com

```

### Advanced Filtering (Modes & Flags)

You can isolate specific types of queries to troubleshoot where latency is coming from.

* **`-up` (Upstream Only):** Analyzes only queries forwarded to your upstream DNS (e.g., Google, Cloudflare). Use this to check your internet connection speed.
* **`-pi` (Pi-hole Only):** Analyzes only queries answered by the Pi-hole Cache or Optimizers. Use this to check your Pi-hole hardware performance.
* **`-nx` (Exclude Upstream Blocks):** Excludes queries that were blocked by the upstream provider (Status 16/17, e.g., NXDOMAIN or 0.0.0.0 replies). Use this if you only want to measure latency for *successful* resolutions.
* **`-db` (Custom Database):** Specify a custom path to the FTL database. Useful for Docker containers or non-standard installs.

#### Examples

```bash
# Check upstream latency for the last hour
sudo ./pihole_stats.sh -up -1h

# Check upstream latency, ignore upstream blocks, and save to JSON
sudo ./pihole_stats.sh -up -nx -24h -j -f upstream_report.json

# Use a custom database path
sudo ./pihole_stats.sh -db /mnt/user/appdata/pihole/pihole-FTL.db

```

### Help command

Run sudo ./pihole_stats.sh `-h` or `--help` to see a full list of commands and examples.

## Understanding the Metrics

* **Average:** The arithmetic mean. Useful, but often skewed by a few slow queries.
* **Median (P50):** The "Middle" query. Represents your typical experience. If your cache hit rate is high, this will be near 0ms.
* **95th Percentile (P95):** The "Realistic Worst Case." 95% of your queries are faster than this. This is the best metric to judge your actual internet speed, ignoring extreme outliers.

## Configuration

On the first run, the script creates a file named `pihole_stats.conf` in the same directory. You can edit this file to:

1. **Define Latency Tiers:** Customize your buckets (e.g., 0.1ms, 50ms, 100ms).
2. **Set Default Save Directory:** Define a specific folder (e.g., `/home/pi/logs`) where all `-f` files will be saved automatically.
3. **Set Database Path:** Permanently override the default `/etc/pihole/pihole-FTL.db` location.

```bash
# Example pihole_stats.conf content

# Where to save files by default
SAVE_DIR="/home/pi/pihole_reports"

# Your custom latency buckets
L01="0.5"
L02="20"
...

