# Pi-hole Latency Stats

A lightweight Bash script to analyze your Pi-hole's DNS response times. It reads directly from the FTL database to visualize how fast your local DNS is resolving queries.

## Features
- **Dynamic Tiers:** Define your own latency buckets (e.g., <1ms, 1-10ms, >100ms).
- **Time Filtering:** Analyze the last 24h, 7d, or any custom duration.
- **Detailed Stats:** Shows percentages and raw counts for blocked vs. allowed queries.
- **Auto-Sorting:** No need to order your config variables; the script does it for you.
<p align="center">
![Pi-hole Stats Screenshot](pihole-latency-stats.png)
</p>
## Usage

1. Download the script:
```
   wget https://raw.githubusercontent.com/panoc/pihole-latency-stats/main/pihole_stats.sh
```

```
   chmod +x pihole_stats.sh

```

2. Run it (requires sudo to read the Pi-hole DB):

## Analyze All Time
sudo ./pihole_stats.sh

## Analyze Last 24 Hours
sudo ./pihole_stats.sh -24h

## Analyze Last 7 Days
sudo ./pihole_stats.sh -7d





## Configuration

Edit the top of the script to change your latency tiers:

```bash
L01="0.1"    # 0.1 ms
L02="50"     # 50 ms
...


