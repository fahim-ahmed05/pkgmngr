# pkgmngr

A standalone unified package manager for Windows PowerShell: **Scoop + Winget** behind one
`pkg` command with an interactive [fzf](https://github.com/junegunn/fzf) TUI and
[Charm Gum](https://github.com/charmbracelet/gum)-styled dialogs.

Search 20,000+ packages instantly, install with multi-select, and preview metadata -
without remembering which manager owns which app.

## Install

```powershell
git clone https://github.com/fahim-ahmed05/pkgmngr "$HOME\Git\pkgmngr"
pwsh -File "$HOME\Git\pkgmngr\setup.ps1"
```

`setup.ps1` is the whole installer. It asks where to put pkg (default
`%USERPROFILE%\.local\bin\pkgmngr`), checks every dependency, offers to install the
missing ones - Scoop first, Winget if you would rather not have Scoop - then copies
pkg to that folder and adds the source line to your `$PROFILE`. Say no to anything it
needs and the run cancels itself and deletes what it created.

Restart the shell. Done - `pkg` is available everywhere.

Already have fzf and python and just want to run from the clone? Skip the installer:

```powershell
. "$HOME\Git\pkgmngr\pkg.ps1"     # this is all the installer writes into $PROFILE
```

**Requirements:** PowerShell 7+, `fzf` 0.69+ (uses `--header-first` and
`--info=inline-right`), `python`, and **at least one** of Scoop or Winget. `gum` is
optional - cards and spinners, plain output without it. The Scoop catalog indexer is
in this repo too, so nothing else needs cloning. `setup.ps1` checks all of this;
to do it by hand instead:

```powershell
scoop install fzf python gum
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
├── setup.ps1                        # installer: location, dependencies, $PROFILE wiring (-Remove to undo)
├── lib/
│   ├── common.ps1                   # cards, notes, confirm, dependency and manager checks, buffer hygiene
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
- **One manager is enough.** A missing Scoop or Winget is a skip, not an error: the
  catalog and the installed-app list are narrowed to what this machine can actually act
  on, `pkg update` and `pkg upgrade` name which half they skipped, and each per-package
  result is checked (`Installed 2 of 3` with the failures listed) instead of an
  unconditional success card.
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
pwsh -File .\setup.ps1 -Remove    # removes the source line and deletes the installed copy
```

If you source a clone directly instead of installing, delete that line and the clone -
nothing else is written anywhere. The generated `cache/` folder is the only file pkg ever
creates outside your profile.
