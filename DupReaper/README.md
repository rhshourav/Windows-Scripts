# DupReaper (Drip Script)

A lightweight PowerShell utility for managing and cleaning duplicate files on Windows systems.

---

## ⚡ Quick Install (One-liner)

Run directly from PowerShell:

```powershell
iex (irm https://raw.githubusercontent.com/rhshourav/Windows-Scripts/refs/heads/main/DupReaper/drip.ps1)
```

---

## 📌 Features

* 🔍 Detect duplicate files across directories
* 🧹 Clean and remove redundant files
* ⚡ Fast scanning with optimized hashing
* 🖥️ Simple CLI-based interface
* 🔐 Optional admin privilege detection

---

## 🛠️ Requirements

* Windows 10 / 11
* PowerShell 5.1 or newer
* Administrator privileges (recommended for full access)

---

## 🚀 Usage

### Run locally:

```powershell
.\drip.ps1
```

### Run from internet (quick method):

```powershell
iex (irm <script-url>)
```

---

## ⚠️ Security Warning

Running scripts directly from the internet using `iex (irm ...)` can be dangerous.

Always review the script before running:

```powershell
irm <script-url> | notepad
```

Remote scripts can be modified at any time and may execute harmful code. ([BleepingComputer][1])

---

## 🧩 How It Works

* Scans selected directories
* Generates hashes for files
* Identifies duplicates
* Prompts or auto-removes based on configuration

---

## 🐞 Troubleshooting

### Script errors (like missing `)` or `}`)

* Ensure the script is fully downloaded
* Re-download latest version
* Check PowerShell execution policy:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

---

## 🤝 Contributing

Pull requests and improvements are welcome.

---

## 📜 License

MIT License (or specify your license here)

---

## 👤 Author

**rhshourav**

GitHub: [https://github.com/rhshourav](https://github.com/rhshourav)
