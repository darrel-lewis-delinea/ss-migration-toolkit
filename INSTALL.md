# Secret Server Migration Toolkit - Installation Guide

## Prerequisites

### PowerShell 7+ (Required)

This toolkit requires PowerShell 7 or later for cross-platform compatibility and modern features.

#### Windows

**Option 1: MSI Installer (Recommended)**
```powershell
# Download and install from Microsoft
winget install Microsoft.PowerShell
```

**Option 2: Manual Download**
1. Go to: https://github.com/PowerShell/PowerShell/releases/latest
2. Download `PowerShell-7.x.x-win-x64.msi`
3. Run the installer

**Verify Installation:**
```powershell
pwsh --version
# Should show: PowerShell 7.x.x
```

#### macOS

**Option 1: Homebrew (Recommended)**
```bash
brew install powershell/tap/powershell
```

**Option 2: Direct Download**
1. Go to: https://github.com/PowerShell/PowerShell/releases/latest
2. Download `powershell-7.x.x-osx-x64.pkg`
3. Run the installer

**Verify Installation:**
```bash
pwsh --version
```

#### Linux (Ubuntu/Debian)

```bash
# Install prerequisites
sudo apt-get update
sudo apt-get install -y wget apt-transport-https software-properties-common

# Download and register Microsoft repository
wget -q "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb"
sudo dpkg -i packages-microsoft-prod.deb

# Install PowerShell
sudo apt-get update
sudo apt-get install -y powershell

# Verify
pwsh --version
```

#### Linux (RHEL/CentOS)

```bash
# Register Microsoft repository
curl https://packages.microsoft.com/config/rhel/8/prod.repo | sudo tee /etc/yum.repos.d/microsoft.repo

# Install PowerShell
sudo dnf install -y powershell

# Verify
pwsh --version
```

---

## Secret Server Requirements

### API Access

Both source and target Secret Server instances must have:

1. **Web Services Enabled**
   - Admin > Configuration > General > Enable Webservices = Yes

2. **API User Account**
   - Create a dedicated service account for migration
   - Or use your admin credentials (less secure)

### Required Permissions

**On Source (read-only needed):**
- View Secrets
- List Secrets in folders being migrated
- (Full Migration mode) View Folders, View Secret Policies

**On Target (write needed):**

*Secrets Only Mode:*
- Create Secrets
- View Secret Templates
- Access to target folders

*Full Migration Mode (additional):*
- Create Folders
- Create Secret Policies
- Edit Folders (for policy assignment)

### TLS Requirements

Secret Server Cloud requires TLS 1.2 or 1.3. The script handles this automatically, but ensure your system supports modern TLS.

---

## Installation Steps

### 1. Extract the Toolkit

```bash
# Extract to your preferred location
unzip ss-migration-toolkit.zip -d ~/ss-migration
cd ~/ss-migration
```

### 2. Verify PowerShell

```powershell
# Start PowerShell 7
pwsh

# Verify version (must be 7+)
$PSVersionTable.PSVersion
```

### 3. Set Execution Policy (Windows Only)

```powershell
# Allow script execution (run as Administrator)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 4. Test the Script

```powershell
# Show help
./ss-migrate.ps1 -Help

# You should see the banner and help text
```

---

## Network Requirements

Ensure the machine running the script can reach:

| Endpoint | Port | Purpose |
|----------|------|---------|
| Source Secret Server URL | 443 | Export secrets |
| Target Secret Server URL | 443 | Import secrets |

If using a proxy, set environment variables:
```powershell
$env:HTTPS_PROXY = "http://proxy.company.com:8080"
```

---

## Troubleshooting Installation

### "PowerShell 7 required" Error

You're running Windows PowerShell (5.1) instead of PowerShell 7:
```powershell
# Wrong - this is Windows PowerShell
powershell ./ss-migrate.ps1

# Correct - use pwsh
pwsh ./ss-migrate.ps1
```

### "Execution Policy" Error (Windows)

```powershell
# Run as Administrator
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
```

### TLS Errors

If you see certificate or TLS errors:
```powershell
# Check TLS version
[Net.ServicePointManager]::SecurityProtocol

# Should include Tls12 or Tls13
```

### Connection Timeout

If connections timeout:
1. Verify URLs are correct and reachable
2. Check firewall/proxy settings
3. Try accessing the Secret Server web UI from the same machine

---

## Quick Start

Once installed, run:

```powershell
pwsh ./ss-migrate.ps1
```

The interactive wizard will guide you through the rest.

See `README.md` for full usage documentation.
