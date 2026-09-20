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
