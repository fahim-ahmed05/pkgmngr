<#
.SYNOPSIS
    Catalog loading and the shared fzf picker UI for pkgmngr.
#>

function Get-PkgCatalog {
    <# Loads the combined Scoop + Winget catalog as tab-separated fzf lines. #>
    param([switch]$Quiet)
    $scriptPath = Join-Path $script:PkgScripts 'Get-Catalog.py'

    # Resolve Winget's native index.db here - PowerShell can enumerate WindowsApps, plain Python cannot
    $wingetDb = Get-Item "$env:ProgramFiles\WindowsApps\Microsoft.Winget.Source_*\Public\index.db" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -Last 1 -ExpandProperty FullName

    $lines = if ($script:PkgHasGum -and -not $Quiet) {
        gum spin --spinner dot --spinner.foreground 214 `
            --title "Loading package catalog..." --title.foreground 245 --show-stdout -- `
            python $scriptPath $wingetDb
    } else {
        python $scriptPath $wingetDb
    }
    return @($lines | Where-Object { $_ })
}

function Show-PkgPicker {
    <#
    .SYNOPSIS
        Presents the fzf multi-select UI over catalog lines and returns raw targets.
    .PARAMETER Lines
        Tab-separated '<raw>\t<display>' catalog lines.
    .PARAMETER Mode
        'install' or 'uninstall' - drives accent color, prompt, and header.
    .PARAMETER Query
        Optional pre-filtered search query.
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [string[]]$Lines,
        [ValidateSet('install', 'uninstall')]
        [string]$Mode = 'install',
        [string]$Query = ''
    )

    if (-not (Get-PkgDependency -Required @('fzf', 'python'))) { return @() }
    if ($Lines.Count -eq 0) {
        Write-PkgNote "[-] Package catalog is empty. Try 'pkg update' first." 214
        return @()
    }

    $accent = if ($Mode -eq 'uninstall') { '203' } else { '42' }
    $action = if ($Mode -eq 'uninstall') { 'Uninstall' } else { 'Install' }
    $previewScript = Join-Path $script:PkgScripts 'Get-PackageInfo.py'
    $headerText = "Tab: select | Enter: $action | ?: info | Esc: cancel"

    $fzfArgs = @(
        '-m',
        '--ansi',
        '--no-hscroll',
        '--delimiter=\t',
        '--with-nth=2',
        '--nth=1,2',
        "--header=$(Center-PkgText $headerText $headerText)",
        '--header-first',
        "--prompt=$Mode > ",
        '--pointer=>',
        '--marker=*',
        '--height=100%',
        '--layout=reverse',
        '--border=rounded',
        # inline-right pins the match counter to the right end of the prompt row
        '--info=inline-right',
        '--preview-window=right:50%:hidden:wrap-word,<100(down:50%:hidden:wrap-word)',
        '--preview-wrap-sign=',
        "--preview=python `"$previewScript`" {1}",
        '--bind=?:toggle-preview',
        "--color=prompt:$accent,pointer:$accent,marker:$accent,spinner:$accent,border:238,header:245,info:245,fg:252,fg+:252"
    )

    if ($Query) {
        $fzfArgs += "--query=$Query"
    }

    Clear-PkgInputBuffer
    $selectedLines = @($Lines | fzf @fzfArgs)
    Clear-PkgInputBuffer

    foreach ($line in $selectedLines) {
        if ($line) { ($line -split "`t")[0].Trim() }
    }
}
