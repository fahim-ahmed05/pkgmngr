# pkgmngr

A standalone unified package manager for Windows PowerShell: **Scoop + Winget** behind one
`pkg` command with an interactive [fzf](https://github.com/junegunn/fzf) TUI and
[Charm Gum](https://github.com/charmbracelet/gum)-styled dialogs.

Search 20,000+ packages instantly, install with multi-select, and preview metadata -
without remembering which manager owns which app.

## Install

No installer needed - it's just a script. Dot-source it from your `$PROFILE`:

```powershell
# 1. Clone somewhere
git clone https://github.com/fahim-ahmed05/pkgmngr "$HOME\Git\pkgmngr"

# 2. Add this line to your PowerShell profile (notepad $PROFILE):
. "$HOME\Git\pkgmngr\pkg.ps1"

# -or- let setup.ps1 do it for you:
pwsh -File "$HOME\Git\pkgmngr\setup.ps1"
```

Restart the shell. Done - `pkg` is available everywhere.

**Requirements:** pwsh 7+, `fzf` 0.69+ (uses `--header-first` and `--info=inline-right`),
`python`, and Scoop + Winget themselves. `gum` recommended (styled cards, spinners, confirm
dialogs - falls back to plain output without it). Everything else, including the Scoop
catalog indexer, is in this repo - no second clone.

```powershell
scoop install fzf python charm-gum
```

## Usage

| Command | What it does |
|---|---|
| `pkg` | Opens the interactive launch menu (install / uninstall / update / upgrade) |
| `pkg install chrome` | Opens fzf over the full catalog, pre-filtered to `chrome` |
| `pkg install` / `pkg add` | Opens fzf over the full catalog (no filter) |
| `pkg uninstall 7zip` / `pkg rm 7zip` | Opens fzf over installed apps, pre-filtered |
| `pkg rm` | Opens fzf over all installed apps |
| `pkg update` | Refresh Winget sources + Scoop buckets |
| `pkg upgrade` | Upgrade everything (Winget, Scoop, UV tools if present) |
| `pkg help` | Styled usage reference |

Aliases: `install` = `i` / `add` / `a` / `get` / `search` · `uninstall` = `u` / `rm` / `remove` / `r` / `del`

### Direct targets (skip fzf)

```powershell
pkg install scoop:extras/tor-browser winget:Neovim.Neovim   # install exactly these
pkg rm scoop:7zip                                           # uninstall directly
pkg rm -Force winget:Some.Publisher.App                     # no confirmation prompt
pkg install chrome -Update                                  # refresh sources, then browse
```

Bucket/source are preserved exactly: `scoop:main/git` runs `scoop install main/git`,
winget ids run `winget install -e --id <id> --source winget`. Bare ids are
auto-routed (`Neovim.Neovim` → winget, `git` → scoop, 12-char store product id → msstore).

### fzf keys

| Key | Action |
|---|---|
| type | live fuzzy filter across bucket, id, name, version |
| `Tab` / `Shift-Tab` | multi-select down / up |
| `?` | toggle metadata preview pane (description, homepage, license, notes) |
| `Enter` | proceed to confirmation card |
| `Esc` | cancel |

## Configuration (optional)

| Variable | Purpose |
|---|---|
| `PKG_SCOOP_INDEX` | Where the Scoop manifest index is read from and written to (default: `<repo>\cache\scoop-index.json`; a `~\Git\fast-scoop-search\scoop-index.json` from an older standalone setup is still used if present, and without either it falls back to scanning bucket manifests) |

## How it works

```
pkgmngr/
├── pkg.ps1                          # sourceable entry: defines `pkg` + dot-sources lib/
├── setup.ps1                        # adds/removes the $PROFILE source line
├── lib/
│   ├── common.ps1                   # gum cards, confirm, dependency checks, buffer hygiene
│   ├── catalog.ps1                  # catalog loader + shared fzf picker (install/uninstall modes)
│   ├── install.ps1                  # Start-PkgInstall / Invoke-PkgInstall
│   ├── uninstall.ps1                # installed-app resolver + uninstall flow
│   ├── update.ps1                   # source sync and full upgrade pipeline
│   └── menu.ps1                     # bare-`pkg` fzf action menu + help card
└── scripts/
    ├── Get-Catalog.py               # merges Scoop index/buckets + Winget SQLite index.db (~140ms)
    ├── Update-ScoopIndex.ps1        # builds the Scoop manifest index (incremental by bucket hash)
    ├── Get-InstalledPackages.py     # parallel resolver: scoop dir scan + winget list (<1s)
    └── Get-PackageInfo.py           # on-demand metadata preview for fzf `?`
```

- Catalog reads Winget's native SQLite source cache directly - no scraping, no daemons.
- Scoop manifests are indexed by the bundled `Update-ScoopIndex.ps1` during `pkg update`:
  it stores each bucket's git hash and only rescans buckets that moved, so a warm refresh
  costs ~25 ms instead of re-reading 5,359 manifests (~1.3 s).
- PowerShell resolves the `WindowsApps` path and hands it to Python (plain Python lacks
  directory-list rights there).
- Terminal input buffers are flushed after gum/fzf runs so leftover capability probes
  (`\e[?2027;0$y`) never pollute the next prompt.
- The launch menu is fzf-based, not `gum choose`: gum centers its list in a viewport whose
  width it measures itself and clips item text in some terminals. All glyphs are ASCII.
- Colors: Winget cyan `39`, Scoop gold `214`, MS Store violet `141`, install accent green
  `42`, uninstall accent red `203`. Zero emojis.

## Uninstall

```powershell
pwsh -File .\setup.ps1 -Remove    # strips the source line from $PROFILE
Remove-Item ..\pkgmngr -Recurse   # and that's the whole uninstall
```
