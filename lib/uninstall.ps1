<#
.SYNOPSIS
    Uninstall pipeline for pkgmngr.
#>

function Invoke-PkgUninstall {
    <#
    .SYNOPSIS
        Executes the uninstall command for one manager + id pair.
    .DESCRIPTION
        Records success in $script:PkgLastOk; see Invoke-PkgInstall.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Manager,
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $script:PkgLastOk = $false
    if (-not (Test-PkgManager -Manager $Manager)) {
        Write-PkgNote "[-] $Manager is not installed - cannot remove '$Id'." 203
        return
    }

    switch ($Manager) {
        { $_ -in 'msstore', 'winget' } {
            Write-PkgCard "Uninstalling $Id via Winget..." -Color 39 -Bold
            Invoke-PkgManagerCommand -Label "winget uninstall $Id" -Command {
                # Ids that came out of Windows' own install tables (MSIX packages and
                # ARP entries, which can hold spaces) are addressed by --id only; the
                # '-e --id' exact-match route is for catalog ids.
                if ($Id -match '^(MSIX|ARP)\\') {
                    winget uninstall --id "$Id"
                } else {
                    winget uninstall -e --id "$Id"
                }
            }
        }
        'scoop' {
            Write-PkgCard "Uninstalling $Id via Scoop..." -Color 214 -Bold
            Invoke-PkgManagerCommand -Label "scoop uninstall $Id" -Command {
                scoop uninstall "$Id"
            }
        }
    }
}

