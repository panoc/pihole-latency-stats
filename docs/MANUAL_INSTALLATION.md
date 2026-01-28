# 📘 Pi-hole Latency Stats: Manual Installation Guide

**Prerequisites:**

* A Raspberry Pi (or server) running Pi-hole.
* Access to the terminal (via SSH or directly).
* The `.zip` file containing your project code.

---

### Phase 1: Preparation & Dependencies

Before installing the scripts, we need to make sure your system has the necessary tools (specifically `sqlite3` for the database and `bc` for math calculations).

1. **Check your username:**
Before we begin, run this command to confirm your actual username. You will need this later to replace placeholders like `<YOUR_USERNAME>`.
```bash
whoami

```


2. **Update your system and install tools:**
Run the following command in your terminal:
```bash
sudo apt-get update
sudo apt-get install sqlite3 bc unzip

```



---

### Phase 2: Installing the Core Scripts

We will separate the main script from the automation tools for better organization. The main script lives in the root folder, while the cron tools and profiles live in a subfolder.

1. **Create the directory structure:**
We will create a main folder (`phls`) and a specific subfolder (`cron`) inside it.
```bash
mkdir -p ~/phls/cron

```


2. **Place the files:**
Transfer your files to the Pi (via SFTP or copy/paste) and place them strictly as follows:
* **Main Folder (`~/phls/`):**
  * `pihole_stats.sh` 
  * `version` 

* **Cron Subfolder (`~/phls/cron/`):**
  * `cronmaker.sh`




3. **Make the scripts executable:**
We need to tell Linux that these files are programs.
```bash
chmod +x ~/phls/pihole_stats.sh
chmod +x ~/phls/cron/cronmaker.sh

```


4. **Generate the Master Configuration:**
Run the script once manually. This generates the **default configuration file** (`pihole_stats.conf`) in the main folder.
```bash
cd ~/phls
./pihole_stats.sh

```


*You should see a text report output. This confirms the backend is working.*

---

### Phase 3: Installing the Dashboard

The visual frontend must live in the web server directory so you can view it in your browser.

1. **Create the Dashboard folder:** We will use a standard location that Pi-hole's web server can "see."
```bash
sudo mkdir -p /var/www/html/admin/img/dash

```


2. **Place the files:**
Copy/Move the following files into that new folder:
* `dash.html`
* `favicon.png`
* `version` (Copy the version file here too)


*Command line example:*
```bash
sudo cp dash.html /var/www/html/admin/img/dash/
sudo cp favicon.png /var/www/html/admin/img/dash/
sudo cp version /var/www/html/admin/img/dash/

```


3. **Download external assets:**
Since you are doing a manual install, you need to grab the styling and graphing libraries manually.
```bash
cd /var/www/html/admin/img/dash
sudo curl -L -o bootstrap.min.css https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css
sudo curl -L -o chart.js https://cdn.jsdelivr.net/npm/chart.js@3.9.1/dist/chart.min.js

```


4. **Set Permissions:**
Give the web server (user `www-data`) permission to read/write these files.
```bash
sudo chown -R www-data:www-data /var/www/html/admin/img/dash
sudo chmod -R 775 /var/www/html/admin/img/dash

```



---

### Phase 4: Automation (The Cron Job)

To update the dashboard automatically, you need a "Cron Job." You have two distinct ways to set this up.

#### Option A: Using `cronmaker.sh` (Isolated Profiles)

Your `cronmaker.sh` script uses its own **profile system**. When you create a profile (e.g., "default"), it generates a *new* config file inside `~/phls/cron/default.conf`. This keeps your automated settings separate from your manual CLI settings in the main folder.

1. **Run the Cron Maker:**
```bash
sudo ~/phls/cron/cronmaker.sh

```


2. **Follow the Prompts:**
* **Profile Name:** Type `default`.
* **Customize Tiers/Cutoffs:** Answer `n` (unless you need specific filtering).
* **Frequency:** Type `5` (minutes).
* **Unbound Stats:** Type `y`.


3. **Result:** The script automatically schedules the job. It will use the configuration file located at `~/phls/cron/default.conf`.

#### Option B: Creating the Job Manually (Explicit Config)

If you prefer to write the cron line yourself, you must be careful with paths. You should explicitly point to the **Master Configuration** file we created in Phase 2 to ensure the script behaves exactly as you configured it.

**⚠️ Critical Path Warning:**
Do not blindly copy `/home/pi/` if your username is not `pi`. Use the username you found in Phase 1.

1. **Open the Cron editor:**
```bash
sudo crontab -e

```


2. **Add the line (One single line):**
Replace `<YOUR_USERNAME>` with your actual username (e.g., `admin`, `dietpi`, `ubuntu`).
```cron
*/5 * * * * export PATH=$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; cd /home/<YOUR_USERNAME>/phls && ./pihole_stats.sh -dash "default" -c /home/<YOUR_USERNAME>/phls/pihole_stats.conf -snap -ucc >> /home/<YOUR_USERNAME>/phls/cron/default_debug.log 2>&1

```


**Breakdown of flags used:**
* `-dash "default"`: Runs in dashboard mode; output files will be named `dash_default.json`.
* 
`-c /home/<YOUR_USERNAME>/phls/pihole_stats.conf`: **Crucial.** Explicitly tells the script to use the master config file we generated in Phase 2.


* 
`-snap`: Uses a RAM snapshot for database safety and speed.


* 
`-ucc`: Includes Unbound Cache Counts.


* `>> .../cron/default_debug.log`: Redirects output to a log file in the `cron` folder for clean tracking.



---

### Phase 5: Verification

1. **Check the Dashboard:**
Open your web browser and go to:
`http://<YOUR_PI_IP>/admin/img/dash/dash.html?p=default`
2. **Force an update (Manual Test):**
If the dashboard is empty, run this command manually to populate it immediately (replace `<YOUR_USERNAME>`):
```bash
sudo /home/<YOUR_USERNAME>/phls/pihole_stats.sh -dash "default" -c /home/<YOUR_USERNAME>/phls/pihole_stats.conf -snap -ucc

```



---

### 📂 Final File Structure Summary

* **Main Script:** `~/phls/pihole_stats.sh`
* **Master Config:** `~/phls/pihole_stats.conf` (Used by Manual Cron Option B)
* **Cron Tools:** `~/phls/cron/cronmaker.sh`
* **Cron Profiles:** `~/phls/cron/default.conf` (Created/Used only if using Option A)
* **Logs:** `~/phls/cron/default_debug.log`
