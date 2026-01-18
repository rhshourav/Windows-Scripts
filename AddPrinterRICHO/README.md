# RICOH Network Printer Auto-Installers (PowerShell)

This repository contains **two hardened PowerShell auto-installers** for deploying RICOH network printers on Windows systems **without relying on PrintManagement cmdlets** (`Get-Printer`, `Add-Printer`), which are known to hang or fail on corrupted spooler environments.

Both scripts are designed for **silent, repeatable, administrator-driven deployments** in enterprise networks.

---

## 📂 Included Installers

### 1️⃣ RICOH Monochrome Printer Installer
**Target Model**
- RICOH MP 2555 PCL 6

**Driver Package**
- ZIP source: `RPrint_driver.zip`

**Purpose**
- Deploys a monochrome RICOH printer using an LPR TCP/IP port
- Suitable for standard office black & white printing

---

### 2️⃣ RICOH Color Printer Installer
**Target Model**
- RICOH IM C2000 PCL 6

**Driver Package**
- ZIP source: `SCP2000_PCL.zip`

**Purpose**
- Deploys a color RICOH printer using an LPR TCP/IP port
- Intended for secure or controlled color-print environments

---

## ⚙️ Key Features (Both Scripts)

- Downloads signed RICOH driver ZIPs from GitHub
- Validates ZIP integrity before extraction
- Extracts drivers to `C:\Drivers\...`
- Registers drivers via `PrintUIEntry (/ia)`
- Creates **LPR TCP/IP ports** using `prnport.vbs`
- Verifies port creation via **WMI/CIM**
- Installs printers via `PrintUIEntry (/if)`
- Supports safe cleanup of existing printers, ports, and drivers
- Avoids fragile PrintManagement PowerShell cmdlets entirely

---

## 🖨️ Network Port Configuration

Both installers create an **LPR port** with the following characteristics:

- **Port Name Format:**  
```

LPR_<PrinterIP>

```
Example:
```

LPR_192.168.18.245

```

- **Protocol:** LPR  
- **Port:** 515  
- **Queue Name:** `secure`  
- **Double Spooling:** Enabled (where supported)

This naming convention is intentional and stable across Windows builds.

---

## 📥 Download Location

Driver ZIP files are downloaded to the current user’s TEMP directory:

```

%TEMP%\RPrint_driver.zip
%TEMP%\SCP2000_PCL.zip

````

The script **verifies**:
- File existence
- Minimum size
- ZIP signature (`PK` header)

Extraction will not proceed if validation fails.

---

## ▶️ How to Run

1. Open **PowerShell/CMD as Administrator**
2. Navigate to the script directory
3. Run the installer:
For B&W:
```powershell
.\addRICHO.ps1
````
````bat
.\printerSetupRICHO.cmd
````
or 
````
iex (irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/addRICHO.ps1)
````
For Color:
```powershell
.\addColorRICHO.ps1
````
````bat
.\printerSetupCRICHO.cmd
````
or 
````
iex (irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/AddPrinterRICHO/addColorRICHO.ps1)
````

Optional cleanup switches:

```powershell
.\addRICHO.ps1 -ForceFullCleanup -RemoveDriver
```

---

## 🔐 Requirements

* Windows 10 / 11 or Windows Server
* Administrator privileges
* Print Spooler service enabled
* Network connectivity to the printer IP
* LPR enabled on the printer device

---

## ❗ Notes & Best Practices

* Do **not** rename TCP/IP ports after installation
* Ensure the **driver model name exactly matches the INF**
* Avoid using bare IP addresses as port names
* These scripts are intended for **IT-managed systems**, not end-user execution

---

## 🧑‍💻 Author

**Shourav (rhshourav)**
Cybersecurity & Systems Engineering
GitHub: [https://github.com/rhshourav](https://github.com/rhshourav)

---

## 📄 License

Internal / administrative usage.
No warranty expressed or implied.
