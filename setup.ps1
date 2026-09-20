<#
.SYNOPSIS
    Installs pkgmngr and everything it needs.
.DESCRIPTION
    The one setup script, in strict order: PowerShell 7, then git, then the clone,
    then the tools pkg runs on. Each step is checked before the next one touches
    the disk, and nothing is cloned until the dependency questions in front of it
    have been answered. Anything this run created is removed again if it is
    cancelled partway through.

    The clone is the installation. $PROFILE is pointed straight at
    <clone>\pkg.ps1, so there is no second copy of the files to keep in sync and
    'git pull' in that folder is the update path.

    A dependency that is already in place is passed over without a question - not
    even the choice of manager, which only comes up once something actually has to be
    installed. That choice defaults to Winget, because every Windows installation
    ships with it; Scoop is offered alongside it, and is used on its own where it is
    the only manager present or where -Manager asked for it by name.

    Usage:
        pwsh -File setup.ps1                     # guided install
        pwsh -File setup.ps1 -CloneDir <path>    # clone somewhere specific
        pwsh -File setup.ps1 -Manager scoop      # install packages through Scoop
        pwsh -File setup.ps1 -Yes                # no prompts, defaults throughout
        pwsh -File setup.ps1 -Remove             # undo an install
.NOTES
    Run it as a file - 'iwr ... | iex' is not supported, because the script ends
    with an exit code and 'exit' would close your shell. From a clone, running
    setup.ps1 again refreshes the profile line and checks the dependencies.
#>
[CmdletBinding()]
param(
    # Where the repository is cloned. Asked for when omitted.
    [string]$CloneDir,

    # Repository to clone. A local path is accepted, which keeps this testable offline.
    [string]$RepoUrl = 'https://github.com/fahim-ahmed05/pkgmngr',

    # Which manager installs packages. 'ask' means Winget unless Scoop is the only one
    # here, and asks which to use when both are installed - but only once something
    # actually has to be installed. Naming a manager here answers that in advance.
    [ValidateSet('ask', 'winget', 'scoop')]
    [string]$Manager = 'ask',

    # Profile file to wire up. Only needed for unusual layouts or testing.
    [string]$ProfilePath = $PROFILE.CurrentUserCurrentHost,

    # Remove the source line, and the clone if you agree to.
    [switch]$Remove,

    # Answer every question with its default; nothing is installed that the
    # defaults do not cover.
    [switch]$Yes
)

# Where this copy of setup.ps1 sits. Only used to recognise "you are already
# running from a clone"; the install itself comes from the repository.
$SourceRoot = $PSScriptRoot
$DefaultClone = Join-Path $HOME 'Git\pkgmngr'

# The source line carries its own signature, so recognition cannot depend on what
# the install folder happens to be called. The second branch is for a hand-written
# `. <path>\pkgmngr\pkg.ps1` line, which older versions of this script produced.
$Signature = '# pkgmngr (added by setup.ps1)'
$Marker = '# pkgmngr \(added by setup\.ps1\)|pkgmngr\\pkg\.ps1'''

# fzf and python are load-bearing; gum only prettier output, so it stays optional.
# git is needed one step earlier, to fetch the repository. Ids verified against the
# Winget and Scoop indexes.
$script:Tools = @(
    @{ Name = 'fzf';    Required = $true;  Scoop = 'fzf';    Winget = 'junegunn.fzf' }
    @{ Name = 'python'; Required = $true;  Scoop = 'python'; Winget = 'Python.Python.3.13' }
    @{ Name = 'gum';    Required = $false; Scoop = 'gum';    Winget = 'charmbracelet.gum' }
)
$script:GitTool = @{ Scoop = 'git'; Winget = 'Git.Git' }

