<#
.SYNOPSIS
    Source synchronization and system-wide upgrade pipeline for pkgmngr.
#>

function Show-PkgRunOutcome {
    <# Green when every step ran and passed, amber naming the exceptions otherwise. #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SuccessText,
        [AllowEmptyCollection()]
        [string[]]$Failed = @(),
        [AllowEmptyCollection()]
        [string[]]$Skipped = @()
    )
    if ($Failed.Count -eq 0 -and $Skipped.Count -eq 0) {
        Write-PkgCard $SuccessText -Color 42 -Bold
        return
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($Skipped.Count) { $parts.Add("skipped: $($Skipped -join ', ')") }
    if ($Failed.Count) { $parts.Add("failed: $($Failed -join ', ')") }
    Write-PkgCard "Finished with exceptions ($($parts -join '; '))" -Color 214 -Bold
}

function Update-PkgScoopIndex {
    <# Rebuilds the Scoop manifest index that Get-Catalog.py reads. #>
    if (-not (Test-PkgManager -Manager 'scoop')) { return }
    $indexer = Join-Path $script:PkgScripts 'Update-ScoopIndex.ps1'
    if (Test-Path $indexer) {
        & $indexer | Out-Host
    }
}

function Update-PkgSources {
    <#
    .SYNOPSIS
        Synchronizes upstream package manifests for the managers present.
    .DESCRIPTION
        Scoop and Winget are handled independently: a missing manager is reported
        and skipped, so a machine with only one of them still syncs fully.
    #>
    if (@(Get-PkgManagers).Count -eq 0) {
        Write-PkgNote '[-] Neither Scoop nor Winget is installed - there are no sources to update.' 203
        return
    }

    $failed = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()

    if (Test-PkgManager -Manager 'winget') {
        Write-PkgCard 'Updating Winget Sources...' -Color 39 -Bold
        Invoke-PkgManagerCommand -Label 'winget source update' -Command { winget source update }
        if (-not $script:PkgLastOk) { $failed.Add('winget source update') }
    } else {
        $skipped.Add('winget')
    }

    if (Test-PkgManager -Manager 'scoop') {
        Write-PkgCard 'Updating Scoop...' -Color 214 -Bold
        Invoke-PkgManagerCommand -Label 'scoop update' -Command { scoop update }
        if (-not $script:PkgLastOk) { $failed.Add('scoop update') }
    } else {
        $skipped.Add('scoop')
    }

    Update-PkgScoopIndex

    Show-PkgRunOutcome -SuccessText 'Package sources updated successfully!' `
        -Failed $failed.ToArray() -Skipped $skipped.ToArray()
}

function Update-PkgAll {
    <#
    .SYNOPSIS
        Upgrades every installed package across the managers present, plus UV tools.
    #>
    if (@(Get-PkgManagers).Count -eq 0) {
        Write-PkgNote '[-] Neither Scoop nor Winget is installed - nothing to upgrade.' 203
        return
    }

    $failed = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()

    if (Test-PkgManager -Manager 'winget') {
        Write-PkgCard 'Updating Winget Sources & Binary' -Color 39 -Bold
        Invoke-PkgManagerCommand -Label 'winget source update' -Command { winget source update }
        if (-not $script:PkgLastOk) { $failed.Add('winget source update') }

        Invoke-PkgManagerCommand -Label 'winget upgrade App Installer' -Command {
            winget upgrade Microsoft.AppInstaller --accept-package-agreements --accept-source-agreements
        }

        Write-PkgCard 'Upgrading Winget Packages' -Color 39 -Bold
        # Deliberately untallied: winget exits non-zero when everything is already
        # up to date, which is the common case and not a failure.
        Invoke-PkgManagerCommand -Label 'winget upgrade --all' -Command {
            winget upgrade --all --accept-package-agreements --accept-source-agreements
        }
    } else {
        $skipped.Add('winget')
    }

    if (Test-PkgManager -Manager 'scoop') {
        Write-PkgCard 'Updating Scoop Packages' -Color 214 -Bold
        Invoke-PkgManagerCommand -Label 'scoop update' -Command { scoop update }
        if (-not $script:PkgLastOk) { $failed.Add('scoop update') }

        Invoke-PkgManagerCommand -Label 'scoop update -a' -Command { scoop update -a }
        Invoke-PkgManagerCommand -Label 'scoop status' -Command { scoop status }

        Update-PkgScoopIndex
    } else {
        $skipped.Add('scoop')
    }

    if (Get-Command uv -ErrorAction SilentlyContinue) {
        Write-PkgCard 'Upgrading UV Tools' -Color 42 -Bold
        Invoke-PkgManagerCommand -Label 'uv tool upgrade --all' -Command { uv tool upgrade --all }
    }

    Clear-PkgInputBuffer
    Show-PkgRunOutcome -SuccessText 'All packages updated successfully!' `
        -Failed $failed.ToArray() -Skipped $skipped.ToArray()
}
