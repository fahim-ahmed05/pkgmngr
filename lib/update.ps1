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
    <#
    .SYNOPSIS
        Rebuilds the Scoop manifest index that Get-Catalog.py reads.
    .DESCRIPTION
        Answers whether the index is usable afterwards. Worth asking for: the index
        is the difference between a 200 ms catalog and a 1.3 s one, and a run that
        finished green while the indexer threw would be lying about itself. An
        unrunnable indexer is the one failure no manager printed a word about.
    #>
    if (-not (Test-PkgManager -Manager 'scoop')) { return $true }   # nothing to index
    $indexer = Join-Path $script:PkgScripts 'Update-ScoopIndex.ps1'
    if (-not (Test-Path $indexer)) { return $true }
    try {
        & $indexer | Out-Host
        return $true
    } catch {
        Write-PkgNote "[-] Scoop index could not be rebuilt: $($_.Exception.Message)" 203
        return $false
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

    if (-not (Update-PkgScoopIndex)) { $failed.Add('scoop index') }

    Show-PkgRunOutcome -SuccessText 'Package sources updated successfully!' `
        -Failed $failed.ToArray() -Skipped $skipped.ToArray()
}

function Update-PkgAll {
    <#
    .SYNOPSIS
        Upgrades every installed package across the managers present.
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

        # App Installer ships winget itself, so it is refreshed before the rest.
        # A current machine answers "no available upgrade found" with a non-zero
        # code, hence the benign list; any other code is a real failure and gets
        # named on the summary card, with winget's own words on the screen above.
        Invoke-PkgManagerCommand -Label 'winget upgrade App Installer' `
            -BenignExitCode $script:PkgWingetBenignCodes -Command {
            winget upgrade Microsoft.AppInstaller --accept-package-agreements --accept-source-agreements
        }
        if (-not $script:PkgLastOk) { $failed.Add('App Installer') }

        Write-PkgCard 'Upgrading Winget Packages' -Color 39 -Bold
        # Tallied now that the 'nothing to do' codes are benign: an up-to-date
        # machine still finishes green, while a package that failed to upgrade
        # (installer in use, hash mismatch, ...) is reported once, by name.
        Invoke-PkgManagerCommand -Label 'winget upgrade --all' `
            -BenignExitCode $script:PkgWingetBenignCodes -Command {
            winget upgrade --all --accept-package-agreements --accept-source-agreements
        }
        if (-not $script:PkgLastOk) { $failed.Add('winget packages') }
    } else {
        $skipped.Add('winget')
    }

    if (Test-PkgManager -Manager 'scoop') {
        Write-PkgCard 'Updating Scoop Packages' -Color 214 -Bold
        Invoke-PkgManagerCommand -Label 'scoop update' -Command { scoop update }
        if (-not $script:PkgLastOk) { $failed.Add('scoop update') }

        Invoke-PkgManagerCommand -Label 'scoop update -a' -Command { scoop update -a }
        if (-not $script:PkgLastOk) { $failed.Add('scoop buckets') }

        # Left untallied on purpose: `scoop status` exists to print what is
        # outdated or broken, and that table is the report - not a failure.
        Invoke-PkgManagerCommand -Label 'scoop status' -Command { scoop status }

        if (-not (Update-PkgScoopIndex)) { $failed.Add('scoop index') }
    } else {
        $skipped.Add('scoop')
    }

    Clear-PkgInputBuffer
    Show-PkgRunOutcome -SuccessText 'All packages updated successfully!' `
        -Failed $failed.ToArray() -Skipped $skipped.ToArray()
}
