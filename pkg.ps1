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

    A manager name may go in front to pin that manager, which is what the manager's
    own install page says: `pkg scoop install extras/tor-browser`,
    `pkg winget install --id Neovim.Neovim -e`, `pkg scoop search`, `pkg winget list`.
    Verbs pkg does not model are handed to the manager itself.

    A target can also name its manager the short way, in the verb's own argument:
    `pkg i s:main/chrome`, `pkg rm w:Neovim.Neovim`, `pkg i m:9WZDNCRFJB4M`.
.NOTES
    Requires: pwsh 7+, fzf, python; gum recommended (styled cards/menus).
    Missing tools make `pkg` refuse to start rather than half-run; setup.ps1
    installs them.
#>

$script:PkgMngrVersion = '1.0.0'

# Resolve the repository root even when invoked from elsewhere
$script:PkgMngrRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.PSCommandPath }

foreach ($lib in 'common', 'catalog', 'install', 'uninstall', 'update', 'menu') {
    . (Join-Path $script:PkgMngrRoot "lib\$lib.ps1")
}

# Copy-pasted manager commands come dressed in flags. These carry the package as
# their value, so the flag is dropped and the id kept; these configure the run, so
# flag and value go together; anything else starting with '-' is a bare switch.
$script:PkgFlagCarriesTarget = @('--id', '--name', '--moniker', '--query')
$script:PkgFlagTakesValue = @(
    '--source', '-s', '--scope', '--version', '-v', '--architecture', '--arch', '-a',
    '--override', '--log', '--header', '--channel', '--mode', '--when', '--setting',
    '--dependency-source', '--install-arch'
)

function Split-PkgManagerWords {
    <#
    .SYNOPSIS
        Pulls package names out of the words after `pkg <manager> <verb>`.
    .DESCRIPTION
        Install pages hand out lines like 'winget install -e --id Foo.Bar
        --accept-source-agreements', which would read as three packages without
        this. Flags are reported back so the caller can say what was ignored rather
        than quietly reinterpret it.
    #>
    param([string[]]$Words)

    $targets = [System.Collections.Generic.List[string]]::new()
    $ignored = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Words.Count; $i++) {
        $word = $Words[$i]
        if ($word -notmatch '^-') { $targets.Add($word); continue }
        $ignored.Add($word)
        if ($word -in $script:PkgFlagCarriesTarget) {
            if ($i + 1 -lt $Words.Count) { $i++; $targets.Add($Words[$i]) }
            continue
        }
        if ($word -in $script:PkgFlagTakesValue -and
            $i + 1 -lt $Words.Count -and $Words[$i + 1] -notmatch '^-') {
            $i++
        }
    }
    return [pscustomobject]@{ Targets = @($targets); Ignored = @($ignored) }
}

function Invoke-PkgManagerScoped {
    <#
    .SYNOPSIS
        Handles `pkg <scoop|winget> <verb> ...`, pinning one manager for the call.
    .DESCRIPTION
        A manager's own install page says 'scoop install extras/tor-browser', and
        people copy that line with pkg in front of it. The verb decides the route:
        install and uninstall reuse the normal pipelines with the manager pinned
        onto each target, search opens that manager's half of the catalog, and
        anything pkg does not model (bucket, list, config, checkup) is handed to the
        manager itself, which reports its own errors.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Manager,
        [AllowEmptyCollection()][string[]]$Words = @()
    )

    if (-not (Test-PkgManager -Manager $Manager)) {
        Write-PkgNote "[-] $Manager is not installed - nothing here can be done through it." 203
        return
    }

    $verb = if ($Words.Count) { ([string]$Words[0]).ToLowerInvariant() } else { '' }
    $rest = @($Words | Select-Object -Skip 1)

    # Only install and uninstall carry targets; a search keeps its words as a filter
    # and a passed-through verb is none of pkg's business.
    $parts = $null
    if ($verb -in 'i', 'install', 'add', 'a', 'get', 'u', 'uninstall', 'remove', 'rm', 'r', 'del', 'un') {
        $parts = Split-PkgManagerWords -Words $rest
        if ($parts.Ignored.Count) {
            Write-PkgNote "[!] Ignored manager flags: $($parts.Ignored -join ' ') - pkg builds its own." 214
        }
    }

    switch -Regex ($verb) {
        '^(i|install|add|a|get)$' {
            # An inline prefix on the target wins, so nothing is double-pinned
            $pinned = @($parts.Targets | ForEach-Object {
                if (Test-PkgQualifiedTarget $_) { $_ } else { "${Manager}:$_" }
            })
            Start-PkgInstall -Manager $Manager -Packages $pinned
        }
        '^(u|uninstall|remove|rm|r|del|un)$' {
            $pinned = @($parts.Targets | ForEach-Object {
                if (Test-PkgQualifiedTarget $_) { $_ } else { "${Manager}:$_" }
            })
            Start-PkgUninstall -Manager $Manager -Packages $pinned
        }
        '^(s|search|find)$' {
            # A search is a browse, so the words stay a filter instead of becoming targets
            Start-PkgInstall -Manager $Manager -Packages $rest
        }
        '^$' {
            # Bare `pkg scoop`: browse that manager's catalog, nothing installed yet
            Start-PkgInstall -Manager $Manager
        }
        default {
            # pkg has no opinion on this verb; the manager answers for itself
            Write-PkgNote "[!] pkg does not wrap '$verb' - running it through $Manager directly." 245
            Clear-PkgInputBuffer
            $argv = @($verb) + $rest
            & $Manager @argv
            Clear-PkgInputBuffer
        }
    }
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

    # Pre-flight, once, at the door: everything but the usage text needs fzf and
    # python, and refusing here is clearer than failing partway through a TUI.
    if ($Command -notmatch '^(h|help|\?|--help|-h|version|--version|-v)$') {
        $setup = Join-Path $script:PkgMngrRoot 'setup.ps1'
        if (-not (Test-PkgRuntime -SetupPath $setup)) { return }
    }

    if (-not $Command) {
        Invoke-PkgMenu
        return
    }

    # A manager name in the command position pins that manager for the rest of the
    # line, so a command copied off an install page still works with pkg in front.
    if ($Command -match '^(scoop|winget|msstore)$') {
        Invoke-PkgManagerScoped -Manager $Command.ToLowerInvariant() -Words $Arguments
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
    $subcommands = 'install', 'uninstall', 'update', 'upgrade', 'help', 'version', 'scoop', 'winget'
    $subcommands |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
}

# After `pkg scoop` / `pkg winget`, the verbs that router accepts; install and
# uninstall are pkg's own, the rest are passed straight to the manager.
Register-ArgumentCompleter -CommandName pkg -ParameterName Arguments -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    $words = @($commandAst.CommandElements | ForEach-Object { $_.Extent.Text })
    if ($words.Count -lt 2 -or $words[1] -notin 'scoop', 'winget', 'msstore') { return }
    $verbs = 'install', 'uninstall', 'search', 'update', 'upgrade', 'list', 'info',
              'bucket', 'which', 'where', 'config', 'checkup', 'home', 'reset'
    $verbs |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
}
