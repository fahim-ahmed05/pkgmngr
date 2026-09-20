"""Build the combined install catalog (Scoop + Winget) as tab-separated lines.

Output format per line:  <raw-target>\t<styled display line>
The raw target (e.g. 'scoop:main/git' or 'winget:Neovim.Neovim') is consumed by
fzf field 1; the styled display (ANSI badges) is rendered by fzf with --ansi.
"""

import sys
import os
import json
import glob
import pathlib
import sqlite3

ESC = '\x1b'
W_COLOR = f'{ESC}[38;5;39m'   # winget cyan
S_COLOR = f'{ESC}[38;5;214m'  # scoop gold
DIM = f'{ESC}[38;5;245m'
RESET = f'{ESC}[0m'

# Application names carry accents and emoji, and a catalog that dies halfway through
# encoding one is a catalog missing its second half. Both streams are stated, not
# inherited: `pkg` sets PYTHONIOENCODING, running this file by hand need not.
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.stderr.reconfigure(encoding='utf-8', errors='replace')


def warn(msg):
    """Say what failed, on stderr.

    PowerShell shows stderr to the user but never feeds it into the captured
    catalog, so a half-loaded catalog cannot pass for a complete one - which is
    what happened while both halves just returned False in silence.
    """
    print(f'[pkg] {msg}', file=sys.stderr)


def trunc(s, max_len):
    # '~' rather than an ellipsis: the display column is decoded by the console's
    # own code page on the way to fzf, so every glyph pkg adds is kept ASCII.
    return s[:max_len - 1] + '~' if len(s) > max_len else s


def find_winget_db(cli_path=''):
    # PowerShell resolves the WindowsApps path (Python lacks directory-list rights there)
    if cli_path and os.path.isfile(cli_path):
        return cli_path
    prog = os.environ.get('ProgramFiles', r'C:\Program Files')
    pattern = os.path.join(prog, 'WindowsApps',
                           'Microsoft.Winget.Source_*', 'Public', 'index.db')
    candidates = sorted(glob.glob(pattern))
    return candidates[-1] if candidates else ''


def find_scoop_index():
    # Built by scripts/Update-ScoopIndex.ps1 into the repository's own cache.
    # One location, no override: without it the bucket manifests are scanned below.
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(os.path.dirname(here), 'cache', 'scoop-index.json')
    return path if os.path.isfile(path) else ''


def scoop_line(bucket, pkg, ver):
    b_text = f'scoop:{bucket}'
    badge = f'{S_COLOR}[{b_text}]{RESET}'
    pad = ' ' * max(2, 20 - len(b_text) - 2)
    disp_pkg = trunc(pkg, 40)
    disp_ver = trunc(ver or '', 16)
    raw = f'scoop:{bucket}/{pkg}'
    disp = f'{badge}{pad}{disp_pkg:<40}  {disp_ver:<16}'
    return f'{raw}\t{disp}'


def emit_scoop_index(path, lines):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        out = []
        for bucket, bval in data.items():
            if isinstance(bval, dict) and 'packages' in bval:
                for pkg, ver in bval['packages'].items():
                    out.append(scoop_line(bucket, pkg, ver))
        # Extended only once the whole file has survived: appending as it went and
        # then failing halfway left the caller to add the bucket scan on top,
        # duplicating every package that had already been emitted.
        lines.extend(out)
        return True
    except Exception as e:
        warn(
            f'Scoop index unusable ({type(e).__name__}: {e}) - reading bucket manifests instead')
        return False


def emit_scoop_buckets(lines):
    """Fallback: scan local scoop bucket manifests directly (no indexer needed)."""
    roots = [os.environ.get('SCOOP', os.path.join(
        os.path.expanduser('~'), 'scoop'))]
    found = False
    for root in roots:
        for bucket_dir in sorted(glob.glob(os.path.join(root, 'buckets', '*', 'bucket', '*.json'))):
            if os.path.basename(bucket_dir) == 'manifest.json':
                continue
            try:
                bucket = os.path.basename(
                    os.path.dirname(os.path.dirname(bucket_dir)))
                pkg = os.path.splitext(os.path.basename(bucket_dir))[0]
                with open(bucket_dir, 'r', encoding='utf-8') as f:
                    d = json.load(f)
                ver = d.get('version', '') or ''
                if isinstance(ver, dict):
                    ver = ver.get('original', '')
                lines.append(scoop_line(bucket, pkg, ver))
                found = True
            except Exception:
                continue
    return found


def scoop_installed():
    """Whether this machine claims a Scoop install, so an empty Scoop half matters."""
    if os.environ.get('SCOOP'):
        return True
    return os.path.isdir(os.path.join(os.path.expanduser('~'), 'scoop', 'buckets'))


def emit_winget(lines, cli_path=''):
    db = find_winget_db(cli_path)
    if not db:
        warn('winget source index not found - run `pkg update`, or install winget entries by id')
        return False
    conn = None
    try:
        # Read-only and patient: `pkg update` leaves winget rewriting this file, and
        # a write-mode connection with the default zero busy timeout fails at once
        # instead of reading the last good copy. Closed in all paths, because the
        # handle is one winget would rather not have held against it.
        uri = f'file:{pathlib.Path(db).as_posix()}?mode=ro'
        conn = sqlite3.connect(uri, uri=True)
        conn.execute('PRAGMA busy_timeout=4000')
        rows = conn.execute(
            'SELECT id, name, latest_version FROM packages;').fetchall()
        badge = f'{W_COLOR}[winget:winget]{RESET}'
        for pkg_id, name, ver in rows:
            v = ver or ''
            n = name or ''
            disp_id = trunc(pkg_id, 40)
            disp_ver = trunc(v, 16)
            desc_str = f'  {DIM}{n}{RESET}' if n else ''
            raw = f'winget:{pkg_id}'
            disp = f'{badge}     {disp_id:<40}  {disp_ver:<16}{desc_str}'
            lines.append(f'{raw}\t{disp}')
        return True
    except Exception as e:
        warn(
            f'winget index unreadable ({type(e).__name__}: {e}) - showing Scoop entries only')
        return False
    finally:
        if conn is not None:
            conn.close()


def main():
    lines = []
    winget_db = sys.argv[1] if len(sys.argv) > 1 else ''

    index = find_scoop_index()
    ok = emit_scoop_index(index, lines) if index else False
    if not ok:
        # The bucket scan is ten times the cost of the index, and silent about it.
        if not index:
            warn('no Scoop index yet - reading bucket manifests instead; `pkg update` builds the fast one')
        emit_scoop_buckets(lines)

    scoop_count = len(lines)
    emit_winget(lines, winget_db)

    # A machine without Scoop has nothing for that half to report, so silence there is
    # right; one that has Scoop and still yielded no entries is the failure worth saying.
    if scoop_count == 0 and scoop_installed():
        warn('no Scoop packages could be listed - run `pkg update` to build the index')
    if not lines:
        warn('catalog is empty - nothing can be offered')

    sys.stdout.write('\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
