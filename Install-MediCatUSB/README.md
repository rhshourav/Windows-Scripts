# 🚀 Install-MediCatUSB (by rhshourav)

A professional, automated wrapper for the **MediCat USB Installer**. This script simplifies the process of creating a bootable MediCat USB drive by handling dependencies, Ventoy installation, and file extraction via a clean, interactive PowerShell and Batch interface.

Part of the [Windows-Scripts](https://www.google.com/search?q=https://github.com/rhshourav/Windows-Scripts) collection.

## ⚡ Quick Start (PowerShell)

Open **PowerShell** as Administrator and paste the following command to begin:

```powershell
iex (irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/main/Install-MediCatUSB/Run-MediCat.ps1)

```

---

## ✨ Features

* **Automated Ventoy Setup:** Automatically fetches and installs the latest version of Ventoy to your USB.
* **Safety First:** Includes logic to detect and block accidental selection of the `C:` drive.
* **Professional UI:** Custom-branded ASCII art and color-coded terminal interface.
* **Dependency Management:** Automatically downloads required tools like `7-Zip` and `curl` binaries if they are missing.
* **Integrity Checks:** Verifies file sizes and hashes to ensure your download isn't corrupted.
* **Smart Cleanup:** PowerShell bootstrapper ensures no temporary scripts are left on your system after execution.

## 🛠️ How it Works

1. **The Bootstrapper:** A PowerShell script fetches the main installer from GitHub and sets up a secure temporary environment.
2. **Initial Checks:** The script verifies internet connectivity and administrative privileges.
3. **User Selection:** An interactive GUI folder browser allows you to pick your USB drive.
4. **Customization:** You choose between **GPT/MBR** partition styles and whether to enable **Secure Boot**.
5. **Extraction:** The script extracts the MediCat files (v21.12) directly to the USB.

## 📁 Repository Structure

* `Run-MediCat.ps1`: The professional PowerShell wrapper (Remote Runner).
* `Install.bat`: The core logic for drive preparation and extraction.
* `bin/`: Support binaries (7-Zip, QuickSFV, UI tools).

## ⚠️ Requirements

* **Operating System:** Windows 10 or 11 (Standard builds).
* **USB Drive:** Minimum 32GB (64GB+ recommended).
* **Internet:** Required for downloading Ventoy and MediCat files.

---

## 🤝 Credits

* **Original Tool:** MediCat USB by **Jayro**.
* **Installer Logic:** Original batch installer by **Mon5termatt**.
* **Modifications:** Customized for the **rhshourav** Windows-Scripts repository.

## 🔗 Links

* [Official MediCat Website](https://medicatusb.com/)
* [My GitHub Profile](https://github.com/rhshourav)
