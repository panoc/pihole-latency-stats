<div align="center">
  <img src="assets/favicon.png" height="100" alt="Logo">
  <br>
  
  <img src="assets/title.png" height="50" alt="Pi-hole Latency Stats">
  
  <p>
    <b>Analyze your Pi-hole and Unbound DNS response times.</b>
  </p>
</div>

**Pi-hole Latency Stats** is a lightweight, zero-dependency Bash script that analyzes your **Pi-hole**'s performance. It calculates latency percentiles (Median, 95th), groups query speeds into "Tiers" (buckets), and—optionally—monitors your **Unbound** recursive DNS server statistics and memory usage.

This tool helps you answer: *"Is my DNS slow because of my upstream provider, or is it just my local network?"* and *"Is Unbound performing efficiently?"*

<p align="center">
  <img src=https://img.shields.io/badge/pihole-%2396060C.svg?style=for-the-badge&logo=pi-hole&logoColor=white> <img src=https://img.shields.io/badge/Unbound-341893?style=for-the-badge&logo=data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAUCAYAAACEYr13AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAAYdEVYdFNvZnR3YXJlAFBhaW50Lk5FVCA1LjEuN4vW9zkAAAC2ZVhJZklJKgAIAAAABQAaAQUAAQAAAEoAAAAbAQUAAQAAAFIAAAAoAQMAAQAAAAMAAAAxAQIAEAAAAFoAAABphwQAAQAAAGoAAAAAAAAAo5MAAOgDAACjkwAA6AMAAFBhaW50Lk5FVCA1LjEuNwADAACQBwAEAAAAMDIzMAGgAwABAAAAAQAAAAWgBAABAAAAlAAAAAAAAAACAAEAAgAEAAAAUjk4AAIABwAEAAAAMDEwMAAAAAA02IfdCSajZAAAAoZJREFUOE+Vk89LVFEUxz/3jk9tdOUf0NyIMGonaYv+AGnTpn0EgYsQRGhTLWwhgSDhpogghKBaBEmbiChdhQYZRv7IwLyJjDLajKOj4/jeu6fF3BeTKdUXLu+cd873e+45917Gxt4rEdFU0ZTN5q45J6Vc7sdWa2uXAZifX7gZhpGsrOSmpqbmTvtclpdX6hKbubmFS/n8RsE5JyIia2t5GRwcPgcwMfHxk3hUKnti7fLzvr67JwHo7b0XbG6WXsRxnOTsiUi8vp6XgYGHHQDj45MfREScc3siEjvnZHu7XAnD6Kzu7798prk5fUFrHYmIE5Hg17ZA1dgAGtBKqXI63Vivte7W6fSRUCmFDySz2I/9QgGA1qqkDwj+D1KHVfxn/E1Aqh/l9gcSHCYgIqC1rqs6LjnvP9o9SCAGUqmUplDY2gBoaGgoAiilQhG/qQQi0u7PP/ZLyuWKLC1lbyQ5o6Pv2vL5je9RFCd5oec8wDnX4Z1oZ2dbstnVpZGRN+0A2Wy2bmbmS0MiNDv79UmhUJAoiiqJgBKRtjAMJ4vFoiuVSto5txkEwWsRGc5kMi8BFha+HauvD7qiKLronDsRBEHY0tISNDU13Ve5XK5zd3f3VRRFTmutlFKqps87wDRwCzhKdQ4452Ig1djY+EwtLi72KKWGlFJ7IlLviTGQSlQ8Iv9PebtOROa11votsOrJUkMWwNWs5CjjxFZKPdKZTGYaaAcee/WELMnjqamaxJeBbmPMbWWt1cYYB2Ct7QR6gPM11ahpp+TnMWyMyVtrq8/QWqsBMcaI968A14HjnlgGngJDxpjPPidljIl/u5rW2hTgjDFirU0DV4FTwKAxZnZ/DsBPrDKEljYmwJEAAAAASUVORK5CYII=&logoColor=whit > <img src=https://img.shields.io/badge/bash_script-%23121011.svg?style=for-the-badge&logo=gnu-bash&logoColor=white>

---

## Features

