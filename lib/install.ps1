<#
.SYNOPSIS
    Install pipeline for pkgmngr.
#>

function Invoke-PkgInstall {
    <#
    .SYNOPSIS
        Executes the install command for one manager-qualified target.
    .DESCRIPTION
        Records success in $script:PkgLastOk; produces no pipeline output so the
        manager can keep its own terminal.
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Target
    )

    # 's:main/git' and 'Scoop:main/git' both mean the same target
    $Target = Resolve-PkgTarget -Target $Target

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

    $script:PkgLastOk = $false
    if (-not (Test-PkgManager -Manager $manager)) {
        Write-PkgNote "[-] $manager is not installed - cannot install '$targetId'." 203
        return
    }

    switch ($manager) {
        'msstore' {
            Write-PkgCard "Installing $targetId via Microsoft Store..." -Color 141 -Bold
            Invoke-PkgManagerCommand -Label "winget install $targetId" -BenignExitCode $script:PkgWingetBenignCodes -Command {
                winget install -e --id "$targetId" --source msstore --accept-package-agreements --accept-source-agreements
            }
        }
        'winget' {
            Write-PkgCard "Installing $targetId via Winget..." -Color 39 -Bold
            Invoke-PkgManagerCommand -Label "winget install $targetId" -BenignExitCode $script:PkgWingetBenignCodes -Command {
                winget install -e --id "$targetId" --source winget --accept-package-agreements --accept-source-agreements
            }
        }
        'scoop' {
            Write-PkgCard "Installing $targetId via Scoop..." -Color 214 -Bold
            Invoke-PkgManagerCommand -Label "scoop install $targetId" -Command {
                scoop install "$targetId"
            }
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
        's:main/git', 'winget:Neovim.Neovim') which install directly. The token
        '-Update' refreshes sources before loading the catalog.
    .PARAMETER Manager
        Narrows the browse picker to one manager, set by `pkg scoop install` and
        friends. Targets already name their manager, so this only filters what is
        offered; it never overrides an explicit prefix.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Packages,

        [ValidateSet('', 'scoop', 'winget', 'msstore')]
        [string]$Manager = ''
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
    $explicit = @($args_ | Where-Object { Test-PkgQualifiedTarget $_ })
    if ($args_.Count -gt 0 -and $explicit.Count -eq $args_.Count) {
        $ok = 0
        $failed = [System.Collections.Generic.List[string]]::new()
        foreach ($target in $explicit) {
            Invoke-PkgInstall -Target $target
            if ($script:PkgLastOk) { $ok++ } else { $failed.Add($target) }
        }
        Show-PkgResultCard -Verb 'Installed' -Ok $ok -Failed $failed.ToArray()
        return
    }

    if (-not (Get-PkgDependency -Required @('python', 'fzf'))) { return }
    if (@(Get-PkgManagers).Count -eq 0) {
        Write-PkgNote '[-] Neither Scoop nor Winget is installed - there is nothing to install from.' 203
        return
    }

    # Only offer what this machine can actually install
    $catalog = Select-PkgActionableLines (Get-PkgCatalog)
    if ($Manager) {
        $catalog = Select-PkgManagerLines -Lines $catalog -Manager $Manager
        if ($catalog.Count -eq 0) {
            if ($Manager -eq 'msstore') {
                # The catalog is Scoop + Winget; a Store id is installable but never listed
                Write-PkgNote "[-] The catalog has no Store entries - install by id: pkg install msstore:<product-id>" 214
            } else {
                Write-PkgNote "[-] The catalog has no $Manager entries - try 'pkg update' first." 214
            }
            return
        }
    }
    $query = $args_ -join ' '
    $selected = @(Show-PkgPicker -Lines $catalog -Mode 'install' -Query $query)

    if ($selected.Count -eq 0) { return }

    # Parse selections into a summary
    $targets = [System.Collections.Generic.List[string]]::new()
    $summary = [System.Collections.Generic.List[string]]::new()

    foreach ($raw in $selected) {
        if ($raw -match '^scoop:(?<bucket>[^/]+)/(?<pkg>.+)$') {
            $targets.Add("scoop:$($Matches['bucket'])/$($Matches['pkg'])")
            $summary.Add("  - [scoop:$($Matches['bucket'])] $($Matches['pkg'])")
        }
        elseif ($raw -match '^winget:(?<id>.+)$') {
            $targets.Add("winget:$($Matches['id'])")
            $summary.Add("  - [winget:winget] $($Matches['id'])")
        }
        else {
            $targets.Add($raw)
            $summary.Add("  - $raw")
        }
    }

    Write-PkgCard "Packages To Install ($($targets.Count)):`n$($summary -join "`n")" -Color 42

    if (-not (Confirm-Pkg "Proceed with installation?" 42)) {
        Write-PkgNote "[-] Installation aborted."
        return
    }

    $installed = 0
    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($target in $targets) {
        Invoke-PkgInstall -Target $target
        if ($script:PkgLastOk) { $installed++ } else { $failed.Add($target) }
    }

    Clear-PkgInputBuffer
    Show-PkgResultCard -Verb 'Installed' -Ok $installed -Failed $failed.ToArray()
}
