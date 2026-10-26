#!/usr/bin/env python3
"""Check tracked/candidate files without printing potentially sensitive matches."""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
SKIP_DIRS = {'.git', '.build', 'dist', '__pycache__'}
PRIVATE_NAMES = {'tasks.json', 'focus.json', 'deadline-reminders.json', 'paste-draft.txt', 'canvas-draft.txt'}
RULES = {
    'private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'GitHub token': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b'),
    'cloud access key': re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'private workstation path': re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+/'),
    'unredacted email': re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
}


def files() -> list[Path]:
    if (ROOT / '.git').is_dir():
        result = subprocess.run(['git', 'ls-files', '-co', '--exclude-standard', '-z'], cwd=ROOT, capture_output=True, check=True)
        return [ROOT / name.decode('utf-8') for name in result.stdout.split(b'\0') if name]
    return [p for p in ROOT.rglob('*') if p.is_file() and not any(part in SKIP_DIRS for part in p.relative_to(ROOT).parts)]


def main() -> int:
    findings: list[tuple[str, str]] = []
    candidates = files()
    for path in candidates:
        relative = path.relative_to(ROOT)
        name = str(relative)
        if path.is_symlink():
            findings.append((name, 'symlinks require manual inspection'))
            continue
        if path.name in PRIVATE_NAMES or path.name.endswith('-draft.txt') or any(part in SKIP_DIRS for part in relative.parts):
            findings.append((name, 'personal or generated data filename'))
        if path.suffix.lower() in {'.zip', '.dmg', '.pkg', '.ics', '.log'} or '.app' in name:
            findings.append((name, 'generated artifact must not be in the source repository'))
        data = path.read_bytes()
        if b'\0' in data:
            if path.suffix.lower() not in {'.png', '.icns'}:
                findings.append((name, 'unexpected binary content'))
            continue
        text = data.decode('utf-8', errors='replace')
        for label, pattern in RULES.items():
            for match in pattern.finditer(text):
                if label == 'unredacted email' and match.group(0).endswith(('@example.com', '@example.org', '@example.net', '@users.noreply.github.com')):
                    continue
                findings.append((name, label))
                break
        for raw in re.findall(r'https?://[^\s<>"\)\\]+', text):
            parsed = urlsplit(raw)
            host = (parsed.hostname or '').lower()
            is_example = any(host == domain or host.endswith('.' + domain) for domain in ['example.com', 'example.org', 'example.net'])
            if '/courses/' in parsed.path and re.search(r'/(?:assignments|announcements)/\d+', parsed.path) and not is_example:
                findings.append((name, 'real course or assignment URL'))
            if ('zoom.us' in host or 'teams.microsoft.com' in host or 'meet.google.com' in host) and len(parsed.path) > 1 and not is_example:
                findings.append((name, 'private meeting URL'))
    if findings:
        for path, reason in sorted(set(findings)):
            print(f'REVIEW {path}: {reason}')
        return 1
    print(f'Privacy check passed for {len(candidates)} source files. Manual review is still required for prose and images.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
