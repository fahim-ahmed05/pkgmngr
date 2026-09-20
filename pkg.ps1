<#
.SYNOPSIS
    pkgmngr - unified Scoop + Winget package manager with an fzf TUI.
.DESCRIPTION
    Source this file once from your PowerShell profile to enable the `pkg` command:

        . "$HOME\Git\pkgmngr\pkg.ps1"

    Commands:
        pkg                       Interactive launch menu
        pkg install|add [query]   fzf catalog search -> install
        pkg uninstall|rm [query]  fzf installed-app search -> uninstall
        pkg update                Refresh Winget + Scoop sources
        pkg upgrade               Upgrade all installed packages
        pkg help                  Styled usage reference
.NOTES
    Requires: pwsh 7+, fzf, python; gum recommended (styled cards/menus).
#>

$script:PkgMngrVersion = '1.0.0'

# Resolve the repository root even when invoked from elsewhere
$pkgMngrRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.PSCommandPath }

foreach ($lib in 'common', 'catalog', 'install', 'uninstall', 'update', 'menu') {
    . (Join-Path $pkgMngrRoot "lib\$lib.ps1")
}

function pkg {
    <# Unified package manager entry point (Scoop + Winget via fzf). #>
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(Position = 0)]
        [string]$Command = '',

        [Parameter(ValueFromRemainingArguments = $true, Position = 1)]
        [string[]]$Arguments = @()
    )

    if (-not $Command) {
        Invoke-PkgMenu
        return
    }

    switch -Regex ($Command.ToLowerInvariant()) {
        '^(i|install|add|a|get|search)$' {
            Start-PkgInstall -Packages $Arguments
        }
        '^(u|uninstall|remove|rm|r|del)$' {
            Start-PkgUninstall -Packages $Arguments
        }
        '^(update|sync|sources|refresh)$' {
            Update-PkgSources
        }
        '^(upgrade|up)$' {
            Update-PkgAll
        }
        '^(version|--version|-v)$' {
            Write-PkgNote "pkgmngr v$script:PkgMngrVersion" 39
        }
        '^(h|help|\?|--help|-h)$' {
            Show-PkgHelp
        }
        default {
            Write-PkgNote "[-] Unknown command: pkg $Command" 203
            Show-PkgHelp
        }
    }
}

# Tab completion for subcommands
Register-ArgumentCompleter -CommandName pkg -ParameterName Command -ScriptBlock {
    param($wordToComplete, [string]$commandAst, [string]$cursorPosition)
    $subcommands = 'install', 'uninstall', 'update', 'upgrade', 'help', 'version'
    $subcommands |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
}
