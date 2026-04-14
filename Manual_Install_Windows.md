# راهنمای نصب دستی WinNet XUI Sync برای ویندوز

## مرحله ۱ — دانلود پروژه از GitHub

به آدرس زیر بروید و فایل ZIP پروژه را دانلود کنید:

```
https://github.com/Win-Net/sync_xui_sqlite/archive/refs/heads/main.zip
```

یا با PowerShell:

```powershell
Invoke-WebRequest -Uri "https://github.com/Win-Net/sync_xui_sqlite/archive/refs/heads/main.zip" -OutFile "main.zip"
```

---

## مرحله ۲ — استخراج فایل ZIP

```powershell
Expand-Archive -Path "main.zip" -DestinationPath "."
cd sync_xui_sqlite-main
```

---

## مرحله ۳ — نصب Python

اگر Python نصب ندارید، آن را دانلود و نصب کنید:

```powershell
# دانلود Python
Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.11.5/python-3.11.5-amd64.exe" -OutFile "python-installer.exe"

# نصب Python
Start-Process -FilePath "python-installer.exe" -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1" -Wait
```

---

## مرحله ۴ — ایجاد محیط مجازی و نصب وابستگی‌ها

```powershell
# ایجاد محیط مجازی
python -m venv venv

# فعال‌سازی محیط مجازی
.\venv\Scripts\Activate

# نصب وابستگی‌ها
python -m pip install --upgrade pip requests
```

---

## مرحله ۵ — انتقال فایل‌ها به محل نصب

```powershell
# ایجاد پوشه نصب
New-Item -ItemType Directory -Force -Path "$env:ProgramFiles\WinNet"

# کپی فایل‌ها
Copy-Item "sync_xui_sqlite.py" "$env:ProgramFiles\WinNet\"
Copy-Item "sync_inbound_tunnel.py" "$env:ProgramFiles\WinNet\"
Copy-Item "install.ps1" "$env:ProgramFiles\WinNet\"
Copy-Item "winnet-cli.ps1" "$env:ProgramFiles\WinNet\"

# کپی محیط مجازی
Copy-Item -Recurse "venv" "$env:ProgramFiles\WinNet\"
```

---

## مرحله ۶ — نصب NSSM (Non-Sucking Service Manager)

```powershell
# دانلود NSSM
Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile "nssm.zip"

# استخراج NSSM
Expand-Archive -Path "nssm.zip" -DestinationPath "nssm-temp"

# کپی NSSM
Copy-Item "nssm-temp\nssm-2.24\win64\nssm.exe" "$env:ProgramFiles\WinNet\"

# پاکسازی
Remove-Item -Recurse "nssm-temp", "nssm.zip"
```

---

## مرحله ۷ — ایجاد سرویس‌ها

```powershell
# ایجاد سرویس همگام‌سازی کلاینت
& "$env:ProgramFiles\WinNet\nssm.exe" install WinNetXUISync "$env:ProgramFiles\WinNet\venv\Scripts\python.exe" "$env:ProgramFiles\WinNet\sync_xui_sqlite.py" --db "$env:ProgramData\x-ui\x-ui.db" --interval 30 --apply --backup
& "$env:ProgramFiles\WinNet\nssm.exe" set WinNetXUISync DisplayName "WinNet XUI Sync"
& "$env:ProgramFiles\WinNet\nssm.exe" set WinNetXUISync Description "Sync X-UI subscriptions"
& "$env:ProgramFiles\WinNet\nssm.exe" set WinNetXUISync Start SERVICE_AUTO_START

# ایجاد سرویس همگام‌سازی تانل
& "$env:ProgramFiles\WinNet\nssm.exe" install WinNetTunnelSync "$env:ProgramFiles\WinNet\venv\Scripts\python.exe" "$env:ProgramFiles\WinNet\sync_inbound_tunnel.py" --db "$env:ProgramData\x-ui\x-ui.db" --interval 30 --apply --backup
& "$env:ProgramFiles\WinNet\nssm.exe" set WinNetTunnelSync DisplayName "WinNet Tunnel Sync"
& "$env:ProgramFiles\WinNet\nssm.exe" set WinNetTunnelSync Description "Sync X-UI tunnel inbound traffic"
& "$env:ProgramFiles\WinNet\nssm.exe" set WinNetTunnelSync Start SERVICE_AUTO_START
```

---

## مرحله ۸ — ایجاد دستور CLI

```powershell
# ایجاد فایل batch برای CLI
$cliContent = @"
@echo off
powershell -ExecutionPolicy Bypass -File "$env:ProgramFiles\WinNet\winnet-cli.ps1" %*
"@
Set-Content -Path "$env:ProgramFiles\WinNet\winnet-xui.cmd" -Value $cliContent

# اضافه کردن به PATH
$currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($currentPath -notlike "*$env:ProgramFiles\WinNet*") {
    [Environment]::SetEnvironmentVariable("Path", "$currentPath;$env:ProgramFiles\WinNet", "Machine")
}
```

---

## مرحله ۹ — راه‌اندازی اولیه (Init)

```powershell
# اجرای init برای کلاینت
& "$env:ProgramFiles\WinNet\venv\Scripts\python.exe" "$env:ProgramFiles\WinNet\sync_xui_sqlite.py" --db "$env:ProgramData\x-ui\x-ui.db" --init

# اجرای init برای تانل
& "$env:ProgramFiles\WinNet\venv\Scripts\python.exe" "$env:ProgramFiles\WinNet\sync_inbound_tunnel.py" --db "$env:ProgramData\x-ui\x-ui.db" --init
```

---

## مرحله ۱۰ — راه‌اندازی سرویس‌ها

```powershell
# راه‌اندازی سرویس کلاینت
Start-Service -Name WinNetXUISync

# راه‌اندازی سرویس تانل
Start-Service -Name WinNetTunnelSync
```

---

## مرحله ۱۱ — مدیریت سرویس‌ها

```powershell
# باز کردن منوی مدیریت
winnet-xui
```

---

## بررسی وضعیت سرویس‌ها

```powershell
# بررسی وضعیت سرویس‌ها
Get-Service -Name WinNetXUISync, WinNetTunnelSync

# مشاهده لاگ‌ها (در Event Viewer ویندوز)
# Windows + R -> eventvwr -> Windows Logs -> Application
```