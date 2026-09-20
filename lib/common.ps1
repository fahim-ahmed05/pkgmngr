<#
.SYNOPSIS
    Shared UI helpers, dependency checks, and terminal hygiene for pkgmngr.
#>

$script:PkgScripts = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'
$script:PkgHasGum = [bool](Get-Command gum -ErrorAction SilentlyContinue)

# Keep python's piped stdout UTF-8 regardless of console code page (badges/ellipsis in catalog)
$env:PYTHONIOENCODING = 'utf-8'

function Write-PkgCard {
    <#
    .SYNOPSIS
        Renders a bordered status card (gum styled, plain fallback).
    .DESCRIPTION
        Output goes through Out-Host, not the pipeline: gum writes to stdout, so a
        card emitted inside a function whose result is captured would otherwise
        become part of that result (extra lines in a catalog, a truthy array where
        a boolean guard was expected).
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Text,
        [Parameter(Position = 1)]
        [int]$Color = 252,
        [switch]$Bold
    )
    if ($script:PkgHasGum) {
        $styleArgs = @('style', '--border', 'normal', '--border-foreground', $Color, '--padding', '0 2', '--margin', '1 0')
        if ($Bold) { $styleArgs += '--bold' }
        gum @styleArgs -- $Text | Out-Host
    } else {
        Write-Host $Text -ForegroundColor DarkCyan
    }
}

function Write-PkgNote {
    <# Renders a single-line inline note. See Write-PkgCard on Out-Host. #>
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Text,
        [Parameter(Position = 1)]
        [int]$Color = 245
    )
    if ($script:PkgHasGum) {
        gum style --foreground $Color -- $Text | Out-Host
    } else {
        Write-Host $Text
    }
}

function Confirm-Pkg {
    <#
    .SYNOPSIS
        Interactive yes/no prompt. Returns $true when confirmed.
    .DESCRIPTION
        Uses Read-Host rather than `gum confirm`: gum renders its box on stdout,
        and any caller that captures stdout (notably `if (-not (Confirm-Pkg ...))`)
        would test a non-empty array instead of the answer - silently approving
        every confirmation. Read-Host writes nowhere but the host.
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message
    )
    Write-PkgNote "$Message [y/N]" 214
    $answer = Read-Host '  >'
    Clear-PkgInputBuffer
    return $answer -match '^[Yy]'
}

function Center-PkgText {
    <#
    .SYNOPSIS
        Left-pads a line so fzf renders it centered in its popup.
    .DESCRIPTION
        fzf has no header alignment option, so the offset is computed from the
        terminal width. $Visible must be the text with ANSI codes stripped, since
        escape sequences do not occupy screen columns.
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Text,
        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Visible,
        [int]$Width = 0
    )
    if (-not $Width) {
        try { $Width = [int]$Host.UI.RawUI.WindowSize.Width } catch { $Width = 0 }
    }
    if ($Width -lt 1) { return $Text }

    # One column each side for the rounded border
    $pad = [int][Math]::Floor(($Width - 2 - $Visible.Length) / 2)
    if ($pad -gt 0) { (' ' * $pad) + $Text } else { $Text }
}

function Clear-PkgInputBuffer {
    <# Discards unconsumed terminal capability probes (e.g. \e[?2027;0$y) emitted by gum/ultraviolet. #>
    try {
        $Host.UI.RawUI.FlushInputBuffer()
        while ([Console]::KeyAvailable) {
            [void][Console]::ReadKey($true)
        }
    } catch {}
}

