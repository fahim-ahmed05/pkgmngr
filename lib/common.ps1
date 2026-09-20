<#
.SYNOPSIS
    Shared UI helpers, dependency checks, and terminal hygiene for pkgmngr.
#>

$script:PkgScripts = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'
$script:PkgHasGum = [bool](Get-Command gum -ErrorAction SilentlyContinue)

# python is asked for UTF-8 so a catalog line never dies on UnicodeEncodeError while
# encoding an accented application name. Left alone if the user set it first, and
# this is the only environment change pkg makes to the session - CLICOLOR_FORCE, the
# other one this file used to set globally, is now scoped to the gum call itself.
if (-not $env:PYTHONIOENCODING) { $env:PYTHONIOENCODING = 'utf-8' }

# The 256-color ids the library passes around, folded onto what a console host
# without gum can actually render. Palette: winget cyan, scoop gold, msstore
# violet, install green, uninstall red, notes grey.
function Get-PkgConsoleColor {
    param([Parameter(Mandatory = $true)][int]$Id)
    switch ($Id) {
        39  { 'Cyan' }
        214 { 'Yellow' }
        141 { 'Magenta' }
        42  { 'Green' }
        203 { 'Red' }
        245 { 'DarkGray' }
        default { 'Gray' }
    }
}

function Invoke-PkgStyled {
    <#
    .SYNOPSIS
        Runs one `gum style` render and cleans up after it.
    .DESCRIPTION
        Two problems are handled here, both caused by gum behaving differently
        when it is not attached to a terminal:

        1. It strips its own ANSI in that case, and every card and note below is
           piped through Out-Host on purpose (see Write-PkgCard) - so without
           CLICOLOR_FORCE the whole UI renders in the default colour and only the
           box shape survives. Measured on gum v2.0.1: 0 escape sequences piped,
           6 per text line forced; FORCE_COLOR is ignored by this build. The
           variable is set for this one process and removed straight away, because
           leaving it set in a session sourced from $PROFILE would make git and
           every other tool there colour their redirected output as well.
        2. It writes a terminal capability probe (\e[?2027;0$y) back into the
           input buffer, which otherwise surfaces as garbage in front of the next
           thing the user types. Flushing after each render is what keeps the last
           card of a run from poisoning the following prompt.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$StyleArgs,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    try {
        $env:CLICOLOR_FORCE = '1'
        $gumArgs = $StyleArgs + @('--', $Text)
        & gum @gumArgs
    } finally {
        Remove-Item Env:CLICOLOR_FORCE -ErrorAction SilentlyContinue
    }
    Clear-PkgInputBuffer
}

function Write-PkgCard {
    <#
    .SYNOPSIS
        Renders a bordered status card (gum styled, plain fallback).
    .DESCRIPTION
        The colour styles both the rounded border and the text, so a card stays
        readable at a glance even while lines of manager output scroll past it.

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
        $styleArgs = @(
            'style', '--border', 'rounded',
            '--border-foreground', $Color, '--foreground', $Color,
            '--padding', '0 2', '--margin', '1 0'
        )
        if ($Bold) { $styleArgs += '--bold' }
        Invoke-PkgStyled -StyleArgs $styleArgs -Text $Text | Out-Host
    } else {
        Write-Host $Text -ForegroundColor (Get-PkgConsoleColor -Id $Color)
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
        Invoke-PkgStyled -StyleArgs @('style', '--foreground', $Color) -Text $Text | Out-Host
    } else {
        Write-Host $Text -ForegroundColor (Get-PkgConsoleColor -Id $Color)
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

# Winget codes that mean "nothing went wrong, there was nothing to do":
#   0x8A150014  update not applicable - the installed package is already at the
#               requested version, or not upgradeable through these sources.
#   0x8A15002B  no applicable update found, printed as "No available upgrade
#               found.  No newer package versions are available from the
#               configured sources." - what `winget upgrade
#               Microsoft.AppInstaller` answers on a current machine.
# Both measured here rather than guessed; a genuine failure uses another code.
$script:PkgWingetBenignCodes = @(-1978335212, -1978335189)

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

        The outcome is recorded, not narrated: $script:PkgLastOk is the only thing
        a caller gets, because the manager has already printed its own explanation
        and pkg's cards restate the failure by name.
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
        # Deliberately silent. The manager has already said what went wrong, in
        # words, on the screen just above, and every caller records the failure:
        # install/uninstall name the package on the result card, the update steps
        # name themselves on the summary card. Repeating it as a bare HRESULT
        # added noise nobody can act on. The one case where pkg is the only
        # witness is a command that could not start at all, and the catch block
        # above still reports that.
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
        [string[]]$Failed = @(),
        # Asked and answered 'no': counted in the total, coloured amber, never a
        # failure - the manager was never invoked, so blaming one would be wrong.
        [int]$Declined = 0
    )
    $total = $Ok + $Failed.Count + $Declined
    if ($Failed.Count -eq 0 -and $Declined -eq 0) {
        Write-PkgCard "$Verb $total of $total package(s)." -Color 42 -Bold
        return
    }
    # Partial success is amber, total failure red
    $color = if ($Ok) { 214 } else { 203 }
    $detail = @($Failed | ForEach-Object { "  x $_" })
    if ($Declined) { $detail += "  - $Declined declined" }
    Write-PkgCard "$Verb $Ok of $total package(s):`n$($detail -join "`n")" -Color $color -Bold
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
