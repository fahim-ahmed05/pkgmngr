<#
.SYNOPSIS
    Install pipeline for pkgmngr.
#>

function Invoke-PkgInstall {
    <# Executes the install command for one manager-qualified target (e.g. 'scoop:main/git'). #>
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Target
    )

    $manager = $null
    $targetId = $Target

    if ($Target -match '^(?<mgr>winget|scoop|msstore):(?<id>.+)$') {
        $manager = $Matches['mgr']
        $targetId = $Matches['id']
    }
    elseif ($Target -match '^(?=.*\d)[A-Za-z0-9]{12}$') {
        $manager = 'msstore'
    }
    elseif ($Target -match '^[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$') {
        $manager = 'winget'
    }
    else {
        $manager = 'scoop'
    }

    switch ($manager) {
        'msstore' {
            Write-PkgCard "Installing $targetId via Microsoft Store..." -Color 141 -Bold
            winget install -e --id "$targetId" --source msstore --accept-package-agreements --accept-source-agreements
        }
        'winget' {
            Write-PkgCard "Installing $targetId via Winget..." -Color 39 -Bold
            winget install -e --id "$targetId" --source winget --accept-package-agreements --accept-source-agreements
        }
        'scoop' {
            Write-PkgCard "Installing $targetId via Scoop..." -Color 214 -Bold
            scoop install "$targetId"
        }
    }
}

function Start-PkgInstall {
    <#
    .SYNOPSIS
        Searches, browses, and installs packages from Scoop and Winget.
    .DESCRIPTION
        Loads the full catalog into an interactive fzf TUI. Supports multi-select,
        query pre-filtering, exact bucket/source installation, and ? preview.
    .PARAMETER Packages
        Search terms (pre-fill fzf) or explicit prefixed targets ('scoop:main/git',
        'winget:Neovim.Neovim') which install directly. The token '-Update'
        refreshes sources before loading the catalog.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Packages
    )

    # Split off flags
    $update = $false
    $args_ = @($Packages | Where-Object {
        if ($_ -match '^(?i)(-update|--update|-u)$') { $update = $true; $false } else { $true }
    })

    if ($update) {
        Update-PkgSources
    }

    # Direct install when every argument is an explicit manager-prefixed target
    $explicit = @($args_ | Where-Object { $_ -match '^(winget|scoop|msstore):' })
    if ($args_.Count -gt 0 -and $explicit.Count -eq $args_.Count) {
        foreach ($target in $explicit) {
            Invoke-PkgInstall -Target $target
        }
        return
    }

    if (-not (Get-PkgDependency -Required @('python'))) { return }

    $catalog = Get-PkgCatalog
    $query = $args_ -join ' '
    $selected = @(Show-PkgPicker -Lines $catalog -Mode 'install' -Query $query)

    if ($selected.Count -eq 0) { return }

    # Parse selections into a summary
    $targets = [System.Collections.Generic.List[string]]::new()
    $summary = [System.Collections.Generic.List[string]]::new()

    foreach ($raw in $selected) {
        if ($raw -match '^scoop:(?<bucket>[^/]+)/(?<pkg>.+)$') {
            $targets.Add("scoop:$($Matches['bucket'])/$($Matches['pkg'])")
            $summary.Add("  • [scoop:$($Matches['bucket'])] $($Matches['pkg'])")
        }
        elseif ($raw -match '^winget:(?<id>.+)$') {
            $targets.Add("winget:$($Matches['id'])")
            $summary.Add("  • [winget:winget] $($Matches['id'])")
        }
        else {
            $targets.Add($raw)
            $summary.Add("  • $raw")
        }
    }

    Write-PkgCard "Packages To Install ($($targets.Count)):`n$($summary -join "`n")" -Color 42

    if (-not (Confirm-Pkg "Proceed with installation?")) {
        Write-PkgNote "[-] Installation aborted."
        return
    }

    foreach ($target in $targets) {
        Invoke-PkgInstall -Target $target
    }

    Clear-PkgInputBuffer
    Write-PkgCard "Installation finished." -Color 42 -Bold
}
