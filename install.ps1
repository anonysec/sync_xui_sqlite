# WinNet XUI Sync - Windows Installer & Manager
# ============================================

param(
    [string]$Action = "install"
)

# Colors for output
$RED = "Red"
$GREEN = "Green"
$YELLOW = "Yellow"
$BLUE = "Blue"
$CYAN = "Cyan"
$MAGENTA = "Magenta"
$WHITE = "White"

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$INSTALL_DIR = "$env:ProgramFiles\WinNet"
$SCRIPT_PATH = "$INSTALL_DIR\sync_xui_sqlite.py"
$SERVICE_NAME = "WinNetXUISync"
$TUNNEL_SCRIPT_PATH = "$INSTALL_DIR\sync_inbound_tunnel.py"
$TUNNEL_SERVICE_NAME = "WinNetTunnelSync"
$VENV_PATH = "$INSTALL_DIR\venv"

function Write-Colored {
    param([string]$Text, [string]$Color = "White")
    Write-Host $Text -ForegroundColor $Color
}

function Write-Banner {
    Clear-Host
    Write-Colored "========================================" $CYAN
    Write-Colored "    WinNet XUI Sync Manager" $CYAN
    Write-Colored "    Subscription Sync Tool" $CYAN
    Write-Colored "========================================" $CYAN
}

function Write-Status { Write-Colored "[OK] $args" $GREEN }
function Write-Error { Write-Colored "[ERROR] $args" $RED }
function Write-Info { Write-Colored "[i] $args" $BLUE }
function Write-Warn { Write-Colored "[!] $args" $YELLOW }

function Check-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "Please run as Administrator"
        exit 1
    }
}

function Get-ServiceStatus {
    param([string]$ServiceName)
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service) {
        if ($service.Status -eq "Running") {
            return "Active"
        } elseif ($service.StartType -eq "Automatic") {
            return "Inactive (Auto)"
        } else {
            return "Stopped"
        }
    } else {
        return "Not Installed"
    }
}

function Check-Python {
    Write-Info "Checking for Python..."
    try {
        $pythonVersion = python --version 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Status "Python found: $pythonVersion"
            return $true
        }
    } catch {}

    Write-Error "Python not found. Please install Python 3.12 or later from https://www.python.org/downloads/"
    Write-Info "After installing, run this installer again."
    return $false
}

function Create-VirtualEnv {
    Write-Info "Creating virtual environment..."
    if (Test-Path $VENV_PATH) {
        Remove-Item -Recurse -Force $VENV_PATH
    }
    python -m venv $VENV_PATH
    Write-Status "Virtual environment created"
}

function Install-Dependencies {
    Write-Info "Installing dependencies..."
    & "$VENV_PATH\Scripts\python.exe" -m pip install --upgrade pip requests
    Write-Status "Dependencies installed"
}

function Copy-Scripts {
    Write-Info "Copying scripts from local folder..."
    New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null

    Copy-Item "$SCRIPT_DIR\sync_xui_sqlite.py" $SCRIPT_PATH
    Copy-Item "$SCRIPT_DIR\sync_inbound_tunnel.py" $TUNNEL_SCRIPT_PATH

    Write-Status "Scripts copied"
}

function Create-ConsoleScripts {
    Write-Info "Creating console scripts..."
    
    $syncBatch = @"
@echo off
"$VENV_PATH\Scripts\python.exe" "$SCRIPT_PATH" %*
"@
    Set-Content -Path "$INSTALL_DIR\run_sync.bat" -Value $syncBatch

    $tunnelBatch = @"
@echo off
"$VENV_PATH\Scripts\python.exe" "$TUNNEL_SCRIPT_PATH" %*
"@
    Set-Content -Path "$INSTALL_DIR\run_tunnel.bat" -Value $tunnelBatch

    Write-Status "Console scripts created"
}

function Install-All {
    Check-Admin
    Write-Banner

    if (-not (Check-Python)) { exit 1 }
    Create-VirtualEnv
    Install-Dependencies
    Copy-Scripts

    Create-ConsoleScripts

    Write-Colored "Installation completed successfully!" $GREEN
    Write-Colored "Run the scripts manually from $INSTALL_DIR" $CYAN
}

function Show-Menu {
    Write-Banner
    Write-Host "  Client Sync:     $(Get-ServiceStatus $SERVICE_NAME)" -ForegroundColor White
    Write-Host "  Tunnel Sync:     $(Get-ServiceStatus $TUNNEL_SERVICE_NAME)" -ForegroundColor White
    Write-Host ""
    Write-Host "  ----- Client Subscription Sync -----" -ForegroundColor White
    Write-Host ""
    Write-Host "  1) Enable Client Sync" -ForegroundColor Green
    Write-Host "  2) Disable Client Sync" -ForegroundColor Red
    Write-Host "  3) Update Client Sync Script" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  ----- Tunnel Inbound Sync ----------" -ForegroundColor White
    Write-Host ""
    Write-Host "  4) Enable Tunnel Sync" -ForegroundColor Green
    Write-Host "  5) Disable Tunnel Sync" -ForegroundColor Red
    Write-Host "  6) Update Tunnel Sync Script" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  ------------------------------------" -ForegroundColor White
    Write-Host ""
    Write-Host "  7) Update All" -ForegroundColor Blue
    Write-Host "  8) Uninstall Everything" -ForegroundColor Yellow
    Write-Host "  0) Exit" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  ------------------------------------" -ForegroundColor White
    Write-Host ""
}

