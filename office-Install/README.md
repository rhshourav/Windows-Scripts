# 📦 Office Install Scripts (ODT-based)

Automated installers for Microsoft Office (O365 / LTSC) using the **Office Deployment Tool (ODT)**.

These scripts download a pre-built ZIP containing `setup.exe` + XML configuration, extract it, and run the ODT to **download and install Office silently**. ([installoffice.org][1])

---

## 🗂️ Included Scripts

### 1. **O365 Installer Script**

This script performs:

1. Administrator check (must run as admin)
2. Creates temporary work directory
3. Downloads a ZIP from GitHub (`O365.zip`)
4. Extracts contents (`setup.exe` + `windows64bit.xml`)
5. Runs ODT in **download mode**
6. Monitors progress by counting files being created
7. Runs ODT in **configure (install) mode**
8. Prints output and summary

**Behavior highlights**

* Downloads Office binaries into `%TEMP%\O365_Install\Office`
* Shows progress by file count
* Automatically installs Office with configured XML

If a required file is missing, the script exits with an error.

---

### 2. **Office LTSC 2021 Auto-Installer**

This script:

1. Checks for admin rights
2. Creates a unique temp folder
3. Downloads `OLTSC-2021.zip` from a GitHub raw file
4. Extracts and finds `setup.exe` + `Configuration.xml`
5. Optionally injects silent install `<Display Level="None" AcceptEULA="TRUE" />` into the XML
6. Runs the ODT `/configure` command
7. Shows a spinner while running
8. Basic Office presence verification (looks for `WINWORD.EXE`)
9. Cleans up temp files

**Key features**

* Cleaner UI with banners & structured output
* Silent install enforced if missing from XML
* Auto removal of working directory after install

---

## ⚡ Requirements

✔ Windows 10 / 11
✔ PowerShell (run *as Administrator*)
✔ Internet access for ODT download
✔ Official ODT files + config come from your repository (these aren't from Microsoft directly — Office binaries are downloaded via the ODT tool) ([GitHub][2])

---

## 💡 One-Line Quick Run

To run the **O365 installer** directly from GitHub (replace the URL with the raw script URL):

```powershell
irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/office-Install/install-o365.ps1 | iex
```

Or for the **LTSC-2021 installer**:

```powershell
irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/office-Install/install-ltsc2021.ps1 | iex
```

**Explanation:**

* `irm` (Invoke-RestMethod) fetches the raw script text
* `iex` (Invoke-Expression) executes the script in memory
  ⚠️ *Always inspect the script before running remote code.*

---

## 📜 Example Manual Use

### Run locally after saving

1. Save script (e.g., as `install-o365.ps1`)
2. Open **PowerShell (Admin)**
3. Set execution policy for this session:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
```

4. Run:

```powershell
.\install-o365.ps1
```

---

## 🛡️ Notes & Best Practices

* Scripts assume Office binaries are in the ZIP you provide — use official ODT downloads where possible. ([GitHub][2])
* Office Deployment Tool (ODT) downloads files directly from Microsoft servers based on the XML configuration. ([GitHub][2])
* Review XML config inside each ZIP to control Office edition, languages, excluded apps, and update channels.
* Check `%TEMP%\USL-*.log` files for detailed install logs.

---

## 📌 Safety & Review

**Important**: Running scripts with `irm | iex` executes code from the web in memory. Always review the target script to ensure it’s trustworthy. Avoid running unknown scripts from unverified sources.
