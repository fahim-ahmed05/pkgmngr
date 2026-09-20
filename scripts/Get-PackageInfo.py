import sys
import re
import os
import io
import json
import time
import glob
import hashlib
import subprocess
import contextlib

# fzf reads the preview as UTF-8; never let an odd character in a description cost
# the whole render.
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# The preview is re-rendered every time the cursor comes to rest, and the two
# renderers below cost about a second each - `winget show` because it queries the
# source, `scoop info` because it starts an interpreter. Hovering over one package
# twice should not cost twice, so renders are replayed from a short-lived cache.
# Short TTL by design: a package's advertised version does change, and these files
# are disposable - cache/ is gitignored and deleting it costs only time.
CACHE_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         'cache', 'preview')
CACHE_TTL = 900


def cache_file(key):
    """Where a render of `key` lives, or '' if the cache cannot be used at all."""
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        return os.path.join(CACHE_DIR, hashlib.sha1(key.encode('utf-8')).hexdigest() + '.txt')
    except OSError:
        return ''


def prune_cache():
    """Drop expired entries, so a long-lived session cannot grow this folder forever."""
    cutoff = time.time() - CACHE_TTL
    try:
        names = os.listdir(CACHE_DIR)
    except OSError:
        return
    for name in names:
        path = os.path.join(CACHE_DIR, name)
        try:
            if os.path.getmtime(path) < cutoff:
                os.remove(path)
        except OSError:
            continue


def cached_render(key, render):
    """Run `render`, or replay its output if it ran recently enough.

    The renderer answers True when its output is worth replaying. A miss is not: `no
    package found` may just as well be the source being unreachable a moment ago, and
    storing that would keep a wrong answer on screen for the whole life of the cache.

    Any cache problem is a reason to render, never a reason to show nothing: the
    worst case here is the speed of having no cache at all.
    """
    path = cache_file(key)
    if path:
        try:
            if os.path.isfile(path) and time.time() - os.path.getmtime(path) < CACHE_TTL:
                with open(path, 'r', encoding='utf-8') as f:
                    body = f.read()
                if body:
                    sys.stdout.write(body)
                    return
        except OSError:
            pass
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        worth_keeping = render()
    body = buf.getvalue()
    sys.stdout.write(body)
    sys.stdout.flush()
    if path and body and worth_keeping:
        try:
            with open(path, 'w', encoding='utf-8') as f:
                f.write(body)
            prune_cache()
        except OSError:
            pass


def scoop_root():
    """Where Scoop keeps its buckets - the same rule every other script follows.

    Hardcoding a home-relative scoop folder made the preview silently fall through
    to `scoop info` (a second and a half) on any machine with Scoop elsewhere, for
    instance a scoop folder on another drive.
    """
    env = os.environ.get('SCOOP')
    if env:
        return env.rstrip('\\/')
    # Only the POSIX-ish home from PowerShell; python's own expanduser is fine here too
    return os.path.join(os.path.expanduser('~'), 'scoop')


def get_scoop_info(bucket, pkg):
    root = scoop_root()
    manifest = None
    app_name = pkg

    if bucket:
        direct_path = os.path.join(
            root, 'buckets', bucket, 'bucket', f'{app_name}.json')
        if os.path.exists(direct_path):
            manifest = direct_path
    if not manifest:
        installed_path = os.path.join(
            root, 'apps', app_name, 'current', 'manifest.json')
        if os.path.exists(installed_path):
            manifest = installed_path
        else:
            # Check most common buckets before disk glob
            for b in ('main', 'extras', 'versions', 'nirsoft', 'sysinternals', 'nerd-fonts'):
                cand = os.path.join(root, 'buckets', b,
                                    'bucket', f'{app_name}.json')
                if os.path.exists(cand):
                    manifest = cand
                    bucket = b
                    break
            if not manifest:
                candidates = glob.glob(os.path.join(
                    root, 'buckets', '*', 'bucket', f'{app_name}.json'))
                if candidates:
                    manifest = candidates[0]
                    if not bucket:
                        bucket = os.path.basename(
                            os.path.dirname(os.path.dirname(manifest)))

    if manifest and os.path.exists(manifest):
        try:
            with open(manifest, 'r', encoding='utf-8') as f:
                d = json.load(f)
            ver = d.get('version', '')
            desc = d.get('description', '')
            hp = d.get('homepage', '')
            lic = d.get('license', '')
            if isinstance(lic, dict):
                lic = lic.get('identifier', '')
            notes = d.get('notes', '')

            esc = '\x1b'
            bold = f'{esc}[1m'
            yellow = f'{esc}[38;5;214m'
            dim = f'{esc}[38;5;245m'
            reset = f'{esc}[0m'

            header = f'{bold}{yellow}{app_name}{reset}'
            sub = f'{dim}scoop' + (f' ({bucket})' if bucket else '') + \
                (f' - v{ver}' if ver else '') + f'{reset}'
            print(f'{header}\n{sub}\n')
            if desc:
                print(f'{bold}Description:{reset}\n{desc}\n')
            if hp:
                print(f'{dim}Homepage  :{reset} {hp}')
            if lic:
                print(f'{dim}License   :{reset} {lic}')
            if notes:
                if isinstance(notes, list):
                    notes = '\n'.join(notes)
                print(f'\n{dim}Notes:{reset}\n{notes}')
            # A manifest read is instant and cannot be wrong in a way that matters
            # next time, so it is worth keeping.
            return True
        except Exception:
            pass

    # Fallback to scoop info when no manifest could be read. Scoop is a .cmd, and a
    # batch file only resolves through a shell, so this call keeps shell=True and
    # list2cmdline does the quoting; the output is captured and re-printed so the
    # preview cache below can see it (a direct write would bypass the capture).
    target = f'{bucket}/{pkg}' if bucket else pkg
    cmd = 'scoop info ' + subprocess.list2cmdline([target])
    try:
        proc = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              encoding='utf-8', errors='replace')
        print((proc.stdout or '') + (proc.stderr or ''))
    except Exception as e:
        print(f'scoop info failed: {e}')
    # Nothing here is safe to replay: this branch is also the one that runs when the
    # package does not exist, and its error text is the whole output.
    return False


