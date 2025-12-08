# 🚀 NOU Setup Instructions for Non-Admin Users

## 📌 Overview
This guide explains how to set up the **New Outlook Uninstaller (NOU)** script to run automatically on startup **without requiring administrator privileges**.

## 📂 Step 1: Place the Script in the Root of `D:` Drive
1. Copy the `NOU.ps1` script to the root of your `D:` drive.
2. Ensure the full path is:
   ```
   D:\NOU.ps1
   ```

## 📌 Step 2: Create a Shortcut for Startup
1. **Create a Shortcut**:
   - Right-click on your desktop and select **New > Shortcut**.
   - In the location field, enter:
     ```
     powershell.exe -ExecutionPolicy Bypass -File "D:\NOU.ps1"
     ```
   - Click **Next**, name it **NOU**, and click **Finish**.

## 📂 Step 3: Move the Shortcut to the Startup Folder
1. Press `Win + R`, type:
   ```
   shell:startup
   ```
   and hit **Enter**.
2. Move the `NOU.lnk` (shortcut) into this **Startup** folder.
3. Restart your PC to check if it runs on startup.

## ✅ Notes
- **This setup ensures the script runs on every startup without requiring administrator privileges.**
- If the script does not run, check that **PowerShell execution policy** allows scripts (`Set-ExecutionPolicy Unrestricted`).

---

Let me know if you need further assistance! 🚀
