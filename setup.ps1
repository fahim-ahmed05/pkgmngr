<#
.SYNOPSIS
    Installs pkgmngr and everything it needs.
.DESCRIPTION
    The one setup script. It asks where to install, checks each dependency,
    offers to install the missing ones through Scoop or Winget - whichever this
    machine actually has - then copies pkgmngr in and wires the source line into
    $PROFILE.

    Nothing is copied until every dependency question has been answered, so
    declining one leaves the machine untouched. Any directory or profile change
    the script already made is removed again on the way out; tools you agreed to
    install are left in place and listed so you can remove them yourself.

    Usage:
        pwsh -File setup.ps1                          # guided install
        pwsh -File setup.ps1 -InstallDir <path> -Yes   # no prompts, defaults
        pwsh -File setup.ps1 -Remove                  # undo an install
#>
[CmdletBinding()]
param(
    # Where pkgmngr is copied to. Asked for when omitted.
    [string]$InstallDir,

    # Profile file to wire up. Only needed for unusual layouts or testing.
    [string]$ProfilePath = $PROFILE.CurrentUserCurrentHost,

    # Remove the source line and the installed copy.
    [switch]$Remove,

    # Answer every question with its default; nothing is installed that the
    # defaults do not cover.
    [switch]$Yes
)

$SourceRoot = $PSScriptRoot
$DefaultDir = Join-Path $env:USERPROFILE '.local\bin\pkgmngr'

# The source line carries its own signature, so recognition cannot depend on what
# the install folder happens to be called. The second branch is for a hand-written
# `. <path>\pkgmngr\pkg.ps1` line, which older versions of this script produced.
$Signature = '# pkgmngr (added by setup.ps1)'
$Marker = '# pkgmngr \(added by setup\.ps1\)|pkgmngr\\pkg\.ps1'''

# fzf and python are load-bearing; gum only prettier output, so it stays optional.
# Ids verified against the Winget and Scoop indexes.
$script:Tools = @(
    @{ Name = 'fzf';    Required = $true;  Scoop = 'fzf';    Winget = 'junegunn.fzf' }
    @{ Name = 'python'; Required = $true;  Scoop = 'python'; Winget = 'Python.Python.3.13' }
    @{ Name = 'gum';    Required = $false; Scoop = 'gum';    Winget = 'charmbracelet.gum' }
)

# What this run created, so an abort can take it back
$script:CreatedDir = $null
$script:CreatedProfile = $false
$script:ProfileBackup = $null

function Write-Head {
    param([string]$Text)
    Write-Host ""
    Write-Host $Text -ForegroundColor Cyan
}

function Write-Done { param([string]$Text) Write-Host "  [+] $Text" -ForegroundColor Green }
function Write-Skip { param([string]$Text) Write-Host "  [!] $Text" -ForegroundColor DarkYellow }
function Write-Bad  { param([string]$Text) Write-Host "  [-] $Text" -ForegroundColor Red }

