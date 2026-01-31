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

## ✨ Key Features
 **🔍 Latency Analysis**  Calculates **Average**, **Median**, and **P95** latency to spot jitters. 
 
 **📈 Tiered Grouping**  Groups query speeds into "Tiers" (e.g., `<10ms`, `10-50ms`) for easy analysis. 
 
 **🔄 Unbound Integration**  Auto-detects Unbound to report **Cache Hit Ratio**, **Prefetching**, and **RAM Usage**. 
 
 **📸 Snapshot Mode**  Safely copies the database before analysis to prevent `Database Locked` errors.
 
 **🎯 Smart Filtering**  Filter by **Time** (24h, 7d), **Status** (Blocked/Forwarded), or **Domain** (Wildcards supported). 
 
 **🤖 Automation Ready**  Native **JSON output** for Home Assistant, Grafana, or Node-RED integration. 


---

## Requirements

* `sqlite3` (usually installed by default)
* *(Optional)* `unbound` and `unbound-host` (for Unbound statistics)

---

## Quick Start (One-Step Install)

To install the core script, the web dashboard, and all required dependencies, run:

```bash
wget -O install_phls.sh https://github.com/panoc/pihole-latency-stats/releases/latest/download/install_phls.sh && sudo bash install_phls.sh

```

### 👉 [Manual Installation Guide](https://github.com/panoc/pihole-latency-stats/blob/main/docs/MANUAL_INSTALLATION.md)

---

## 📊 Visual Dashboard

Includes a modern, responsive browser dashboard powered by **Chart.js**.

*Features: Auto-refresh, Dark Mode, Historical Trends, and Multi-Profile support.*

<a href="https://raw.githubusercontent.com/panoc/pihole-latency-stats/main/assets/phls_gif_small.gif" target="_blank">
<img src="https://raw.githubusercontent.com/panoc/pihole-latency-stats/main/assets/phls_gif_small.gif" alt="Dashboard Screenshot" width="100%" style="border-radius: 6px; box-shadow: 0 4px 15px rgba(0,0,0,0.3);">
</a>

---


## 🛠️ Real-World Use Cases

### 1. Diagnosing "Is it me or the ISP?"

Speed tests measure bandwidth, not latency. DNS lag is the primary cause of sluggish browsing.

* **The Test:** Compare your **Local** speed vs **Upstream** speed.
* `./pihole_stats.sh -pi` (Cached/Local answers)
* `./pihole_stats.sh -up` (Cloudflare/Google/ISP answers)



> **💡 The Insight**
> * If **`-pi` is slow (> 10ms):** Your Raspberry Pi might be overloaded or using a slow SD card.
> * If **`-up` is slow (> 100ms):** Your ISP or upstream DNS provider is having issues.
> 
> 

### 2. Optimizing Unbound Performance

If you run Unbound as a recursive resolver, blind trust isn't enough. Verify your efficiency.

* **The Strategy:** Run `./pihole_stats.sh -up` to strictly analyze upstream resolution speed. Compare the **Average** against a standard forwarder (like `1.1.1.1`).
* **Deep Inspection:** Use the `-ucc` flag to count the exact number of **Messages** and **RRsets** in RAM.

> **💡 The Insight**
> If your **Cache Hit Ratio** stays low (< 50%) after 24 hours, consider increasing `cache-min-ttl` in your Unbound config.

### 3. Domain-Specific Debugging

Services like work VPNs or streaming sites often behave differently than general traffic.

* **The Test:** Filter stats for specific domains.
* `./pihole_stats.sh -dm "netflix"` (Matches `netflix.com`, `nflxso.net`, etc.)
* `./pihole_stats.sh -edm "my-work-vpn.com"` (Exact match only)

> **💡 The Insight**
> You might find that while your global average is **20ms**, specific queries are hitting **Tier 8 (>1000ms)**, indicating a routing timeout.

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

---

