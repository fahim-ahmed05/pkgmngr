"""Build the combined install catalog (Scoop + Winget) as tab-separated lines.

Output format per line:  <raw-target>\t<styled display line>
The raw target (e.g. 'scoop:main/git' or 'winget:Neovim.Neovim') is consumed by
fzf field 1; the styled display (ANSI badges) is rendered by fzf with --ansi.
"""

import sys
import os
import json
import glob
import sqlite3

ESC = '\x1b'
W_COLOR = f'{ESC}[38;5;39m'   # winget cyan
S_COLOR = f'{ESC}[38;5;214m'  # scoop gold
DIM = f'{ESC}[38;5;245m'
RESET = f'{ESC}[0m'


def trunc(s, max_len):
    return s[:max_len - 1] + '…' if len(s) > max_len else s


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
    # Built by scripts/Update-ScoopIndex.ps1; the standalone fast-scoop-search
    # checkout is still honoured so existing setups keep working.
    env = os.environ.get('PKG_SCOOP_INDEX')
    if env and os.path.isfile(env):
        return env
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(os.path.dirname(here), 'cache', 'scoop-index.json'),
        os.path.join(os.path.expanduser('~'), 'Git',
                     'fast-scoop-search', 'scoop-index.json'),
    ]
    for path in candidates:
        if os.path.isfile(path):
            return path
    return ''


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
        for bucket, bval in data.items():
            if isinstance(bval, dict) and 'packages' in bval:
                for pkg, ver in bval['packages'].items():
                    lines.append(scoop_line(bucket, pkg, ver))
        return True
    except Exception:
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


def emit_winget(lines, cli_path=''):
    db = find_winget_db(cli_path)
    if not db:
        return False
    try:
        conn = sqlite3.connect(db)
        c = conn.cursor()
        c.execute('SELECT id, name, latest_version FROM packages;')
        badge = f'{W_COLOR}[winget:winget]{RESET}'
        for pkg_id, name, ver in c:
            v = ver or ''
            n = name or ''
            disp_id = trunc(pkg_id, 40)
            disp_ver = trunc(v, 16)
            desc_str = f'  {DIM}{n}{RESET}' if n else ''
            raw = f'winget:{pkg_id}'
            disp = f'{badge}     {disp_id:<40}  {disp_ver:<16}{desc_str}'
            lines.append(f'{raw}\t{disp}')
        conn.close()
        return True
    except Exception:
        return False


def main():
    lines = []
    winget_db = sys.argv[1] if len(sys.argv) > 1 else ''

    index = find_scoop_index()
    ok = emit_scoop_index(index, lines) if index else False
    if not ok:
        emit_scoop_buckets(lines)

    emit_winget(lines, winget_db)

    sys.stdout.reconfigure(encoding='utf-8')
    sys.stdout.write('\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