function Test-Tool {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# A version flag is the cheapest proof that the name in PATH is the real tool.
$VersionArgs = @{
    fzf    = @('--version')
    python = @('--version')
    gum    = @('-v')
}

function Test-ToolWorking {
    <#
    Presence is not enough on Windows: 'python' and 'winget' resolve to store stubs
    that launch the Microsoft Store and exit without running anything, so the
    tool has to actually answer.
    #>
    param([string]$Name)
    if (-not (Test-Tool $Name)) { return $false }
    try {
        & $Name @($VersionArgs[$Name]) *> $null
    } catch {
        return $false
    }
    return ($LASTEXITCODE -eq 0)
}

function Confirm-Choice {
    <# Yes/no question. With -Yes the default is taken without asking. #>
    param(
        [string]$Question,
        [bool]$Default = $true
    )
    if ($Yes) { return $Default }
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $answer = Read-Host "$Question [$hint]"
    if (-not $answer) { return $Default }
    return $answer -match '^[Yy]'
}

function Update-SessionPath {
    <# Picks up shims a manager just added to the user or machine PATH. #>
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $env:Path = @($machine, $user) -join ';'
}

function Install-Package {
    <# Installs one package through the chosen manager. Returns $true on success. #>
    param(
        [string]$Manager,
        [string]$Package,
        [string]$Label
    )
    Write-Host "  installing $Label via $Manager ..." -ForegroundColor DarkGray
    $global:LASTEXITCODE = 0
    try {
        if ($Manager -eq 'scoop') {
            scoop install $Package
        } else {
            winget install -e --id $Package --accept-package-agreements --accept-source-agreements
        }
    } catch {
        Write-Bad "$Label could not be installed: $($_.Exception.Message)"
        return $false
    }
    if ($global:LASTEXITCODE -ne 0) {
        Write-Bad "$Label failed with exit code $global:LASTEXITCODE"
        return $false
    }
    Update-SessionPath
    Write-Done "$Label installed"
    return $true
}

function Install-Scoop {
    <#
    Runs the official Scoop installer for the current user.
    Its installer requires scripts to run for the current user, which is also what
    sourcing pkg from $PROFILE needs; RemoteSigned is Scoop's own documented setting.
    #>
    if (-not (Confirm-Choice "Install Scoop (uses the official get.scoop.sh installer)?" $true)) {
        return $false
    }
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    try {
        Invoke-RestMethod 'https://get.scoop.sh' | Invoke-Expression
    } catch {
        Write-Bad "Scoop installer failed: $($_.Exception.Message)"
    }
    Update-SessionPath
    return (Test-Tool 'scoop')
}

function Select-ToolManager {
    <# Which manager installs the supporting tools. Scoop when present. #>
    param([string[]]$Available)

    if ($Available.Count -eq 0) { return $null }
    if ($Available.Count -eq 1) { return $Available[0] }
    if ($Yes) { return 'scoop' }

    Write-Host "  Both Scoop and Winget are available - install the tools from:"
    Write-Host "    1) Scoop  (default)"
    Write-Host "    2) Winget"
    $answer = Read-Host "  Choice"
    return $(if ($answer -match '^2') { 'winget' } else { 'scoop' })
}

function Undo-Everything {
    <# Takes back what this run created. Installed tools are left alone. #>
    $touched = $false

    if ($script:CreatedDir -and (Test-Path -LiteralPath $script:CreatedDir)) {
        Remove-Item -LiteralPath $script:CreatedDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Done "removed $($script:CreatedDir)"
        $touched = $true
    }
    if ($script:CreatedProfile -and (Test-Path -LiteralPath $ProfilePath)) {
        Remove-Item -LiteralPath $ProfilePath -Force
        Write-Done "removed the profile file it created"
        $touched = $true
    } elseif ($script:ProfileBackup.Count -gt 0 -and (Test-Path -LiteralPath $ProfilePath)) {
        Write-ProfileLines -Lines $script:ProfileBackup
        Write-Done "restored $ProfilePath"
        $touched = $true
    }
    if (-not $touched) {
        Write-Host "  [=] nothing was created, nothing to remove" -ForegroundColor DarkGray
    }
}

function Stop-Setup {
    <# Rolls back, explains, and ends with a failing exit code. #>
    param([string]$Reason, [string[]]$Remaining = @())

    Write-Head 'Setup cancelled'
    Write-Bad $Reason
    Undo-Everything

    if ($Remaining.Count) {
        Write-Host ""
        Write-Host "Left installed (pkgmngr itself was not):" -ForegroundColor DarkYellow
        $Remaining | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    Write-Host ""
    Write-Host "Run setup.ps1 again whenever you are ready to continue." -ForegroundColor DarkGray
    exit 1
}

function Copy-Pkgmngr {
    <# Copies the distributable files into the install directory. #>
    param([string]$Destination)

    $items = 'pkg.ps1', 'setup.ps1', 'README.md', '.gitignore', 'lib', 'scripts'
    foreach ($item in $items) {
        $from = Join-Path $SourceRoot $item
        if (-not (Test-Path -LiteralPath $from)) { continue }
        Copy-Item -LiteralPath $from -Destination $Destination -Recurse -Force
    }
    # Helper-script bytecode and the local index are not installation material
    foreach ($stray in 'scripts\__pycache__', '__pycache__', 'cache') {
        $path = Join-Path $Destination $stray
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

function Write-ProfileLines {
    <# Set-Content refuses an empty array, which is what a profile holding only
       pkgmngr lines becomes once those lines are removed. #>
    param([string[]]$Lines)
    if ($Lines.Count -eq 0) {
        Set-Content -LiteralPath $ProfilePath -Value '' -Encoding utf8
    } else {
        Set-Content -LiteralPath $ProfilePath -Value $Lines -Encoding utf8
    }
}

function Set-ProfileSource {
    <# Points exactly one pkgmngr source line at $Target. #>
    param([string]$Target)

    $sourceLine = ". '$Target'  $Signature"
    $dir = Split-Path -Parent $ProfilePath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        New-Item -Path $ProfilePath -ItemType File -Force | Out-Null
        $script:CreatedProfile = $true
        $script:ProfileBackup = @()
    } else {
        $script:ProfileBackup = @(Get-Content -LiteralPath $ProfilePath -ErrorAction SilentlyContinue)
    }

    # Drop any earlier entry (this script's or a hand-written one) before appending
    $lines = @($script:ProfileBackup |
        Where-Object { $_ -notmatch $Marker -and $_ -notmatch '^# pkgmngr - unified' })
    $lines += ''
    $lines += $sourceLine
    Write-ProfileLines -Lines $lines
    Write-Done "sourced from $ProfilePath"
    Write-Host "      $sourceLine" -ForegroundColor DarkGray
}

function Remove-Pkgmngr {
    <# The -Remove path: undo the profile line and delete the installed copy. #>
    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        Write-Host "[-] No profile at $ProfilePath - nothing wired up here." -ForegroundColor DarkGray
        exit 0
    }

    $lines = @(Get-Content -LiteralPath $ProfilePath -ErrorAction SilentlyContinue)
    $entries = @($lines | Where-Object { $_ -match $Marker })

    if ($entries.Count -eq 0) {
        Write-Host "[-] No pkgmngr entry found in $ProfilePath" -ForegroundColor DarkGray
        Write-Host "    If you source a clone directly, delete that line and the clone." -ForegroundColor DarkGray
        exit 0
    }

    # Read the install path out of the line before the line is gone
    $copies = @($entries | ForEach-Object {
        if ($_ -match "'([^']+)'\s*(#|$)") { Split-Path -Parent $Matches[1] }
    })

    $kept = @($lines | Where-Object { $_ -notmatch $Marker -and $_ -notmatch '^# pkgmngr - unified' })
    Write-ProfileLines -Lines $kept
    Write-Done "removed the source line from $ProfilePath"

    foreach ($copy in $copies) {
        if (-not $copy) { continue }
        if ($copy -ieq $SourceRoot) {
            Write-Host "  [=] $copy is this checkout - left in place (it is a git clone)." -ForegroundColor DarkGray
            continue
        }
        if (Test-Path -LiteralPath $copy) {
            Remove-Item -LiteralPath $copy -Recurse -Force
            Write-Done "deleted $copy"
        }
    }
    exit 0
}

function Resolve-InstallDir {
    <# Asks for the destination unless given, expands it, returns $null to abort. #>
    $chosen = $InstallDir
    if (-not $chosen) {
        if ($Yes) {
            $chosen = $DefaultDir
        } else {
            Write-Host "  Where should pkgmngr be installed?"
            $entered = Read-Host "  Path [$DefaultDir]"
            $chosen = if ($entered.Trim()) { $entered } else { $DefaultDir }
        }
    }

    $chosen = [Environment]::ExpandEnvironmentVariables($chosen.Trim().Trim('"'))
    try {
        $chosen = [IO.Path]::GetFullPath($chosen)
    } catch {
        Write-Bad "That is not a usable path: $chosen"
        return $null
    }

    if (Test-Path -LiteralPath $chosen) {
        $existing = @(Get-ChildItem -LiteralPath $chosen -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 0 -and -not (Confirm-Choice "$chosen is not empty - install into it anyway?" $true)) {
            return $null
        }
    } elseif (-not (Confirm-Choice "Create ${chosen}?" $true)) {
        return $null
    }

    return $chosen
}

# ---------------------------------------------------------------------------

if ($Remove) { Remove-Pkgmngr }

Write-Head 'pkgmngr setup'
Write-Host "  source: $SourceRoot" -ForegroundColor DarkGray

# 1. PowerShell 7 - pkg is written against it, so this is a hard requirement.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        Write-Host "  This shell is PowerShell $($PSVersionTable.PSVersion); relaunching under pwsh ..." -ForegroundColor DarkYellow
        & pwsh -NoProfile -File $PSCommandPath @PSBoundParameters
        exit $LASTEXITCODE
    }
    if (-not (Confirm-Choice "PowerShell 7 is required but not found. Install it now?" $true)) {
        Stop-Setup 'PowerShell 7 is required to run pkg.'
    }
    $bootstrapper = if (Test-Tool 'scoop') { 'scoop' } elseif (Test-Tool 'winget') { 'winget' } else { $null }
    if (-not $bootstrapper) {
        Stop-Setup 'PowerShell 7 is required, and installing it needs Scoop or Winget - install one and re-run.'
    }
    if (-not (Install-Package -Manager $bootstrapper -Package $(if ($bootstrapper -eq 'scoop') { 'pwsh' } else { 'Microsoft.PowerShell' }) -Label 'PowerShell 7')) {
        Stop-Setup 'Could not install PowerShell 7.'
    }
    Stop-Setup "PowerShell 7 is installed. Re-run 'pwsh -File setup.ps1' to finish."
}
Write-Done "PowerShell $($PSVersionTable.PSVersion)"