def get_winget_info(mgr, pkg):
    esc = '\x1b'
    bold = f'{esc}[1m'
    cyan = f'{esc}[38;5;39m'
    dim = f'{esc}[38;5;245m'
    reset = f'{esc}[0m'

    # Instant inspection for local MSIX or ARP packages (avoids slow network query timeout)
    if pkg.startswith('MSIX\\') or pkg.startswith('ARP\\'):
        pkg_type = "MSIX Application" if pkg.startswith(
            "MSIX") else "Installed Application (ARP)"
        print(f'{bold}{cyan}{pkg}{reset}')
        print(f'{dim}winget - local Windows package{reset}\n')
        print(f'{dim}Type      :{reset} {pkg_type}')
        print(f'{dim}Identifier:{reset} {pkg}')
        # Already instant, so caching it would only risk showing a stale name
        return False

    cmd = ['winget', 'show', '-e', '--id', pkg]
    if mgr:
        cmd.extend(['--source', mgr])
    cmd.append('--accept-source-agreements')

    # winget.exe resolves without a shell, so none is started: a shell would re-parse
    # metacharacters in text that came out of a manifest. UTF-8 is stated explicitly
    # because winget emits it while the default decode follows the locale codepage.
    proc = subprocess.run(cmd, capture_output=True, text=True,
                          encoding='utf-8', errors='replace', shell=False)
    if proc.returncode != 0 or not proc.stdout.strip():
        # Winget explains a miss on stdout ("No package found matching input
        # criteria.") and a hard failure on stderr. Showing only stderr left the
        # preview pane an empty rectangle with the reason sitting right next to it
        # unread, so: whatever spoke, say it back.
        message = (proc.stdout or '').strip() or (proc.stderr or '').strip()
        if message:
            print(message)
        return False

    out = proc.stdout
    info = {}
    curr_key = None
    header_title = ''
    tags = []

    for line in out.splitlines():
        if line.startswith('Found '):
            m_title = re.match(r'^Found\s+(.+?)\s+\[', line)
            if m_title:
                header_title = m_title.group(1).strip()
            continue
        m = re.match(r'^([A-Z][a-zA-Z0-9\s]+):\s*(.*)$', line)
        if m:
            curr_key = m.group(1).strip()
            val = m.group(2).strip()
            if curr_key == 'Tags' and not val:
                continue
            info[curr_key] = val
        elif curr_key == 'Tags' and line.startswith('  '):
            tags.append(line.strip())
        elif curr_key and line.startswith('  '):
            info[curr_key] += ' ' + line.strip()

    esc = '\x1b'
    bold = f'{esc}[1m'
    cyan = f'{esc}[38;5;39m'
    dim = f'{esc}[38;5;245m'
    reset = f'{esc}[0m'

    title = header_title or pkg
    ver = info.get('Version', '')
    desc = info.get('Description', '')
    pub = info.get('Publisher', '')
    hp = info.get('Homepage', '')
    lic = info.get('License', '')

    print(f'{bold}{cyan}{title}{reset}')
    print(f'{dim}winget ({mgr}) - {pkg}' +
          (f' - v{ver}' if ver else '') + f'{reset}\n')

    if desc:
        print(f'{bold}Description:{reset}\n{desc}\n')
    if pub:
        print(f'{dim}Publisher :{reset} {pub}')
    if hp:
        print(f'{dim}Homepage  :{reset} {hp}')
    if lic:
        print(f'{dim}License   :{reset} {lic}')
    if tags:
        tag_str = ', '.join(tags)
        print(f'{dim}Tags      :{reset} {tag_str}')
    # A full render off a live source query: exactly the second of work worth saving.
    return True


def main():
    if len(sys.argv) < 2:
        return
    raw_input = sys.argv[1].strip()
    clean_line = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', raw_input).strip()

    # Direct target from fzf {1} (e.g. scoop:main/chromedriver or winget:Google.Chrome.Beta)
    if clean_line.startswith('scoop:'):
        target = clean_line[6:]
        bucket, app = target.split('/', 1) if '/' in target else ('', target)
        cached_render(clean_line, lambda: get_scoop_info(bucket, app))
        return
    elif clean_line.startswith('winget:'):
        cached_render(clean_line, lambda: get_winget_info(
            'winget', clean_line[7:]))
        return
    elif clean_line.startswith('msstore:'):
        cached_render(clean_line, lambda: get_winget_info(
            'msstore', clean_line[8:]))
        return

    # Fallback for bracketed lines [mgr:source] pkg
    m = re.search(r'\[([^\]]+)\]\s+(\S+)', clean_line)
    if not m:
        return

    badge, pkg = m.group(1).strip(), m.group(2).strip()

    if badge.startswith('scoop'):
        bucket = badge.split(':', 1)[1] if ':' in badge else ''
        cached_render(clean_line, lambda: get_scoop_info(bucket, pkg))
    elif badge.startswith('winget') or badge.startswith('msstore'):
        source = badge.split(':', 1)[1] if ':' in badge else 'winget'
        cached_render(clean_line, lambda: get_winget_info(source, pkg))


if __name__ == '__main__':
    main()
