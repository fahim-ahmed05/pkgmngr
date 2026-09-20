<#
.SYNOPSIS
    Interactive launch menu and help screen for bare `pkg` invocations.
#>

function Show-PkgHelp {
    <# Renders the styled usage card. #>
    $usage = @'
NAME
    pkg - unified Scoop + Winget package manager

USAGE
    pkg                       Open the interactive launch menu
    pkg install [query]       Browse/search the full catalog in fzf, install
    pkg uninstall [query]     Browse installed apps in fzf, uninstall
    pkg update                Refresh package sources (Winget + Scoop)
    pkg upgrade               Upgrade all installed packages
    pkg help                  Show this help

ALIASES
    install: i, add, a, get, search    uninstall: u, rm, remove, r, del
    update: sync, sources, refresh     upgrade: up                help: h, ?

EXAMPLES
    pkg install chrome        Open fzf pre-filtered to 'chrome'
    pkg add                   Open fzf with the entire catalog
    pkg rm notepad            Open fzf (installed apps) pre-filtered to 'notepad'
    pkg uninstall -f scoop:git
                              Direct uninstall without prompts

EXPLICIT TARGETS (skip fzf)
    scoop:main/git            winget:Neovim.Neovim        msstore:9WZDNCRFJB4M
    s:main/git                w:Neovim.Neovim             m:9WZDNCRFJB4M
                              Short forms work anywhere a target is named

ONE MANAGER ONLY (paste-ready)
    pkg scoop install extras/tor-browser
                              Installs that exact Scoop target, no fzf
    pkg winget install --id Neovim.Neovim -e
                              Same through Winget; manager flags are ignored
    pkg scoop search          Fzf over Scoop entries only (also: uninstall, rm)
    pkg winget list           Verbs pkg does not wrap run the manager itself
    pkg msstore install 9WZDNCRFJB4M
                              A Store id installs through winget's msstore source

FZF SHORTCUTS
    Tab select | Shift-Tab up-select | Enter confirm | ? toggle info | Esc cancel
'@
    Write-PkgCard $usage -Color 39
}

# Menu entries: dispatch key, label, description
$script:PkgMenuItems = @(
    @{ Key = 'install';   Label = 'Install packages';               Desc = 'search the Scoop + Winget catalog' }
    @{ Key = 'uninstall'; Label = 'Uninstall packages';             Desc = 'pick from what is installed' }
    @{ Key = 'update';    Label = 'Update package sources';         Desc = 'refresh Winget + Scoop indexes' }
    @{ Key = 'upgrade';   Label = 'Upgrade all installed packages'; Desc = 'update every manager in one pass' }
    @{ Key = 'help';      Label = 'Show help';                      Desc = 'usage, aliases, examples' }
)

function Invoke-PkgMenu {
    <#
    .SYNOPSIS
        Bare `pkg`: presents the action menu and dispatches the choice.
    .DESCRIPTION
        Built on fzf rather than `gum choose` - gum centers its list in a viewport
        whose width it measures itself, which clips item text in some terminals.
    #>
    $choice = $null

    if (Get-PkgDependency -Required @('fzf')) {
        $esc  = [char]27
        $bold = "$esc[1m"
        $acc  = "$esc[38;5;39m"
        $fg   = "$esc[38;5;252m"
        $dim  = "$esc[38;5;245m"
        $rst  = "$esc[0m"

        $lines = foreach ($item in $script:PkgMenuItems) {
            $item.Key + "`t" + $fg + $item.Label.PadRight(31) + $rst + $dim + $item.Desc + $rst
        }

        $headerStyled = $acc + $bold + 'pkg' + $rst + ' ' + $dim + '- unified package manager' + $rst +
            '   ' + $acc + 'enter' + $rst + ' ' + $dim + 'run' + $rst +
            '   ' + $acc + 'esc' + $rst + ' ' + $dim + 'cancel' + $rst
        $header = Center-PkgText $headerStyled 'pkg - unified package manager   enter run   esc cancel'

        Clear-PkgInputBuffer
        $fzfArgs = @(
            '--ansi', '--no-multi', '--no-sort', '--tiebreak=index', '--no-hscroll',
            '--delimiter=\t', '--with-nth=2', '--nth=1,2',
            "--header=$header",
            '--header-first',
            '--prompt=select > ',
            '--pointer=>',
            '--layout=reverse', '--border=rounded', '--height=60%', '--min-height=12',
            # inline-right pins the match counter to the right end of the prompt row
            '--info=inline-right',
            '--color=prompt:39,pointer:39,border:238,header:245,info:245,fg:252,fg+:230,spinner:39'
        )
        $picked = @($lines | & fzf @fzfArgs | Select-Object -First 1)
        Clear-PkgInputBuffer

        if (-not $picked) { return }   # Esc / cancel
        $choice = (([string]$picked[0]) -split "`t")[0].Trim()
    } else {
        Write-PkgCard 'pkg - what do you want to do?' -Color 39
        $i = 1
        foreach ($item in $script:PkgMenuItems) { Write-Host "  $i. $($item.Label)"; $i++ }
        $pick = Read-Host 'Enter number (0 to exit)'
        if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $script:PkgMenuItems.Count) { return }
        $choice = $script:PkgMenuItems[[int]$pick - 1].Key
    }

    switch ($choice) {
        'install'   { Start-PkgInstall }
        'uninstall' { Start-PkgUninstall }
        'update'    { Update-PkgSources }
        'upgrade'   { Update-PkgAll }
        'help'      { Show-PkgHelp }
    }
}