# 2. Scoop - offered first because the catalog is richer, but never assumed.
$hasScoop = Test-Tool 'scoop'
if (-not $hasScoop) {
    Write-Skip 'Scoop is not installed.'
    $hasScoop = Install-Scoop
    if ($hasScoop) { Write-Done 'Scoop installed' } else { Write-Skip 'Continuing without Scoop.' }
} else {
    Write-Done 'Scoop found'
}

$hasWinget = Test-Tool 'winget'
if ($hasWinget) { Write-Done 'Winget found' } else { Write-Skip 'Winget is not available.' }

if (-not $hasScoop -and -not $hasWinget) {
    Stop-Setup 'pkg needs at least one package manager (Scoop or Winget) to install anything.'
}

# 3. Supporting tools
$missing = @($script:Tools | Where-Object { -not (Test-ToolWorking $_.Name) })
foreach ($tool in @($missing | Where-Object { Test-Tool $_.Name })) {
    # Found on PATH but it does not run - the store alias case
    Write-Skip "$($tool.Name) is on PATH but does not run (Windows store alias?) - reinstalling it."
}
if ($missing.Count -eq 0) {
    Write-Done "fzf, python and gum already present"
} else {
    $available = @()
    if ($hasScoop) { $available += 'scoop' }
    if ($hasWinget) { $available += 'winget' }
    $toolManager = Select-ToolManager -Available $available
    Write-Host "  Missing: $($missing.Name -join ', ') - installing via $toolManager" -ForegroundColor DarkGray

    foreach ($tool in $missing) {
        $label = if ($tool.Required) { "$($tool.Name) (required)" } else { "$($tool.Name) (optional, nicer output)" }
        if (-not (Confirm-Choice "Install ${label}?" $true)) {
            if ($tool.Required) {
                Stop-Setup "$($tool.Name) is required for pkg to search and display packages."
            }
            Write-Skip "$($tool.Name) skipped - pkg will fall back to plain output."
            continue
        }
        if (-not (Install-Package -Manager $toolManager -Package $tool.$toolManager -Label $tool.Name)) {
            if ($tool.Required) {
                Stop-Setup "$($tool.Name) is required but could not be installed."
            }
            Write-Skip "$($tool.Name) skipped."
        }
    }
}

# 4. Destination, then the copy - after this point a failure must roll back
$target = Resolve-InstallDir
if (-not $target) {
    Stop-Setup 'No install location chosen.'
}

$samePlace = [string]::Equals($target, [IO.Path]::GetFullPath($SourceRoot),
    [StringComparison]::OrdinalIgnoreCase)

Write-Head "Installing to $target"
if ($samePlace) {
    Write-Skip 'source and destination are the same - using this checkout in place'
} else {
    if (-not (Test-Path -LiteralPath $target)) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $script:CreatedDir = $target
    }
    try {
        Copy-Pkgmngr -Destination $target
    } catch {
        Stop-Setup "Copy failed: $($_.Exception.Message)"
    }
    Write-Done 'files copied'
}

# 5. Profile wiring
Write-Head 'PowerShell profile'
Set-ProfileSource -Target (Join-Path $target 'pkg.ps1')

Write-Head 'Done'
Write-Host "  Restart PowerShell (or run:  . '$(Join-Path $target 'pkg.ps1')')" -ForegroundColor Cyan
Write-Host "  Then type:  pkg" -ForegroundColor Cyan
Write-Host ""
Write-Host "  To update later:  git -C $SourceRoot pull; then re-run this script." -ForegroundColor DarkGray
exit 0