# What this run created, so an abort can take it back
$script:CreatedDir = $null
$script:CreatedParents = @()
$script:CreatedProfile = $false
$script:ProfileBackup = $null
$script:ChosenManager = $null
$script:ClonePath = $null

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
    git    = @('--version')
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
    <#
    Installs one package through the chosen manager. Returns $true on success.

    The manager's output is pushed through Out-Host instead of being left on the
    pipeline: scoop and winget write to stdout, so their lines would otherwise
    land in this function's return value, and `if (-not (Install-Package ...))`
    would read a non-empty array as success and never see a failure.
    #>
    param(
        [string]$Manager,
        [string]$Package,
        [string]$Label
    )
    Write-Host "  installing $Label via $Manager ..." -ForegroundColor DarkGray
    $global:LASTEXITCODE = 0
    try {
        if ($Manager -eq 'scoop') {
            scoop install $Package | Out-Host
        } else {
            winget install -e --id $Package --accept-package-agreements --accept-source-agreements | Out-Host
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

function Get-ManagerOptions {
    <# The managers this machine can install with, Winget first. #>
    $found = @()
    if (Test-Tool 'winget') { $found += 'winget' }
    if (Test-Tool 'scoop') { $found += 'scoop' }
    return $found
}

function Install-Scoop {
    <#
    Runs the official Scoop installer for the current user.
    Its installer requires scripts to run for the current user, which is also what
    sourcing pkg from $PROFILE needs; RemoteSigned is Scoop's own documented setting.

    Scoop is an extra manager, so the offer defaults to no - unless there is no
    Winget here, in which case it is the only way anything can be installed.
    #>
    param(
        [bool]$Ask = $true,
        [bool]$Default = $false
    )
    $question = if ($Default) {
        'No package manager is installed. Install Scoop now so this can continue?'
    } else {
        'Scoop is not installed. Add it as well? It is optional - Winget alone is enough.'
    }
    if ($Ask -and -not (Confirm-Choice $question $Default)) {
        return $false
    }
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    try {
        Invoke-RestMethod 'https://get.scoop.sh' | Invoke-Expression | Out-Host
    } catch {
        Write-Bad "Scoop installer failed: $($_.Exception.Message)"
    }
    Update-SessionPath
    return (Test-Tool 'scoop')
}

function Resolve-Manager {
    <#
    Decides which manager installs something, and is only ever called when there is
    something to install - a tool that is already in place raises no question here,
    not even the choice of manager. The answer is cached for the rest of the run, so
    git and the supporting tools are not asked about separately.

    Winget is the default answer because it ships with Windows, and Scoop - optional
    here, since it is a second manager - is offered at this point rather than up
    front. Scoop is used without asking when it is the only manager present or when
    -Manager named it.
    #>
    if ($script:ChosenManager) { return $script:ChosenManager }

    if ($Manager -ne 'ask') {
        if (Test-Tool $Manager) {
            $script:ChosenManager = $Manager
            return $script:ChosenManager
        }
        if ($Manager -ne 'scoop') {
            Write-Bad "Winget was requested with -Manager winget but is not available."
            return $null
        }
        # -Manager scoop is an explicit request, so no yes/no question about it
        Write-Skip 'Scoop was requested with -Manager - installing it now.'
        if (-not (Install-Scoop -Ask:$false)) { return $null }
        $script:ChosenManager = 'scoop'
        return $script:ChosenManager
    }

    # A dependency has to be resolved, so this is where the Scoop question belongs
    if (-not (Test-Tool 'scoop')) {
        # Without Winget there is nothing else that could install anything, so Scoop
        # stops being an optional extra and becomes the recommended answer.
        $onlyOption = -not (Test-Tool 'winget')
        if (Install-Scoop -Ask:(-not $Yes) -Default:$onlyOption) {
            Write-Done 'Scoop installed'
        } elseif ($onlyOption) {
            Write-Bad 'Nothing can be installed without a package manager, and Scoop was declined.'
            return $null
        }
    }

    $options = @(Get-ManagerOptions)
    if ($options.Count -eq 0) { return $null }
    if ($options.Count -eq 1) {
        $script:ChosenManager = $options[0]
        return $script:ChosenManager
    }
    if ($Yes) { $script:ChosenManager = 'winget'; return $script:ChosenManager }

    Write-Host '  Both Winget and Scoop are available - use which for dependency resolution?'
    Write-Host '    1) Winget  (default)'
    Write-Host '    2) Scoop'
    $answer = Read-Host '  Choice'
    $script:ChosenManager = if ($answer -match '^2') { 'scoop' } else { 'winget' }
    return $script:ChosenManager
}

function Resolve-Git {
    <# Step 1: git has to exist before the repository can be fetched. #>
    if (Test-ToolWorking 'git') {
        Write-Done "git found: $((git --version) -join '')"
        return $true
    }
    if (Test-Tool 'git') {
        Write-Skip 'git is on PATH but does not run.'
        if (-not (Confirm-Choice 'Reinstall git anyway?' $true)) { return $false }
    } elseif (-not (Confirm-Choice 'Git is needed to clone pkgmngr but was not found. Install it now?' $true)) {
        return $false
    }

    $chosen = Resolve-Manager
    if (-not $chosen) { return $false }
    return (Install-Package -Manager $chosen -Package $script:GitTool.$chosen -Label 'Git')
}

function Test-PkgClone {
    <# Enough of a pkgmngr checkout to source and run, git metadata or not. #>
    param([string]$Path)
    return (Test-Path -LiteralPath (Join-Path $Path 'pkg.ps1')) -and
           (Test-Path -LiteralPath (Join-Path $Path 'lib'))
}

function Invoke-Git {
    <#
    Runs git and reports failure by exit code. Output goes to Out-Host, which both
    shows the clone progress and keeps this function's return value a clean boolean.
    #>
    param([string]$WorkingDir, [Parameter(Mandatory = $true)][string[]]$Arguments)

    $global:LASTEXITCODE = 0
    try {
        if ($WorkingDir -and (Test-Path -LiteralPath $WorkingDir)) {
            Push-Location -LiteralPath $WorkingDir
            try { git @Arguments | Out-Host } finally { Pop-Location }
        } else {
            git @Arguments | Out-Host
        }
    } catch {
        Write-Bad "git $($Arguments[0]) failed: $($_.Exception.Message)"
        return $false
    }
    if ($global:LASTEXITCODE -ne 0) {
        Write-Bad "git $($Arguments[0]) exited with code $global:LASTEXITCODE"
        return $false
    }
    return $true
}

function Resolve-CloneDir {
    <# Step 2: where the repository lives, or will live. #>
    $chosen = $CloneDir
    if (-not $chosen) {
        if ($SourceRoot -and (Test-PkgClone $SourceRoot)) {
            # Already standing in a checkout: using it is the default, so -Yes takes
            # it too. Otherwise the answer would be a second clone elsewhere.
            if ($Yes) { return $SourceRoot }
            Write-Host "  This script is inside a pkgmngr checkout at $SourceRoot"
            if (Confirm-Choice 'Install from that checkout instead of cloning again?' $true) {
                return $SourceRoot
            }
            $chosen = $DefaultClone
        } elseif ($Yes) {
            $chosen = $DefaultClone
        } else {
            Write-Host '  Where should pkgmngr be cloned?'
            $entered = Read-Host "  Path [$DefaultClone]"
            $chosen = if ($entered.Trim()) { $entered } else { $DefaultClone }
        }
    }

    $chosen = [Environment]::ExpandEnvironmentVariables($chosen.Trim().Trim('"'))
    try {
        return [IO.Path]::GetFullPath($chosen)
    } catch {
        Write-Bad "That is not a usable path: $chosen"
        return $null
    }
}

function Update-Clone {
    <# Fetches the repository, or refreshes a checkout that is already there. #>
    param([string]$Path)

    if (Test-PkgClone $Path) {
        Write-Done "pkgmngr checkout found at $Path"
        if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
            Write-Skip "It is not a git repository, so 'git pull' will not work here."
            return $true
        }
        if (Confirm-Choice "Update it with 'git pull'?" $true) {
            # A failed pull is not fatal: the checkout already on disk still works
            if (Invoke-Git -WorkingDir $Path -Arguments @('pull', '--ff-only')) {
                Write-Done 'clone updated'
            } else {
                Write-Skip 'Keeping the copy already on disk.'
            }
        }
        return $true
    }

    if (Test-Path -LiteralPath $Path) {
        $entries = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
        if ($entries.Count -gt 0) {
            Write-Bad "$Path already exists and is not a pkgmngr checkout."
            $entries | Select-Object -First 5 | ForEach-Object {
                Write-Host "      $($_.Name)" -ForegroundColor DarkGray
            }
            return $false
        }
    } else {
        $parent = Split-Path -Parent $Path
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            $script:CreatedParents += $parent
        }
    }

    Write-Head "Cloning $RepoUrl"
    if (-not (Invoke-Git -WorkingDir (Split-Path -Parent $Path) -Arguments @('clone', '--depth', '1', $RepoUrl, $Path))) {
        return $false
    }
    if (-not (Test-PkgClone $Path)) {
        Write-Bad "The clone at $Path has no pkg.ps1 - wrong repository or a partial checkout?"
        return $false
    }
    # Owned by this run from here on, so an abort can delete it
    $script:CreatedDir = $Path
    Write-Done "cloned into $Path"
    return $true
}

