
---
layout: default
---

<div align="center">

# Pi-hole Latency Stats

[![GitHub release (latest by date)](https://img.shields.io/github/v/release/panoc/pihole-latency-stats?style=for-the-badge&color=dd4b39)](https://github.com/panoc/pihole-latency-stats/releases)
[![License](https://img.shields.io/github/license/panoc/pihole-latency-stats?style=for-the-badge&color=3c8dbc)](LICENSE)
[![GitHub main commit activity](https://img.shields.io/github/commit-activity/m/panoc/pihole-latency-stats?style=for-the-badge&color=f39c12)](https://github.com/panoc/pihole-latency-stats/commits/main)

<br>

**A lightweight, zero-dependency analytics suite for Pi-hole & Unbound.** *Diagnose latency, visualize cache health, and optimize your DNS performance.*

[View on GitHub](https://github.com/panoc/pihole-latency-stats){: .btn } [Download Latest](https://github.com/panoc/pihole-latency-stats/releases/latest){: .btn }

</div>

---

## ⚡ Quick Start

Install or update everything (Core Script + Dashboard) with a single command:

```bash
wget -O install_phls.sh https://github.com/panoc/pihole-latency-stats/releases/latest/download/install_phls.sh && sudo bash install_phls.sh

```

> **Note:** The installer will guide you through setting up **Cron Jobs**, creating **Profiles**, and installing the **Dashboard**.

---

## 📊 Visual Dashboard

Includes a modern, responsive browser dashboard powered by **Chart.js**.

*Features: Auto-refresh, Dark Mode, Historical Trends, and Multi-Profile support.*

<a href="https://raw.githubusercontent.com/panoc/pihole-latency-stats/main/assets/dash_ss_1280.jpg" target="_blank">
<img src="https://raw.githubusercontent.com/panoc/pihole-latency-stats/main/assets/dash_ss_1280.jpg" alt="Dashboard Screenshot" width="100%" style="border-radius: 6px; box-shadow: 0 4px 15px rgba(0,0,0,0.3);">
</a>

---

## ✨ Key Features

| Feature | Description |
| --- | --- |
| **🔍 Latency Analysis** | Calculates **Average**, **Median**, and **P95** latency to spot jitters. |
| **📈 Tiered Grouping** | Groups query speeds into "Tiers" (e.g., `<10ms`, `10-50ms`) for easy analysis. |
| **🔄 Unbound Integration** | Auto-detects Unbound to report **Cache Hit Ratio**, **Prefetching**, and **RAM Usage**. |
| **📸 Snapshot Mode** | Safely copies the database before analysis to prevent `Database Locked` errors. |
| **🎯 Smart Filtering** | Filter by **Time** (24h, 7d), **Status** (Blocked/Forwarded), or **Domain** (Wildcards supported). |
| **🤖 Automation Ready** | Native **JSON output** for Home Assistant, Grafana, or Node-RED integration. |

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

---

## 📖 Documentation

Ready to dive deeper? Check out the full guides below.

[👉 Detailed Command Guide](https://github.com/panoc/pihole-latency-stats/blob/main/docs/USAGE.md){: .btn }
[👉 Profile & Config Guide](https://github.com/panoc/pihole-latency-stats/blob/main/docs/PROFILE_GUIDE.md){: .btn }

---

```

```
