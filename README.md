# Pi-hole Latency Stats

A lightweight Bash script to analyze your Pi-hole's DNS response times. It reads directly from the FTL database to visualize how fast your local DNS is resolving queries.

## Features
- **Dynamic Tiers:** Define your own latency buckets (e.g., <1ms, 1-10ms, >100ms).
- **Time Filtering:** Analyze the last 24h, 7d, or any custom duration.
- **Query Modes:** Isolate **Upstream** (Internet) latency from **Local** (Pi-hole Cache) latency.
- **Cleaner Data:** Option to exclude Upstream-Blocked (NXDOMAIN/0.0.0.0) queries from your stats.
- **Detailed Stats:** Shows percentages and raw counts for blocked vs. allowed queries.
- **Auto-Sorting:** No need to order your config variables; the script does it for you.

<p align="center">
  <img src="pihole-latency-stats.png" alt="Pi-hole Stats Screenshot">
</p>

## Installation

1. Download the script:
```
wget -O pihole_stats.sh https://raw.githubusercontent.com/panoc/pihole-latency-stats/main/pihole_stats.sh

```

2. Make it executable:
```
chmod +x pihole_stats.sh

```



## Usage

Run the script using `sudo` (required to read the Pi-hole database). You can mix and match arguments in any order.

### Basic Usage

```bash
# Analyze All Time (Default)
sudo ./pihole_stats.sh

```

### Time Filtering

```bash
# Analyze Last 24 Hours
sudo ./pihole_stats.sh -24h

# Analyze Last 7 Days
sudo ./pihole_stats.sh -7d

```

### Advanced Filtering (Modes & Flags)

You can isolate specific types of queries to troubleshoot where latency is coming from.

* **`-up` (Upstream Only):** Analyzes only queries forwarded to your upstream DNS (e.g., Google, Cloudflare). Use this to check your internet connection speed.
* **`-pi` (Pi-hole Only):** Analyzes only queries answered by the Pi-hole Cache or Optimizers. Use this to check your Pi-hole hardware performance.
* **`-nx` (Exclude Upstream Blocks):** Excludes queries that were blocked by the upstream provider (Status 16/17, e.g., NXDOMAIN or 0.0.0.0 replies). Use this if you only want to measure latency for *successful* resolutions.

#### Examples

```bash
# Check upstream latency for the last hour
sudo ./pihole_stats.sh -up -1h

# Check upstream latency, but ignore upstream blocks/NXDOMAIN
sudo ./pihole_stats.sh -up -nx -24h

# Check cache performance for the last 30 days
sudo ./pihole_stats.sh -pi -30d

```

## Configuration

Edit the top of the script (`pihole_stats.sh`) to change your latency tiers. You can enter them in any order; the script sorts them automatically.

```bash
L01="0.1"    # 0.1 ms
L02="50"     # 50 ms
L03="100"    # 100 ms
...