function Get-PkgInstalled {
    <# Resolves installed packages across Scoop and Winget in parallel; returns objects. #>
    param([string]$Query = '')
    $helperScript = Join-Path $script:PkgScripts 'Get-InstalledPackages.py'

    $title = if ($Query) { "Checking installed packages matching '$Query'..." } else { "Fetching installed packages..." }

    $json = if ($script:PkgHasGum) {
        gum spin --spinner dot --spinner.foreground 214 --title $title --title.foreground 245 --show-stdout -- `
            python $helperScript $Query
    } else {
        python $helperScript $Query
    }

    Clear-PkgInputBuffer

    if (-not $json) { return @() }
    try {
        return @($json | ConvertFrom-Json)
    } catch {
        return @()
    }
}

function Start-PkgUninstall {
    <#
    .SYNOPSIS
        Searches and uninstalls applications installed via Scoop or Winget.
    .PARAMETER Packages
        Search terms (pre-fill fzf), an explicit prefixed target ('scoop:git',
        's:git', 'winget:Neovim.Neovim') for direct uninstall, or the token
        '-Force' to bypass confirmation prompts.
    .PARAMETER Manager
        Narrows the picker and the installed-app list to one manager, set by
        `pkg scoop rm` and friends.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Packages,

        [ValidateSet('', 'scoop', 'winget', 'msstore')]
        [string]$Manager = ''
    )

    # Split off flags
    $force = $false
    $args_ = @($Packages | Where-Object {
        if ($_ -match '^(?i)(-force|--force|-f)$') { $force = $true; $false } else { $true }
    })

    # Direct uninstall whenever every argument already names its manager
    $explicit = @($args_ | Where-Object { Test-PkgQualifiedTarget $_ })
    if ($args_.Count -gt 0 -and $explicit.Count -eq $args_.Count) {
        $removed = 0
        $failed = [System.Collections.Generic.List[string]]::new()
        $declined = 0
        foreach ($target in $explicit) {
            $mgr, $id = (Resolve-PkgTarget $target) -split ':', 2
            if (-not ($force -or (Confirm-Pkg "Uninstall '$id' via ${mgr}?"))) {
                Write-PkgNote "[-] Skipped $id."
                $declined++
                continue
            }
            Invoke-PkgUninstall -Manager $mgr -Id $id
            if ($script:PkgLastOk) { $removed++ } else { $failed.Add("$($mgr):$id") }
        }
        # Nothing was agreed to, so there is no result to report
        if ($removed -or $failed.Count -or $declined) {
            Show-PkgResultCard -Verb 'Removed' -Ok $removed -Failed $failed.ToArray() -Declined $declined
        }
        return
    }

    if (-not (Get-PkgDependency -Required @('python', 'fzf'))) { return }
    if (@(Get-PkgManagers).Count -eq 0) {
        Write-PkgNote '[-] Neither Scoop nor Winget is installed - nothing to uninstall.' 203
        return
    }

    $query = $args_ -join ' '
    $installed = @(Get-PkgInstalled -Query $query)
    if ($Manager) {
        # msstore apps are winget's to remove, so a winget filter keeps them
        $installed = @($installed | Where-Object {
            $_.Manager -eq $Manager -or ($Manager -eq 'winget' -and $_.Manager -eq 'msstore')
        })
    }

    if ($installed.Count -eq 0) {
        $scope = if ($Manager) { " $Manager" } else { '' }
        Write-PkgNote "[-] No installed$scope packages found matching '$query'." 214
        return
    }

    # Build fzf lines with manager badges
    $esc = [char]27
    $fzfLines = foreach ($item in $installed) {
        $badgeText = switch ($item.Manager) {
            'winget'  { if ($item.Source) { "winget:$($item.Source)" } else { 'winget' } }
            'scoop'   { if ($item.Bucket) { "scoop:$($item.Bucket)" } else { 'scoop' } }
            'msstore' { 'winget:msstore' }
        }
        $badgeColor = switch ($item.Manager) {
            'winget'  { "$esc[38;5;39m" }
            'scoop'   { "$esc[38;5;214m" }
            'msstore' { "$esc[38;5;141m" }
        }
        $badge = "$badgeColor[$badgeText]$esc[0m"
        $pad = ' ' * [Math]::Max(2, 20 - ($badgeText.Length + 2))

        $dispId = if ($item.Id.Length -gt 40) { $item.Id.Substring(0, 38) + '..' } else { $item.Id }
        $dispVer = if ($item.Version.Length -gt 16) { $item.Version.Substring(0, 14) + '..' } else { $item.Version }

        $idPadded  = '{0,-40}' -f $dispId
        $verPadded = '{0,-16}' -f $dispVer
        $detail    = "$esc[38;5;245m$($item.Name)$esc[0m"
        $rawTarget = "$($item.Manager):$($item.Id)"
        "$rawTarget`t$badge$pad$idPadded  $verPadded  $detail"
    }

    # An app whose manager is gone can be listed but never removed
    $selectable = @(Select-PkgActionableLines $fzfLines)
    if ($selectable.Count -eq 0) {
        Write-PkgNote "[-] None of the matching packages can be removed with the managers installed here." 214
        return
    }

    $selected = @(Show-PkgPicker -Lines $selectable -Mode 'uninstall' -Query $query)

    if ($selected.Count -eq 0) { return }

    $toUninstall = [System.Collections.Generic.List[PSCustomObject]]::new()
    $summaryList = [System.Collections.Generic.List[string]]::new()

    foreach ($raw in $selected) {
        if ($raw -match '^(?<mgr>[^:]+):(?<id>.+)$') {
            $toUninstall.Add([PSCustomObject]@{ Manager = $Matches['mgr']; Id = $Matches['id'] })
            $summaryList.Add("  - [$($Matches['mgr'])] $($Matches['id'])")
        }
    }

    if ($toUninstall.Count -eq 0) { return }

    if (-not $force) {
        Write-PkgCard "Packages To Uninstall ($($toUninstall.Count)):`n$($summaryList -join "`n")" -Color 203

        if (-not (Confirm-Pkg "Proceed with uninstallation?")) {
            Write-PkgNote "[-] Uninstallation aborted."
            return
        }
    }

    $removed = 0
    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($target in $toUninstall) {
        Invoke-PkgUninstall -Manager $target.Manager -Id $target.Id
        if ($script:PkgLastOk) { $removed++ } else { $failed.Add("$($target.Manager):$($target.Id)") }
    }

    Clear-PkgInputBuffer
    Show-PkgResultCard -Verb 'Removed' -Ok $removed -Failed $failed.ToArray()
}
