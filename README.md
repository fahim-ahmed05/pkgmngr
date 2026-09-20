# pkgmngr

A standalone unified package manager for Windows PowerShell: **Scoop + Winget** behind one
`pkg` command with an interactive [fzf](https://github.com/junegunn/fzf) TUI and
[Charm Gum](https://github.com/charmbracelet/gum)-styled dialogs.

Search 20,000+ packages instantly, install with multi-select, and preview metadata -
without remembering which manager owns which app.

## Install

```powershell
iwr https://raw.githubusercontent.com/fahim-ahmed05/pkgmngr/main/setup.ps1 -OutFile $env:TEMP\pkgmngr-setup.ps1
pwsh -File $env:TEMP\pkgmngr-setup.ps1
```

`setup.ps1` is the whole installer, and it works in strict order - each step is
checked before the next one touches the disk:

1. **PowerShell 7** - required; it relaunches itself under `pwsh` if you started in
   Windows PowerShell.
2. **Package managers** - reports what it finds (Winget, Scoop) and asks nothing yet.
3. **Git** - only if it is missing, since cloning needs it. This is where a manager is
   picked: with both installed it asks which to use for dependency resolution,
   defaulting to **Winget** because every Windows installation ships with it, and
   offers to install Scoop where it is absent (recommended only if there is no Winget).
4. **The clone** - asks where to put it (default `$HOME\Git\pkgmngr`) and runs
   `git clone`. Run the script from inside a clone you already have and it offers to
   use that one instead of fetching a second copy.
5. **fzf, python, gum** - only the ones that are missing, using the same manager
   decision; a tool already on PATH is never asked about.
6. **`$PROFILE`** - adds the single line that sources `<clone>\pkg.ps1`.

Nothing to install means no questions at all: on a machine that already has git, fzf,
python and gum the run clones, wires the profile and exits without a prompt.

Say no to anything it needs and the run cancels itself: the clone it made and the
profile edit it made are taken back, and nothing else is touched. Tools you agreed
to install are listed so you can remove them yourself.

The clone *is* the installation - `git -C <clone> pull` is how pkgmngr updates, and
no second copy of the files is kept anywhere. Flags: `-CloneDir <path>` answers step 4
up front, `-Manager scoop` (or `winget`) makes the step 3 decision in advance, `-Yes`
takes every default.

Already have git, fzf and python and just want to run from your own clone? Skip the
installer:

```powershell
. "$HOME\Git\pkgmngr\pkg.ps1"     # this is all the installer writes into $PROFILE
```

**Requirements:** PowerShell 7+, `git` (to fetch the repository), `fzf` 0.69+ (uses
`--header-first` and `--info=inline-right`), `python`, and **at least one** of Scoop
or Winget. `gum` is optional - cards and spinners, plain output without it. The Scoop
catalog indexer is in this repo too, so nothing else needs cloning. `setup.ps1` checks
all of this; to do it by hand instead:

```powershell
scoop install git fzf python gum
```

## Usage

| Command | What it does |
|---|---|
| `pkg` | Opens the interactive launch menu (install / uninstall / update / upgrade) |
| `pkg install chrome` | Opens fzf over the full catalog, pre-filtered to `chrome` |
| `pkg install` / `pkg add` | Opens fzf over the full catalog (no filter) |
| `pkg uninstall 7zip` / `pkg rm 7zip` | Opens fzf over installed apps, pre-filtered |
| `pkg rm` | Opens fzf over all installed apps |
| `pkg scoop install extras/tor-browser` | Installs through Scoop directly - the manager name pins the manager |
| `pkg winget list` / `pkg scoop bucket add extras` | Verbs pkg does not wrap go to the manager itself |
| `pkg update` | Refresh Winget sources + Scoop buckets |
| `pkg upgrade` | Upgrade everything installed through Winget and Scoop |
| `pkg help` | Styled usage reference |

Aliases: `install` = `i` / `add` / `a` / `get` / `search` · `uninstall` = `u` / `rm` / `remove` / `r` / `del`

### Direct targets (skip fzf)

```powershell
pkg install scoop:extras/tor-browser winget:Neovim.Neovim   # install exactly these
pkg i s:main/chrome                                          # s:/w:/m: short forms
pkg rm scoop:7zip                                            # uninstall directly
pkg rm -Force winget:Some.Publisher.App                      # no confirmation prompt
pkg install chrome -Update                                   # refresh sources, then browse
```

Bucket/source are preserved exactly: `scoop:main/git` runs `scoop install main/git`,
winget ids run `winget install -e --id <id> --source winget`. The manager may also be
abbreviated (`s:main/git`, `w:Neovim.Neovim`, `m:9WZDNCRFJB4M`), and is case-insensitive
on the manager half only - the id is passed through as typed. Bare ids are
auto-routed (`Neovim.Neovim` → winget, `git` → scoop, 12-char store product id → msstore).

### One manager only (paste-ready)

A manager's own install page says `scoop install extras/tor-browser`, so putting that
manager's name where the verb goes works too - it pins the manager instead of letting
the id be auto-routed:

```powershell
pkg scoop install extras/tor-browser        # Scoop, bucket kept in the target
pkg scoop install tor-browser               # same package, default bucket
pkg winget install Neovim.Neovim            # Winget, by id
pkg winget install --id Notepad++.Notepad++ -e
                                            # flags off the install page are ignored
pkg scoop uninstall git                     # pinned removal, still confirms first
pkg scoop search chrome                     # fzf over Scoop entries only
pkg winget list                             # verbs pkg does not wrap run the manager
```

Nothing else changes: the install card, the per-package result check and the
`Installed n of m` summary are the same ones `pkg install` uses. The bare verb with no
target (`pkg scoop install`) opens fzf over that manager's entries alone.

### fzf keys

| Key | Action |
|---|---|
| type | live fuzzy filter across bucket, id, name, version |
| `Tab` / `Shift-Tab` | multi-select down / up |
| `?` | toggle metadata preview pane (description, homepage, license, notes) |
| `Enter` | proceed to confirmation card |
| `Esc` | cancel |

## How it works

```
pkgmngr/
├── pkg.ps1                          # sourceable entry: checks dependencies, defines `pkg`, dot-sources lib/
├── setup.ps1                        # installer: git, clone, tools, $PROFILE wiring (-Remove to undo)
├── lib/
│   ├── common.ps1                   # cards, notes, confirm, dependency and manager checks, buffer hygiene
│   ├── catalog.ps1                  # catalog loader + shared fzf picker (install/uninstall modes)
│   ├── install.ps1                  # Start-PkgInstall / Invoke-PkgInstall
│   ├── uninstall.ps1                # installed-app resolver + uninstall flow
│   ├── update.ps1                   # source sync and full upgrade pipeline
│   └── menu.ps1                     # bare-`pkg` fzf action menu + help card
└── scripts/
    ├── Get-Catalog.py               # merges Scoop index/buckets + Winget SQLite index.db (~200ms)
    ├── Update-ScoopIndex.ps1        # builds the Scoop manifest index (incremental by bucket hash)
    ├── Get-InstalledPackages.py     # scoop dir scan while winget list runs (~2s, winget dominates)
    └── Get-PackageInfo.py           # on-demand metadata preview for fzf `?`, cached 15 minutes
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
- **`pkg` will not start half-broken.** fzf and python are probed before anything is
  launched, and a name that exists but does not run - the `python` that is really the
  Microsoft Store alias - counts as missing. It prints what is wrong and stops;
  `pkg help` and `pkg version` always work.
- PowerShell resolves the `WindowsApps` path and hands it to Python (plain Python lacks
  directory-list rights there).
- The installed-app list is filtered here, not by winget: `winget list <query>` costs 2.3
  to 6.1 seconds against 2.2 for the whole list, so the whole list is what is read and the
  query is applied to it locally.
- Terminal input buffers are flushed after gum/fzf runs so leftover capability probes
  (`\e[?2027;0$y`) never pollute the next prompt.
- The launch menu is fzf-based, not `gum choose`: gum centers its list in a viewport whose
  width it measures itself and clips item text in some terminals. All glyphs are ASCII.
- Colors: Winget cyan `39`, Scoop gold `214`, MS Store violet `141`, install accent green
  `42`, uninstall accent red `203`. Zero emojis. A card colours its rounded border *and*
  its text with the same id; without gum installed the ids fold onto the console's own
  eight colors. `pkg help` is the exception - a screenful of reference text renders in the
  default foreground (`252`) inside the frame, man-page style.
- gum strips its ANSI whenever stdout is not a terminal, and every card here is piped
  through `Out-Host` on purpose - so `CLICOLOR_FORCE=1` is set around each `gum` call and
  removed again straight after it. Without it the boxes render in the default color and
  only the shape survives (measured on gum v2.0.1: 0 escape sequences piped, 6 per text
  line forced). Setting it at load instead would colour the redirected output of every
  other tool in a profile-sourced session too; `$env:PYTHONIOENCODING=utf-8` is the one
  variable pkg does leave set, and only when it was empty.
- Confirmations are gum's Yes/No buttons, or a typed `[y/N]` when gum is absent. The dialog
  goes through `Out-Host` like every card because a native command's stdout becomes part of
  the enclosing function's return value: called bare, `Confirm-Pkg` would hand its callers
  the rendered screen with the answer as one more line, and a multi-element array is always
  truthy - every `if (-not (Confirm-Pkg ...))` guard would approve whatever it was checking.
  The answer is gum's exit code, and `--default=false` makes a bare Enter mean No.
- `?` previews are cached in `cache/preview/` for 15 minutes, because `winget show` costs
  about a second and fzf re-renders the preview every time the cursor stops. A miss is
  never cached - a source that was unreachable a moment ago should not stay wrong.
- A failed manager command is reported once, by name, on the result or summary card.
  Winget and Scoop have already printed the reason in words, so pkg does not repeat it as
  a bare exit code; codes that only mean "nothing to do" (`0x8A150014`, `0x8A15002B`) are
  never treated as failures at all.

## Uninstall

```powershell
pwsh -File "$HOME\Git\pkgmngr\setup.ps1" -Remove   # removes the source line, then asks about the clone
```

Saying no leaves the clone alone - delete the folder yourself whenever you like.
Tools installed through Scoop or Winget are never removed by pkgmngr, and nothing
else is written anywhere: the generated `cache/` folder inside the clone - the Scoop
index and the preview cache, both safe to delete - is the only file pkg creates
outside your profile.

## License

[MIT](LICENSE) - the whole point is that you can read it, copy it, and fix it yourself.