* **Latency Analysis:** Calculates Average, Median, and 95th Percentile latency.
* **Browser Dashboard:** A modern, responsive interface powered by Chart.js that visualizes your latency distribution and Unbound cache health. It features auto-refreshing stats, dark-mode styling, and support for custom monitoring profiles.
* **Domain Filtering:** Supports **Wildcards** (`*`, `?`).
* **Unbound Integration:** Auto-detects Unbound to report Cache Hit Ratio, Prefetch jobs, and Cache Memory Usage.
* **Snapshot Mode:** Safely copies the database before analysis to prevent "Database Locked" errors. Includes **Smart RAM Safety** to choose between RAM (fast) or Disk (safe) snapshots automatically.
* **Flexible Filtering:** Filter by time (last 24h, 7 days), specific date ranges (`-from`, `-to`), status (Blocked/Forwarded), or specific domains.
* **JSON Support:** Native JSON output for dashboards (Home Assistant, Grafana, Node-RED).
* **Configuration Profiles:** Define default arguments inside the config file to create preset "Profiles" that override CLI flags.
* **Zero Dependencies:** Uses standard tools (`sqlite3`, `bc`, `awk`, `sed`) pre-installed on most Pi-hole distros.

## Requirements

* Pi-hole (v5 or v6)
* `sqlite3` (usually installed by default)
* *(Optional)* `unbound` and `unbound-host` (for Unbound statistics)

---

## Quick Start (One-Step Install)

To install the core script, the web dashboard, and all required dependencies, run:

```bash
wget -O install_phls.sh https://github.com/panoc/pihole-latency-stats/releases/latest/download/install_phls.sh && sudo bash install_phls.sh

```

> [!TIP]
> **Existing Users:** The v3.3 installer will automatically update your configuration and preserve your settings while adding new dashboard variables.

---

##  Real-World Use Cases

### 1. Diagnosing "Is it me or the ISP?"

When your internet feels slow, speed tests often lie because they measure bandwidth, not latency. DNS lag is the #1 cause of "snappy" browsing turning sluggish.

* **The Test:** Compare your **Local** speed vs **Upstream** speed.
* `./pihole_stats.sh -pi` (Measures only cached/local answers)
* `./pihole_stats.sh -up` (Measures only answers from Cloudflare/Google/ISP)


* **The Insight:**
* If `-pi` is slow (> 10ms): Your Raspberry Pi might be overloaded or using a slow SD card.
* If `-up` is slow (> 100ms): Your ISP or upstream DNS provider is having issues.



### 2. Optimizing Unbound Performance

If you use Unbound (recursive or forwarding), blind trust isn't enough. Verify your cache efficiency.

* **Benchmark Strategy:** Run `./pihole_stats.sh -up` to strictly analyze upstream resolution speed. Compare the **Average** and **p95** latency against a standard forwarder like `1.1.1.1` to see if being recursive is actually worth the speed trade-off.
* **Tune Cache Efficiency:** Check the **Cache Hit Ratio** in the Unbound panel. If it stays low (< 50%) after 24 hours, consider increasing `cache-min-ttl`.
* **Deep Inspection:** Use `./pihole_stats.sh -ucc` to count the exact number of **Messages** and **RRsets** in RAM. This helps verify if `prefetch` is effectively keeping popular domains alive.

### 3. Domain-Specific Debugging

Sometimes specific services (like work VPNs or streaming sites) feel slow while everything else is fine.

* **The Test:** Filter stats for a specific domain.
* `./pihole_stats.sh -dm "netflix"` (Analyzes `netflix.com`, `nflxso.net`, etc.)
* `./pihole_stats.sh -edm "my-work-vpn.com"` (Exact match only)


* **The Insight:** You might find that while your average global latency is 20ms, `netflix` queries are hitting **Tier 8 (>1000ms)**, indicating a specific routing issue or blocklist conflict.

### 4. Long-Term Health Monitoring

Spot trends before they become problems by automating data collection.

* **The Setup:** Add the script to Cron to run nightly.
* `./pihole_stats.sh -24h -j -f "daily_stats.json" -rt 30`


* **The Insight:**
   * **JSON Output:** Ingest this into **Home Assistant**, **Grafana**, or **Node-RED** to visualize latency over weeks.
  * **Auto-Retention (`-rt`):** Keeps your disk clean by automatically deleting reports older than 30 days.

---

## 📖 Full Documentation

Detailed information on CLI flags, automation, and advanced tuning can be found here:

### 👉 [Detailed Usage & Command Guide](https://github.com/panoc/pihole-latency-stats/blob/main/docs/USAGE.md)

### 👉 [Profile Example & Command Guide](https://github.com/panoc/pihole-latency-stats/blob/main/docs/PROFILE_GUIDE.md)

---

