"""Scan publishable files, without printing matched secret values."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = {
    'personal Windows home path': re.compile(r'(?i)\b[A-Z]:[\\/]+Users[\\/]+(?!Public\b|Default\b)[^\\/\s]+'),
    'Windows user SID': re.compile(r'S-1-5-21-(?:\d+-){2}\d+-\d+'),
    'email address': re.compile(r'\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b'),
    'credential-shaped token': re.compile(r'\b(?:gh[opusr]_|github_pat_|sk-(?:proj-)?)[A-Za-z0-9_-]{16,}\b'),
    'private network address': re.compile(r'\b(?:10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+)\b'),
}
FORBIDDEN_NAMES = {'.env', 'auth.json', '.install.json', 'proxy-setup-state.json', 'state.json', 'state.json.bak'}

def inspect(name, data, forbidden):
    problems = []
    path = Path(name)
    if path.name in FORBIDDEN_NAMES or path.name.startswith('.env.') or path.suffix.lower() in {'.sqlite', '.log', '.pem', '.key'}:
        problems.append((name, 'runtime or private file'))
    try:
        text = data.decode('utf-8-sig')
    except UnicodeDecodeError:
        return problems + [(name, 'unexpected binary content')]
    for label, pattern in PATTERNS.items():
        if pattern.search(text):
            problems.append((name, label))
    if any(value.lower() in text.lower() for value in forbidden if value):
        problems.append((name, 'locally supplied private literal'))
    return problems

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args()
    forbidden = os.environ.get('CODEX_PRIVACY_FORBIDDEN', '').split('|')
    names = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT).decode('utf-8').split('\0')
    problems = []
    count = 0
    for name in sorted(set(names)):
        file = ROOT / name
        if name and file.is_file():
            problems += inspect(name, file.read_bytes(), forbidden)
            count += 1
    if args.archive:
        with zipfile.ZipFile(args.archive) as archive:
            for name in archive.namelist():
                if not name.endswith('/'):
                    problems += inspect('archive/' + name, archive.read(name), forbidden)
    for name, label in problems:
        print(f'FAIL: {name}: {label}')
    if problems:
        return 1
    print(f'PASS: {count} source files' + (' and release archive' if args.archive else '') + '; no configured private-data patterns found.')
    return 0

if __name__ == '__main__':
    sys.exit(main())