function Undo-Everything {
    <#
    Takes back what this run created: the clone it fetched, any folder it made for
    it, and the profile edit. Tools installed through a package manager are left
    alone - uninstalling those would be a second deletion nobody asked for.
    #>
    $touched = $false

    if ($script:CreatedDir -and (Test-Path -LiteralPath $script:CreatedDir)) {
        # A shell sitting inside the folder would hold it open
        if ($PWD.Path -ieq $script:CreatedDir -or $PWD.Path -like "$($script:CreatedDir)\*") {
            Set-Location $HOME
        }
        Remove-Item -LiteralPath $script:CreatedDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $script:CreatedDir) {
            Write-Bad "could not remove $($script:CreatedDir) - delete it by hand"
        } else {
            Write-Done "removed the clone at $($script:CreatedDir)"
        }
        $touched = $true
    }
    foreach ($parent in $script:CreatedParents) {
        if ((Test-Path -LiteralPath $parent) -and -not @(Get-ChildItem -LiteralPath $parent -Force)) {
            Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
            Write-Done "removed the empty folder $parent"
        }
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
    <#
    The -Remove path: take the source line out of the profile, then offer to delete
    the clone. The clone is the user's own repository and may be the folder this
    very script is running from, so deleting it is always a separate yes.
    #>
    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        Write-Host "[-] No profile at $ProfilePath - nothing wired up here." -ForegroundColor DarkGray
        exit 0
    }

    $lines = @(Get-Content -LiteralPath $ProfilePath -ErrorAction SilentlyContinue)
    $entries = @($lines | Where-Object { $_ -match $Marker })

    if ($entries.Count -eq 0) {
        Write-Host "[-] No pkgmngr entry found in $ProfilePath" -ForegroundColor DarkGray
        Write-Host '    If you source a clone by hand, delete that line and the clone.' -ForegroundColor DarkGray
        exit 0
    }

    # Read the clone path out of the line before the line is gone
    $clones = @($entries | ForEach-Object {
        if ($_ -match "'([^']+)'\s*(#|$)") { Split-Path -Parent $Matches[1] }
    })

    $kept = @($lines | Where-Object { $_ -notmatch $Marker -and $_ -notmatch '^# pkgmngr - unified' })
    Write-ProfileLines -Lines $kept
    Write-Done "removed the source line from $ProfilePath"

    foreach ($clone in @($clones | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $clone)) { continue }
        $note = if ($clone -ieq $SourceRoot) { " It is the folder this script is running from." } else { '' }
        if (-not (Confirm-Choice "Delete ${clone}?$note" $false)) {
            Write-Host "  [=] left in place - update it with 'git pull', or delete the folder by hand" -ForegroundColor DarkGray
            continue
        }
        # A shell sitting inside the folder would hold it open
        if ($PWD.Path -ieq $clone -or $PWD.Path -like "$clone\*") { Set-Location $HOME }
        Remove-Item -LiteralPath $clone -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $clone) {
            Write-Bad "could not delete $clone - close any shell inside it and try again"
        } else {
            Write-Done "deleted $clone"
        }
    }

    Write-Host ''
    Write-Host '  Restart PowerShell for pkg to disappear.' -ForegroundColor Cyan
    exit 0
}