function Get-PkgDependency {
    <#
    .SYNOPSIS
        Verifies required external tools; writes a note for each missing one.
    .DESCRIPTION
        Returns $false when blocked. Package managers are not checked here - use
        Test-PkgManager, since a machine with only Scoop or only Winget is still
        fully usable.
    #>
    param([string[]]$Required = @())
    $missing = @($Required | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    foreach ($tool in $missing) {
        Write-PkgNote "[-] Required tool '$tool' not found in PATH - run setup.ps1 to install it." 203
    }
    return ($missing.Count -eq 0)
}

# A version flag is the cheapest proof that a name in PATH is the tool itself and
# not a Windows store alias, which opens the Store and exits without running.
$script:PkgRuntimeProbe = @{
    fzf    = @('--version')
    python = @('--version')
}

function Test-PkgToolWorking {
    <# True only when $Name exists and actually answers its version flag. #>
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { return $false }
    $probe = $script:PkgRuntimeProbe[$Name]
    if ($null -eq $probe) { return $true }
    try { & $Name @($probe) *> $null } catch { return $false }
    return ($LASTEXITCODE -eq 0)
}

function Test-PkgRuntime {
    <#
    .SYNOPSIS
        Entry-point pre-flight for the tools pkg cannot work without.
    .DESCRIPTION
        Names every broken dependency in one message and returns $false so the
        caller can leave before any TUI or package-manager call is made. Nothing
        is installed from here - setup.ps1 owns that decision; this only refuses to
        run half-broken. Not cached on purpose: installing fzf in the same shell
        should work immediately rather than after a restart.
    #>
    param([string]$SetupPath = 'setup.ps1')

    $broken = [System.Collections.Generic.List[string]]::new()
    foreach ($tool in 'fzf', 'python') {
        if (Test-PkgToolWorking $tool) { continue }
        $why = if (Get-Command $tool -ErrorAction SilentlyContinue) {
            "$tool is on PATH but does not run (Windows store alias?)"
        } else {
            "$tool is not installed"
        }
        $broken.Add("  - $why")
    }
    if ($broken.Count -eq 0) { return $true }

    Write-PkgCard "pkg cannot run - missing:`n$($broken -join "`n")" -Color 203 -Bold
    Write-PkgNote "Fix it with:  pwsh -File `"$SetupPath`"" 214
    Write-PkgNote 'Or by hand:   scoop install fzf python   (or the same via winget)' 245
    return $false
}

$script:PkgManagers = $null

function Get-PkgManagers {
    <#
    .SYNOPSIS
        Which package managers are usable here, resolved once per session.
    .DESCRIPTION
        Scoop and Winget are independent: a machine may have either, both, or
        neither, and everything downstream narrows to what is present.
    #>
    if ($null -eq $script:PkgManagers) {
        $found = [System.Collections.Generic.List[string]]::new()
        foreach ($manager in 'winget', 'scoop') {
            if (Get-Command $manager -ErrorAction SilentlyContinue) { $found.Add($manager) }
        }
        $script:PkgManagers = @($found)
    }
    return $script:PkgManagers
}

function Test-PkgManager {
    <# True when the manager is installed. The msstore source is served by winget. #>
    param([Parameter(Mandatory = $true, Position = 0)][string]$Manager)
    $required = if ($Manager -in 'winget', 'msstore') { 'winget' } else { 'scoop' }
    return ($required -in (Get-PkgManagers))
}

function Clear-PkgManagerCache {
    <# Forgets the lookup so a manager installed in this session is picked up. #>
    $script:PkgManagers = $null
}

# Short forms for typed targets, so `pkg i s:main/git` reads the way people type it.
# Catalog and installed-app lines always carry the full name; the letters exist only
# on the way in, which is why everything downstream can match on the long names.
$script:PkgManagerAlias = @{ s = 'scoop'; w = 'winget'; m = 'msstore' }
$script:PkgManagerNames = 'winget|scoop|msstore|[swm]'

function Resolve-PkgTarget {
    <#
    .SYNOPSIS
        Expands a short manager prefix to the canonical '<manager>:<id>'.
    .DESCRIPTION
        's:main/git' becomes 'scoop:main/git'. An already canonical target and a bare
        word with no prefix both come back untouched, so the auto-router in
        Invoke-PkgInstall still gets to see them.
    #>
    param([Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Target)

    if ($Target -match "^(?<mgr>$script:PkgManagerNames):(?<id>.+)$") {
        # -match is case-insensitive, so the name is folded; the id is left as typed
        $mgr = $Matches['mgr'].ToLowerInvariant()
        if ($script:PkgManagerAlias.ContainsKey($mgr)) { $mgr = $script:PkgManagerAlias[$mgr] }
        return "$($mgr):$($Matches['id'])"
    }
    return $Target
}

function Test-PkgQualifiedTarget {
    <# True when a typed target names its manager, in either the long or short form. #>
    param([Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Target)
    return ($Target -match "^(?:$script:PkgManagerNames):.+$")
}

$script:PkgLastOk = $false

# 0x8A150034 - winget's "no applicable upgrade found", the normal answer when a
# package is already installed at the requested version. Measured, not guessed.
$script:PkgWingetBenignCodes = @(-1978335212)

function Invoke-PkgManagerCommand {
    <#
    .SYNOPSIS
        Runs one manager command and records the outcome in $script:PkgLastOk.
    .DESCRIPTION
        Writes nothing to the pipeline on purpose. A caller that captures output
        (an assignment, or `if (Invoke-PkgManagerCommand ...)`) would force
        PowerShell to redirect the manager's own stdout through the pipeline,
        which flattens winget's live progress rendering. Call it as a bare
        statement and read $script:PkgLastOk.

        $global:LASTEXITCODE is zeroed first because it otherwise still holds the
        previous command's code, which reads as a fresh failure.
    .PARAMETER BenignExitCode
        Codes that mean "nothing was wrong, there was nothing to do". Without them
        an up-to-date machine would be reported as a failure.
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [scriptblock]$Command,
        [string]$Label = 'command',
        [int[]]$BenignExitCode = @()
    )
    $script:PkgLastOk = $false
    $global:LASTEXITCODE = 0
    try {
        & $Command
    } catch {
        Write-PkgNote "[-] $Label failed: $($_.Exception.Message)" 203
        return
    }
    if ($global:LASTEXITCODE -ne 0) {
        if ($global:LASTEXITCODE -in $BenignExitCode) {
            $script:PkgLastOk = $true
            return
        }
        Write-PkgNote "[-] $Label failed with exit code $global:LASTEXITCODE" 203
        return
    }
    $script:PkgLastOk = $true
}

function Select-PkgManagerLines {
    <#
    .SYNOPSIS
        Keeps the lines that belong to one manager.
    .DESCRIPTION
        Used when the command pinned a manager (`pkg scoop install`). Matching is on
        the raw first column - '<manager>:<id>' - so the coloured display column is
        never inspected. Catalog lines only ever carry 'scoop:' or 'winget:'; an
        'msstore:' target can be installed but is not listed, which is why filtering
        on it simply yields nothing.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Manager
    )
    return @($Lines | Where-Object { (($_ -split "`t")[0]) -like "${Manager}:*" })
}

function Show-PkgResultCard {
    <# One summary card for a batch run, instead of an unconditional success line. #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Verb,                       # 'Installed', 'Removed'
        [Parameter(Mandatory = $true)]
        [int]$Ok,
        [AllowEmptyCollection()]
        [string[]]$Failed = @()
    )
    $total = $Ok + $Failed.Count
    if ($Failed.Count -eq 0) {
        Write-PkgCard "$Verb $total of $total package(s)." -Color 42 -Bold
        return
    }
    # Partial success is amber, total failure red
    $color = if ($Ok) { 214 } else { 203 }
    $detail = ($Failed | ForEach-Object { "  x $_" }) -join "`n"
    Write-PkgCard "$Verb $Ok of $total package(s):`n$detail" -Color $color -Bold
}

function Select-PkgActionableLines {
    <#
    .SYNOPSIS
        Drops catalog lines whose package manager is not installed.
    .DESCRIPTION
        Catalog and installed-app lines are prefixed 'scoop:', 'winget:' or
        'msstore:'. Listing packages a user cannot act on is worse than hiding
        them, so a single-manager machine only ever sees its own.
    #>
    param([AllowEmptyCollection()][string[]]$Lines)

    if (@(Get-PkgManagers).Count -eq 2) { return @($Lines) }

    $kept = [System.Collections.Generic.List[string]]::new()
    $hidden = 0
    foreach ($line in $Lines) {
        if ($line -match '^(scoop|winget|msstore)') {
            if (-not (Test-PkgManager -Manager $Matches[1])) { $hidden++; continue }
        }
        $kept.Add($line)
    }

    if ($hidden) {
        $found = @(Get-PkgManagers)
        $advice = if ($found.Count) { "available: $($found -join ', ')" } else { 'no package manager found' }
        Write-PkgNote "[!] $hidden entries hidden - their manager is not installed ($advice)." 214
    }
    return @($kept)
}
