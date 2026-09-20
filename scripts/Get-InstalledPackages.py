import os
import sys
import json
import subprocess

# The report itself goes out as ASCII-safe JSON, but a warning carries whatever path or
# manager message upset it, and a locale codepage can fail to encode that.
sys.stderr.reconfigure(encoding='utf-8', errors='replace')


def warn(msg):
    """One line for the user, on stderr, which PowerShell shows and the JSON parse ignores."""
    print(f'[pkg] {msg}', file=sys.stderr)


def get_installed_packages(query=""):
    query_lower = query.strip().lower()

    # 1. Start Winget in background
    #
    # The query is deliberately not handed to winget. Measured here, `winget list`
    # with a search term took 2.3 to 6.1 seconds against 2.2 for the whole list, so
    # filtering remotely buys no time at all - while its own match rules would hide
    # rows the substring filter below is happier about, and a term starting with '-'
    # would arrive as a switch. One list, one parser, one cost.
    cmd = ['winget', 'list', '--accept-source-agreements']

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding='utf-8',
            errors='ignore'
        )
    except Exception as e:
        warn(f'winget could not be started ({type(e).__name__}: {e}) - listing Scoop apps only')
        proc = None

    # 2. Fast local Scoop scan (<15ms)
    scoop_packages = []
    user_home = os.path.expanduser('~')
    scoop_dirs = [
        os.environ.get('SCOOP', os.path.join(user_home, 'scoop')),
        os.environ.get('SCOOP_GLOBAL', os.path.join(os.environ.get('ProgramData', r'C:\ProgramData'), 'scoop'))
    ]

    for base_root in scoop_dirs:
        apps_dir = os.path.join(base_root, 'apps')
        if not os.path.isdir(apps_dir):
            continue
        try:
            entries = os.listdir(apps_dir)
        except OSError:
            continue

        for name in entries:
            if name.lower() == 'scoop':
                continue
            app_path = os.path.join(apps_dir, name)
            if not os.path.isdir(app_path):
                continue

            if query_lower and query_lower not in name.lower():
                continue

            bucket = 'main'
            ver = ''
            cur = os.path.join(app_path, 'current')
            ij = os.path.join(cur, 'install.json')
            if os.path.isfile(ij):
                try:
                    with open(ij, 'r', encoding='utf-8') as f:
                        d = json.load(f)
                        bucket = d.get('bucket', 'main') or 'main'
                except Exception:
                    pass

            if os.path.islink(cur):
                try:
                    ver = os.path.basename(os.readlink(cur))
                except Exception:
                    pass
            if not ver:
                try:
                    subs = [s for s in os.listdir(app_path) if s != 'current' and os.path.isdir(os.path.join(app_path, s))]
                    if subs:
                        ver = subs[-1]
                except OSError:
                    pass

            scoop_packages.append({
                'Manager': 'scoop',
                'Source': bucket,
                'Bucket': bucket,
                'Id': name,
                'Name': name,
                'Version': ver
            })

    # 3. Collect Winget output
    winget_packages = []
    if proc:
        stdout_data, stderr_data = proc.communicate()
        if proc.returncode not in (0, None):
            # Without this a failed 'winget list' looked exactly like an empty machine,
            # and the caller's "nothing matches" note sent people hunting in the registry.
            reason = (stderr_data or '').strip().splitlines()
            warn(f"winget list exited {proc.returncode}" + (f': {reason[0]}' if reason else ''))
        lines = stdout_data.splitlines()
        header_idx = -1
        for i, line in enumerate(lines):
            if line.startswith('Name') and 'Id' in line:
                header_idx = i
                break

        if header_idx >= 0:
            header = lines[header_idx]
            id_pos = header.find('Id')
            ver_pos = header.find('Version')
            src_pos = header.find('Source')
            ap_pos = header.find('Available')
            # When an upgrade is pending winget prints an 'Available' column between
            # Version and Source; slicing to Source would glue the two values together.
            ver_end = ap_pos if 0 < ap_pos < src_pos else src_pos

            for line in lines[header_idx + 2:]:
                if not line.strip():
                    continue
                name = line[:id_pos].strip() if id_pos > 0 else line.strip()
                pkg_id = line[id_pos:ver_pos].strip() if ver_pos > id_pos else line[id_pos:].strip()
                if not pkg_id:
                    continue
                ver = line[ver_pos:ver_end].strip() if (ver_end > ver_pos and ver_pos > 0) else (line[ver_pos:].strip() if ver_pos > 0 else '')
                src = line[src_pos:].strip() if (src_pos > 0 and len(line) > src_pos) else ''
                mgr = 'msstore' if 'msstore' in src.lower() else 'winget'

                if query_lower and query_lower not in name.lower() and query_lower not in pkg_id.lower():
                    continue

                winget_packages.append({
                    'Manager': mgr,
                    'Source': src,
                    'Bucket': '',
                    'Id': pkg_id,
                    'Name': name,
                    'Version': ver
                })

    return scoop_packages + winget_packages

if __name__ == '__main__':
    q = sys.argv[1] if len(sys.argv) > 1 else ""
    res = get_installed_packages(q)
    sys.stdout.write(json.dumps(res))
