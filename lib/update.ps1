<#
.SYNOPSIS
    Source synchronization and system-wide upgrade pipeline for pkgmngr.
#>

function Update-PkgScoopIndex {
    <# Rebuilds the Scoop manifest index that Get-Catalog.py reads. #>
    $indexer = Join-Path $script:PkgScripts 'Update-ScoopIndex.ps1'
    if (Test-Path $indexer) {
        & $indexer | Out-Host
    }
}

function Update-PkgSources {
    <# Synchronizes upstream package manifests for Winget and Scoop. #>
    Write-PkgCard 'Updating Winget Sources...' -Color 39 -Bold
    winget source update

    Write-PkgCard 'Updating Scoop...' -Color 214 -Bold
    scoop update

    Update-PkgScoopIndex

    Write-PkgCard 'Package sources updated successfully!' -Color 42 -Bold
}

function Update-PkgAll {
    <# Upgrades every installed package across Winget, Scoop, and UV tools. #>
    Write-PkgCard 'Updating Winget Sources & Binary' -Color 39 -Bold
    winget source update
    winget upgrade Microsoft.AppInstaller --accept-package-agreements --accept-source-agreements

    Write-PkgCard 'Upgrading Winget Packages' -Color 39 -Bold
    winget upgrade --all --accept-package-agreements --accept-source-agreements

    Write-PkgCard 'Updating Scoop Packages' -Color 214 -Bold
    scoop update
    scoop update -a
    scoop status

    Update-PkgScoopIndex

    if (Get-Command uv -ErrorAction SilentlyContinue) {
        Write-PkgCard 'Upgrading UV Tools' -Color 42 -Bold
        uv tool upgrade --all
    }

    Write-PkgCard 'All packages updated successfully!' -Color 42 -Bold
}