# ---------------------------------------------------------------------------

# Failure is reported through exit codes, and `exit` inside an iex'd script would
# close the caller's shell instead of the setup run.
if (-not $PSCommandPath) {
    Write-Host '[-] Run setup.ps1 from a file, not through "| iex":' -ForegroundColor Red
    Write-Host '      iwr https://raw.githubusercontent.com/fahim-ahmed05/pkgmngr/main/setup.ps1 -OutFile $env:TEMP\pkgmngr-setup.ps1'
    Write-Host '      pwsh -File $env:TEMP\pkgmngr-setup.ps1'
    return
}

if ($Remove) { Remove-Pkgmngr }

Write-Head 'pkgmngr setup'
Write-Host "  run from:   $(if ($SourceRoot) { $SourceRoot } else { 'a downloaded copy of setup.ps1' })" -ForegroundColor DarkGray
Write-Host "  repository: $RepoUrl" -ForegroundColor DarkGray

# --- 1. PowerShell 7: pkg is written against it, and every step below assumes it.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        Write-Host "  This shell is PowerShell $($PSVersionTable.PSVersion); relaunching under pwsh ..." -ForegroundColor DarkYellow
        & pwsh -NoProfile -File $PSCommandPath @PSBoundParameters
        exit $LASTEXITCODE
    }
    if (-not (Confirm-Choice 'PowerShell 7 is required but not found. Install it now?' $true)) {
        Stop-Setup 'PowerShell 7 is required to run pkg.'
    }
    $chosen = Resolve-Manager
    if (-not $chosen) {
        Stop-Setup 'PowerShell 7 is required, and installing it needs Winget or Scoop - install one and re-run.'
    }
    $pwshPackage = if ($chosen -eq 'scoop') { 'pwsh' } else { 'Microsoft.PowerShell' }
    if (-not (Install-Package -Manager $chosen -Package $pwshPackage -Label 'PowerShell 7')) {
        Stop-Setup 'Could not install PowerShell 7.'
    }
    Stop-Setup "PowerShell 7 is installed. Re-run 'pwsh -File setup.ps1' to finish."
}
Write-Done "PowerShell $($PSVersionTable.PSVersion)"

