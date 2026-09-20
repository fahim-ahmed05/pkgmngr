import sys
import re
import os
import json
import glob
import subprocess

def get_scoop_info(bucket, pkg):
    user_home = os.path.expanduser('~')
    manifest = None
    app_name = pkg

    if bucket:
        direct_path = os.path.join(user_home, 'scoop', 'buckets', bucket, 'bucket', f'{app_name}.json')
        if os.path.exists(direct_path):
            manifest = direct_path
    if not manifest:
        installed_path = os.path.join(user_home, 'scoop', 'apps', app_name, 'current', 'manifest.json')
        if os.path.exists(installed_path):
            manifest = installed_path
        else:
            # Check most common buckets before disk glob
            for b in ('main', 'extras', 'versions', 'nirsoft', 'sysinternals', 'nerd-fonts'):
                cand = os.path.join(user_home, 'scoop', 'buckets', b, 'bucket', f'{app_name}.json')
                if os.path.exists(cand):
                    manifest = cand
                    bucket = b
                    break
            if not manifest:
                candidates = glob.glob(os.path.join(user_home, 'scoop', 'buckets', '*', 'bucket', f'{app_name}.json'))
                if candidates:
                    manifest = candidates[0]
                    if not bucket:
                        bucket = os.path.basename(os.path.dirname(os.path.dirname(manifest)))

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
            sub = f'{dim}scoop' + (f' ({bucket})' if bucket else '') + (f' • v{ver}' if ver else '') + f'{reset}'
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
            return
        except Exception:
            pass

    # Fallback to scoop info command if manifest reading failed
    target = f'{bucket}/{pkg}' if bucket else pkg
    subprocess.run(['scoop', 'info', target], shell=True)

def get_winget_info(mgr, pkg):
    esc = '\x1b'
    bold = f'{esc}[1m'
    cyan = f'{esc}[38;5;39m'
    dim = f'{esc}[38;5;245m'
    reset = f'{esc}[0m'

    # Instant inspection for local MSIX or ARP packages (avoids slow network query timeout)
    if pkg.startswith('MSIX\\') or pkg.startswith('ARP\\'):
        pkg_type = "MSIX Application" if pkg.startswith("MSIX") else "Installed Application (ARP)"
        print(f'{bold}{cyan}{pkg}{reset}')
        print(f'{dim}winget • local Windows package{reset}\n')
        print(f'{dim}Type      :{reset} {pkg_type}')
        print(f'{dim}Identifier:{reset} {pkg}')
        return

    cmd = ['winget', 'show', '-e', '--id', pkg]
    if mgr:
        cmd.extend(['--source', mgr])
    cmd.append('--accept-source-agreements')

    proc = subprocess.run(cmd, capture_output=True, text=True, shell=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        if proc.stderr:
            print(proc.stderr.strip())
        return

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
    print(f'{dim}winget ({mgr}) • {pkg}' + (f' • v{ver}' if ver else '') + f'{reset}\n')

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

def main():
    if len(sys.argv) < 2:
        return
    raw_input = sys.argv[1].strip()
    clean_line = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', raw_input).strip()

    # Direct target from fzf {1} (e.g. scoop:main/chromedriver or winget:Google.Chrome.Beta)
    if clean_line.startswith('scoop:'):
        target = clean_line[6:]
        bucket, app = target.split('/', 1) if '/' in target else ('', target)
        get_scoop_info(bucket, app)
        return
    elif clean_line.startswith('winget:'):
        get_winget_info('winget', clean_line[7:])
        return
    elif clean_line.startswith('msstore:'):
        get_winget_info('msstore', clean_line[8:])
        return

    # Fallback for bracketed lines [mgr:source] pkg
    m = re.search(r'\[([^\]]+)\]\s+(\S+)', clean_line)
    if not m:
        return

    badge, pkg = m.group(1).strip(), m.group(2).strip()

    if badge.startswith('scoop'):
        bucket = badge.split(':', 1)[1] if ':' in badge else ''
        get_scoop_info(bucket, pkg)
    elif badge.startswith('winget') or badge.startswith('msstore'):
        source = badge.split(':', 1)[1] if ':' in badge else 'winget'
        get_winget_info(source, pkg)

if __name__ == '__main__':
    main()
