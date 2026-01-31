---
layout: default
---

<div align="center" markdown="1">

**A lightweight, zero-dependency analytics suite for Pi-hole & Unbound.** *Diagnose latency, visualize cache health, and optimize your DNS performance.*

[View on GitHub](https://github.com/panoc/pihole-latency-stats){: .btn } [Download Latest](https://github.com/panoc/pihole-latency-stats/releases/latest){: .btn }

</div>


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

## 📖 Documentation

Ready to dive deeper? Check out the full guides below.

[👉 Detailed Command Guide](https://github.com/panoc/pihole-latency-stats/blob/main/docs/USAGE.md){: .btn }

---


