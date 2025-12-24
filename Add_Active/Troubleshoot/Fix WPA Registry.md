# Fix WPA Registry (sppsvc / Activation Issues)

In some cases, Windows systems may have **corrupted WPA registry keys** located at:

```

HKEY_LOCAL_MACHINE\SYSTEM\WPA

```

When this registry area is corrupted, it can cause:

- Windows activation failures  
- `sppsvc` (Software Protection Platform Service) not working  
- High CPU usage by the `sppsvc` service  

This registry key is **kernel-protected**, meaning it cannot be deleted or modified during normal Windows operation. To fix it, the system must be booted into the **Windows Recovery Environment (WinRE)** and cleaned from there.

---

## When Should You Do This?

Only perform this fix if you are experiencing:
- Persistent activation problems
- `sppsvc` errors or abnormal CPU usage
- Activation-related system instability

If you are unsure, seek guidance before proceeding.

---

## Steps to Fix WPA Registry

### 1. Prepare the Repair Script

- Download the `rearm` utility archive
- Extract the ZIP file
- Copy **`rearm.cmd`** to the root of the system drive:

```

C:\rearm.cmd

````

---

### 2. Reboot into Advanced Startup

Open **Command Prompt as Administrator** and run:

```cmd
shutdown /f /r /o /t 0
````

This will immediately reboot the system into **Advanced Startup**.

---

### 3. Open Command Prompt in Recovery Mode

After restart:

1. Select **Troubleshoot**
2. Go to **Advanced Options**
3. Choose **Command Prompt**

---

### 4. Run the Repair Script

In the recovery command prompt, enter:

```cmd
C:\rearm.cmd
```

If the command is **not recognized**, determine the correct Windows drive letter:

```cmd
bcdedit | find "osdevice"
```

Example output may show something like `partition=E:`
In that case, run:

```cmd
E:\rearm.cmd
```

---

### 5. Wait for Completion

* Allow the script to fully finish
* Do not interrupt the process
* When the command prompt becomes responsive again, the operation is complete

---

### 6. Boot Back into Windows

* Exit the command prompt
* Continue with a normal Windows boot

---

## Summary

This process clears corrupted **WPA registry data** that cannot be fixed from within a running Windows environment.
It is an advanced recovery method used to resolve activation-related issues and `sppsvc` service problems caused by registry corruption.

Use only when necessary and with administrative access.
