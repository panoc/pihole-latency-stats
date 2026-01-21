# 🚀 Guide: Creating and Using Custom Profiles

A **Profile** is simply a specific configuration file that tells the script exactly what to analyze and where to save the results without you having to type long commands every time.

---

## Step 1: Create a New Profile File

We will create a profile called `streaming`. This profile will monitor only "Netflix" and "Disney" traffic.

1. **Navigate to your folder:**
```bash
cd ~/phls

```


2. **Generate the new profile file:**
Use the `-mc` (make config) flag followed by the name you want for the file.
```bash
sudo ./pihole_stats.sh -mc streaming.conf

```


*Now you have a new file named `streaming.conf` inside your `phls` folder.*

---

## Step 2: Edit the Profile Settings

Now we need to tell this profile what to do. We will use the `nano` editor.

1. **Open the file:**
```bash
sudo nano streaming.conf

```


2. **Add your "Automation" rules:**
Scroll down to the `CONFIG_ARGS` line. This is where the magic happens. Anything you put here will run automatically when you load this profile.
**To monitor without a Dashboard (Text only):**
```bash
CONFIG_ARGS='-dm "netflix" -dm "disney" -24h'

```


**To monitor WITH a Dashboard:**
```bash
CONFIG_ARGS='-dm "netflix" -dm "disney" -24h -j'

```


*(Note: The `-j` is required to send data to the dashboard.)*
3. **Set the Dashboard Paths:**
To see this on the web, you must tell the profile where to save the data.
* **SAVE_DIR_JSON**: Change this to `"/var/www/html/admin/img/dash"`.
* **JSON_NAME**: Change this to `"dash_streaming.json"`.
*(The `dash_` prefix is important for the dashboard to find it.)*


4. **Save and Exit:**
Press `Ctrl+O`, then `Enter`, then `Ctrl+X`.

---

## Step 3: Load and Run the Profile

To run the script using your new settings, use the `-c` (config) flag.

**Run it manually:**

```bash
sudo ./pihole_stats.sh -c streaming.conf

```

*Because of your `CONFIG_ARGS`, the script automatically knows to look for Netflix/Disney traffic and (if you added `-j`) update the dashboard data.*

---

## Step 4: View the Dashboard (Web)

If you enabled the dashboard settings in Step 2, you can view your specific "Streaming" stats in your browser:

**URL Format:** `http://<your-pi-ip>/admin/img/dash/dash.html?p=streaming`

*The `?p=streaming` tells the webpage to look for `dash_streaming.json` instead of the default file.*

---

## Step 5: Automate with Cron

To make this profile update itself every 30 minutes without you doing anything:

1. **Open the Cron editor:**
```bash
sudo crontab -e

```


2. **Add the command at the bottom:**
(Replace `pi` with your username and ensure you point to the custom config).
```bash
# Update the Streaming Dashboard every 30 mins
*/30 * * * * /home/pi/phls/pihole_stats.sh -c /home/pi/phls/streaming.conf -s

```


* **`-c`**: Tells it which profile to use.
* **`-s`**: Tells it to be "Silent" (essential for background tasks).



---

### Summary Checklist for Noobs:

* **Create:** `sudo ./pihole_stats.sh -mc name.conf`
* **Edit:** Put your favorite flags in `CONFIG_ARGS='...'`
* **Dash:** Set `JSON_NAME="dash_name.json"` and add `-j` to args
* **Run:** `sudo ./pihole_stats.sh -c name.conf`
* **Web:** Visit `dash.html?p=name`
