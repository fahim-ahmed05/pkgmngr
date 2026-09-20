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

        # Pages print both shapes: `--id Foo.Bar` and `--id=Foo.Bar`. The package is
        # the value either way, so the attached form must not lose it.
        $name = $word
        $attached = ''
        if ($word -match '^(--?[a-z-]+)=(.+)$') { $name = $Matches[1]; $attached = $Matches[2] }

        if ($name -in $script:PkgFlagCarriesTarget) {
            if ($attached) { $targets.Add($attached) }
            elseif ($i + 1 -lt $Words.Count) { $i++; $targets.Add($Words[$i]) }
            continue
        }
        if ($attached) { continue }   # `--scope=user`: its value arrived with the '='
        if ($name -in $script:PkgFlagTakesValue -and
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
            Write-PkgNote "[!] Ignored manager flags: $($parts.Ignored -join ' ')  (pkg builds its own)." 214
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
            # pkg has no opinion on this verb; the manager answers for itself.
            # msstore is a winget source and has no executable of its own, so
            # `pkg msstore list` is winget's to answer.
            $exe = if ($Manager -eq 'msstore') { 'winget' } else { $Manager }
            Write-PkgNote "[!] pkg does not wrap '$verb' - running it through $exe directly." 245
            Clear-PkgInputBuffer
            $argv = @($verb) + $rest
            & $exe @argv
            Clear-PkgInputBuffer
        }
    }
}

# `pkg` takes its arguments from $args rather than a param block, and that is a
# deliberate choice rather than an oversight. A function that declares parameters is
# an advanced function, which drags in the common parameters (-ErrorAction,
# -Verbose, ...), and then a copied manager line fails inside PowerShell's own
# binder before this function is entered:
#
#     pkg winget install -e --id Foo.Bar
#     # Parameter cannot be processed because the parameter name 'e' is ambiguous.
#     # Possible matches include: -ErrorAction -ErrorVariable.
#
# `-e`, `-v`, `-i`, `-a` and the rest of the manager's short flags collide the same
# way. With no parameters there is no binder to disagree with: every word survives to
# the router below, and Split-PkgManagerWords is the only parser in the path. The one
# thing this gives up is parameter-name-based tab completion, which the -Native
# registration at the bottom of this file replaces.
function pkg {
    <# Unified package manager entry point (Scoop + Winget via fzf). #>
    $Command = if ($args.Count) { [string]$args[0] } else { '' }
    $Arguments = @($args | Select-Object -Skip 1)

    # Managers are probed once per command rather than once per session, so that
    # installing Scoop or Winget here is visible to the very next `pkg`. Two
    # Get-Command lookups per command is nothing beside the manager call after them.
    Clear-PkgManagerCache

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
        '^(h|help|\?|-\?|--help|-h)$' {
            Show-PkgHelp
        }
        default {
            Write-PkgNote "[-] Unknown command: pkg $Command" 203
            Show-PkgHelp
        }
    }
}

# Tab completion. -Native because the function has no parameters to hang a completer
# on; the scriptblock is handed the whole command AST, so it works out which word the
# cursor is in itself. The element containing the cursor is the one being completed,
# and a cursor past the end of the line means a fresh word after the last element.
$script:PkgSubcommands = 'install', 'uninstall', 'update', 'upgrade', 'help',
                         'version', 'scoop', 'winget', 'msstore'
# After `pkg scoop` / `pkg winget`: install and uninstall are pkg's own, the rest go
# straight to the manager.
$script:PkgManagerVerbs = 'install', 'uninstall', 'search', 'update', 'upgrade', 'list',
                          'info', 'bucket', 'which', 'where', 'config', 'checkup', 'home', 'reset'

Register-ArgumentCompleter -Native -CommandName pkg -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)

    $elements = @($commandAst.CommandElements)
    $words = @($elements | ForEach-Object { $_.Extent.Text })
    $index = $words.Count
    for ($i = 0; $i -lt $elements.Count; $i++) {
        if ($cursorPosition -le $elements[$i].Extent.EndOffset) { $index = $i; break }
    }

    $candidates = if ($index -eq 1) {
        $script:PkgSubcommands
    } elseif ($index -gt 1 -and $words.Count -gt 1 -and $words[1] -in 'scoop', 'winget', 'msstore') {
        $script:PkgManagerVerbs
    } else {
        return
    }

    $candidates |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
}
