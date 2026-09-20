<#
.SYNOPSIS
    Adds (or removes) the pkgmngr source line in your PowerShell $PROFILE.
.DESCRIPTION
    Usage:
        .\setup.ps1            # add `. <repo>\pkg.ps1` to the current user profile
        .\setup.ps1 -Remove    # remove any existing pkgmngr source line
#>
[CmdletBinding()]
param(
    [switch]$Remove
)

$sourceLine = ". '$(Join-Path $PSScriptRoot 'pkg.ps1')'"

# CurrentUserCurrentHost profile, falling back to CurrentUserAllHosts
$profilePath = $PROFILE.CurrentUserCurrentHost
if (-not (Test-Path $profilePath)) {
    $alt = $PROFILE.CurrentUserAllHosts
    if (Test-Path $alt) { $profilePath = $alt }
}

if (-not (Test-Path $profilePath)) {
    New-Item -Path $profilePath -ItemType File -Force | Out-Null
}

$lines = @(Get-Content $profilePath -ErrorAction SilentlyContinue)
$existing = @($lines | Where-Object { $_ -match 'pkgmngr\\pkg\.ps1' })

if ($Remove) {
    if ($existing.Count -eq 0) {
        Write-Host "[-] No pkgmngr entry found in $profilePath" -ForegroundColor DarkGray
        return
    }
    $kept = $lines | Where-Object { $_ -notmatch 'pkgmngr\\pkg\.ps1' }
    Set-Content -Path $profilePath -Value $kept -Encoding utf8
    Write-Host "[+] Removed pkgmngr from $profilePath" -ForegroundColor Green
    return
}

if ($existing -contains $sourceLine) {
    Write-Host "[=] pkgmngr is already sourced in $profilePath" -ForegroundColor DarkGray
    return
}

if ($existing.Count -gt 0) {
    # Stale entry (moved repo?) - replace it
    $lines = $lines | Where-Object { $_ -notmatch 'pkgmngr\\pkg\.ps1' }
    Write-Host "[~] Replaced previous pkgmngr entry" -ForegroundColor DarkYellow
}

$lines += ""
$lines += "# pkgmngr - unified Scoop + Winget package manager"
$lines += $sourceLine
Set-Content -Path $profilePath -Value $lines -Encoding utf8

Write-Host "[+] Added to $profilePath :" -ForegroundColor Green
Write-Host "    $sourceLine" -ForegroundColor Cyan
Write-Host ""
Write-Host "Restart PowerShell (or run the line above) and type: pkg" -ForegroundColor DarkGray
