<#
.SYNOPSIS
    Uninstall pipeline for pkgmngr.
#>

function Invoke-PkgUninstall {
    <# Executes the uninstall command for one manager + id pair. #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Manager,
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    switch ($Manager) {
        { $_ -in 'msstore', 'winget' } {
            Write-PkgCard "Uninstalling $Id via Winget..." -Color 39 -Bold
            if ($Id -like 'MSIX\*') {
                winget uninstall --id "$Id"
            } else {
                winget uninstall -e --id "$Id"
            }
        }
        'scoop' {
            Write-PkgCard "Uninstalling $Id via Scoop..." -Color 214 -Bold
            scoop uninstall "$Id"
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
        'winget:Neovim.Neovim') for direct uninstall, or the token '-Force'
        to bypass confirmation prompts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Packages
    )

    # Split off flags
    $force = $false
    $args_ = @($Packages | Where-Object {
        if ($_ -match '^(?i)(-force|--force|-f)$') { $force = $true; $false } else { $true }
    })

    # Direct uninstall for a single explicit prefixed target
    if ($args_.Count -eq 1 -and $args_[0] -match '^(?<mgr>winget|scoop|msstore):(?<id>.+)$') {
        $mgr = $Matches['mgr']
        $id  = $Matches['id']
        if (-not $force) {
            if (-not (Confirm-Pkg "Uninstall '$id' via $mgr?")) {
                Write-PkgNote "[-] Skipped $id."
                return
            }
        }
        Invoke-PkgUninstall -Manager $mgr -Id $id
        return
    }

    if (-not (Get-PkgDependency -Required @('python'))) { return }

    $query = $args_ -join ' '
    $installed = Get-PkgInstalled -Query $query

    if ($installed.Count -eq 0) {
        Write-PkgNote "[-] No installed packages found matching '$query'." 214
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

        $dispId = if ($item.Id.Length -gt 40) { $item.Id.Substring(0, 39) + '…' } else { $item.Id }
        $dispVer = if ($item.Version.Length -gt 16) { $item.Version.Substring(0, 15) + '…' } else { $item.Version }

        $idPadded  = '{0,-40}' -f $dispId
        $verPadded = '{0,-16}' -f $dispVer
        $detail    = "$esc[38;5;245m$($item.Name)$esc[0m"
        $rawTarget = "$($item.Manager):$($item.Id)"
        "$rawTarget`t$badge$pad$idPadded  $verPadded  $detail"
    }

    $selected = @(Show-PkgPicker -Lines $fzfLines -Mode 'uninstall' -Query $query)

    if ($selected.Count -eq 0) { return }

    $toUninstall = [System.Collections.Generic.List[PSCustomObject]]::new()
    $summaryList = [System.Collections.Generic.List[string]]::new()

    foreach ($raw in $selected) {
        if ($raw -match '^(?<mgr>[^:]+):(?<id>.+)$') {
            $toUninstall.Add([PSCustomObject]@{ Manager = $Matches['mgr']; Id = $Matches['id'] })
            $summaryList.Add("  • [$($Matches['mgr'])] $($Matches['id'])")
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

    foreach ($target in $toUninstall) {
        Invoke-PkgUninstall -Manager $target.Manager -Id $target.Id
    }

    Clear-PkgInputBuffer
    Write-PkgCard "Uninstallation finished." -Color 203 -Bold
}
