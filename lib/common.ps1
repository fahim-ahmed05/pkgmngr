<#
.SYNOPSIS
    Shared UI helpers, dependency checks, and terminal hygiene for pkgmngr.
#>

$script:PkgScripts = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'
$script:PkgHasGum = [bool](Get-Command gum -ErrorAction SilentlyContinue)

# Keep python's piped stdout UTF-8 regardless of console code page (badges/ellipsis in catalog)
$env:PYTHONIOENCODING = 'utf-8'

function Write-PkgCard {
    <# Renders a bordered status card (gum styled, plain fallback). #>
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
        gum @styleArgs -- $Text
    } else {
        Write-Host $Text -ForegroundColor DarkCyan
    }
}

function Write-PkgNote {
    <# Renders a single-line inline note. #>
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Text,
        [Parameter(Position = 1)]
        [int]$Color = 245
    )
    if ($script:PkgHasGum) {
        gum style --foreground $Color -- $Text
    } else {
        Write-Host $Text
    }
}

function Confirm-Pkg {
    <# Interactive yes/no prompt. Returns $true when confirmed. #>
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message
    )
    if ($script:PkgHasGum) {
        gum confirm --default=false -- $Message
        return ($LASTEXITCODE -eq 0)
    }
    $answer = Read-Host "$Message [y/N]"
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
    <# Verifies required external tools; writes a card for each missing one. Returns $false when blocked. #>
    param([string[]]$Required = @())
    $missing = @($Required | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    foreach ($tool in $missing) {
        Write-PkgNote "[-] Required tool '$tool' not found in PATH." 203
    }
    return ($missing.Count -eq 0)
}