# --- 2. Package managers: reported here, and only asked about further down if
#        something actually has to be installed through one.
$found = @(Get-ManagerOptions)
if ($found -contains 'winget') { Write-Done 'Winget found' } else { Write-Skip 'Winget is not available.' }
if ($found -contains 'scoop') { Write-Done 'Scoop found' } else { Write-Host '  Scoop is not installed - it is offered only if a dependency has to be installed.' -ForegroundColor DarkGray }
if ($found.Count -eq 0) {
    Write-Skip 'No package manager here yet. pkg can be installed, but not used to install anything until Scoop or Winget is added.'
}

# --- 3. Git: needed to fetch the repository, so checked before anything is cloned
if (-not (Resolve-Git)) {
    Stop-Setup 'Git is required to fetch the pkgmngr repository, and it is not installed.'
}

# --- 4. The clone, which is the installation
$clone = Resolve-CloneDir
if (-not $clone) {
    Stop-Setup 'No clone location chosen.'
}
if (-not (Update-Clone -Path $clone)) {
    Stop-Setup "pkgmngr could not be cloned into $clone."
}
$script:ClonePath = $clone

# --- 5. The tools pkg runs on. One that is already in place is left alone entirely:
#        no question about it, and no question about a manager because of it.
$missing = @($script:Tools | Where-Object { -not (Test-ToolWorking $_.Name) })
foreach ($tool in @($missing | Where-Object { Test-Tool $_.Name })) {
    # Found on PATH but it does not run - the store alias case
    Write-Skip "$($tool.Name) is on PATH but does not run (Windows store alias?) - reinstalling it."
}
if ($missing.Count -eq 0) {
    Write-Done 'fzf, python and gum already present - no dependency to resolve'
} else {
    Write-Host "  Missing: $($missing.Name -join ', ')" -ForegroundColor DarkGray

    foreach ($tool in $missing) {
        $label = if ($tool.Required) { "$($tool.Name) (required)" } else { "$($tool.Name) (optional, nicer output)" }
        if (-not (Confirm-Choice "Install ${label}?" $true)) {
            if ($tool.Required) {
                Stop-Setup "$($tool.Name) is required for pkg to search and display packages."
            }
            Write-Skip "$($tool.Name) skipped - pkg will fall back to plain output."
            continue
        }
        # Decided here, after the yes, so declining every tool asks no manager question
        $toolManager = Resolve-Manager
        if (-not $toolManager) {
            if ($tool.Required) {
                Stop-Setup "$($tool.Name) is required, and installing it needs a package manager."
            }
            Write-Skip "$($tool.Name) skipped - there is no package manager to install it with."
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

# --- 6. Profile wiring: point $PROFILE at the clone
Write-Head 'PowerShell profile'
$pkgEntry = Join-Path $clone 'pkg.ps1'
Set-ProfileSource -Target $pkgEntry

Write-Head 'Done'
Write-Host "  Restart PowerShell (or run:  . '$pkgEntry')" -ForegroundColor Cyan
Write-Host '  Then type:  pkg' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Installed at  $clone" -ForegroundColor DarkGray
Write-Host "  Update with   git -C ""$clone"" pull" -ForegroundColor DarkGray
Write-Host "  Undo with     pwsh -File ""$($clone)\setup.ps1"" -Remove" -ForegroundColor DarkGray
exit 0