function Enable-ClientSync {
    Write-Info "Enabling client sync service..."
    Start-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
    Set-Service -Name $SERVICE_NAME -StartupType Automatic
    if ((Get-Service -Name $SERVICE_NAME).Status -eq "Running") {
        Write-Status "Client sync service enabled and started."
    } else {
        Write-Error "Failed to start client sync service."
    }
    Read-Host "Press Enter to continue"
}

function Disable-ClientSync {
    Write-Info "Disabling client sync service..."
    Stop-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
    Set-Service -Name $SERVICE_NAME -StartupType Manual
    Write-Status "Client sync service disabled."
    Read-Host "Press Enter to continue"
}

function Update-ClientSync {
    Write-Info "Updating client sync from GitHub..."
    Stop-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri "$GITHUB_RAW/sync_xui_sqlite.py" -OutFile $SCRIPT_PATH
    Write-Status "Client sync script updated."
    Start-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
    Write-Status "Client sync service restarted."
    Read-Host "Press Enter to continue"
}

function Enable-TunnelSync {
    if (-not (Test-Path $TUNNEL_SCRIPT_PATH)) {
        Write-Info "Tunnel sync not installed. Downloading..."
        Invoke-WebRequest -Uri "$GITHUB_RAW/sync_inbound_tunnel.py" -OutFile $TUNNEL_SCRIPT_PATH
        Create-Service -ServiceName $TUNNEL_SERVICE_NAME -ScriptPath $TUNNEL_SCRIPT_PATH -DisplayName "WinNet Tunnel Sync" -Description "Sync X-UI tunnel inbound traffic"
    }
    Write-Info "Enabling tunnel sync service..."
    Start-Service -Name $TUNNEL_SERVICE_NAME -ErrorAction SilentlyContinue
    Set-Service -Name $TUNNEL_SERVICE_NAME -StartupType Automatic
    if ((Get-Service -Name $TUNNEL_SERVICE_NAME).Status -eq "Running") {
        Write-Status "Tunnel sync service enabled and started."
    } else {
        Write-Error "Failed to start tunnel sync service."
    }
    Read-Host "Press Enter to continue"
}

function Disable-TunnelSync {
    Write-Info "Disabling tunnel sync service..."
    Stop-Service -Name $TUNNEL_SERVICE_NAME -ErrorAction SilentlyContinue
    Set-Service -Name $TUNNEL_SERVICE_NAME -StartupType Manual
    Write-Status "Tunnel sync service disabled."
    Read-Host "Press Enter to continue"
}

function Update-TunnelSync {
    Write-Info "Updating tunnel sync from GitHub..."
    Stop-Service -Name $TUNNEL_SERVICE_NAME -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri "$GITHUB_RAW/sync_inbound_tunnel.py" -OutFile $TUNNEL_SCRIPT_PATH
    Write-Status "Tunnel sync script updated."
    Start-Service -Name $TUNNEL_SERVICE_NAME -ErrorAction SilentlyContinue
    Write-Status "Tunnel sync service restarted."
    Read-Host "Press Enter to continue"
}

function Update-All {
    Update-ClientSync
    Update-TunnelSync
    Write-Colored "All updates completed!" $GREEN
    Read-Host "Press Enter to continue"
}

function Uninstall-All {
    Write-Warn "This will remove all WinNet components. Continue? (y/N)"
    $confirm = Read-Host
    if ($confirm -eq "y" -or $confirm -eq "Y") {
        Stop-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
        Stop-Service -Name $TUNNEL_SERVICE_NAME -ErrorAction SilentlyContinue
        & $NSSM_PATH remove $SERVICE_NAME confirm
        & $NSSM_PATH remove $TUNNEL_SERVICE_NAME confirm
        Remove-Item -Recurse -Force $INSTALL_DIR -ErrorAction SilentlyContinue
        Write-Status "WinNet uninstalled successfully."
    }
    Read-Host "Press Enter to continue"
}

# Main execution
switch ($Action) {
    "install" { Install-All }
    "menu" {
        do {
            Show-Menu
            $choice = Read-Host "Enter your choice"
            switch ($choice) {
                1 { Enable-ClientSync }
                2 { Disable-ClientSync }
                3 { Update-ClientSync }
                4 { Enable-TunnelSync }
                5 { Disable-TunnelSync }
                6 { Update-TunnelSync }
                7 { Update-All }
                8 { Uninstall-All }
                0 { break }
                default { Write-Warn "Invalid choice. Please try again." }
            }
        } while ($choice -ne "0")
    }
    default { Write-Error "Invalid action. Use 'install' or 'menu'" }
}