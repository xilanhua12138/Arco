#!/usr/bin/env python3
"""One-time, explicit Keychain -> credentials.json migration. Never prints secrets.

Run with `uv run --no-project python native/migrate-credentials.py` after quitting
Arco. Existing file entries win. Keychain originals are kept for rollback; the
new app neither reads them nor falls back to them after removing a file entry.
"""
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

MAX_BYTES = 1024 * 1024


def read_legacy(service, account):
    try:
        result = subprocess.run(
            ['/usr/bin/security', 'find-generic-password', '-s', service, '-a', account, '-w'],
            capture_output=True, timeout=15,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError('Keychain access timed out; credential was not imported') from None
    if result.returncode == 44:
        return None
    if result.returncode:
        raise RuntimeError('Keychain access failed; credential was not imported')
    return result.stdout.decode('utf-8').removesuffix('\n')


def legacy_provider(provider):
    if provider == 'deepgram':
        for service in ['app.arco.desktop.deepgram.v3', 'app.arco.desktop.deepgram.v2', 'app.arco.desktop.deepgram']:
            key = read_legacy(service, 'api-key')
            if key is not None:
                return {'apiKey': key}
    elif provider == 'elevenLabs':
        key = read_legacy('app.arco.desktop.elevenlabs.v1', 'api-key')
        if key is not None:
            return {'apiKey': key}
    elif provider == 'doubao':
        app_id = read_legacy('app.arco.desktop.doubao.v1', 'app-id')
        if app_id is not None:
            token = read_legacy('app.arco.desktop.doubao.v1', 'access-token')
            if token is None:
                raise RuntimeError('Incomplete legacy Doubao credential; nothing imported')
            return {'appId': app_id, 'accessToken': token}
    elif provider == 'gptLive':
        raw = read_legacy('app.arco.desktop.gpt-live-beta.v1', 'oauth')
        if raw is not None:
            try:
                data = json.loads(raw)
                if data['version'] != 1 or not data['accessToken'] or not data['refreshToken']:
                    raise ValueError()
                return data
            except (ValueError, TypeError, KeyError):
                raise RuntimeError('Invalid legacy OAuth data; nothing imported') from None
    return None


def restrict_file(fd):
    metadata = os.fstat(fd)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_uid != os.geteuid():
        raise RuntimeError('Credential files must be owned regular files without hard links')
    os.fchmod(fd, 0o600)


def migrate(directory, reader=legacy_provider):
    directory.mkdir(mode=0o700, exist_ok=True)
    metadata = directory.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid():
        raise RuntimeError('Credential directory must be an owned directory without a symlink')
    directory.chmod(0o700)
    lock = os.open(directory / 'credentials.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        restrict_file(lock)
        fcntl.flock(lock, fcntl.LOCK_EX)
        destination = directory / 'credentials.json'
        try:
            fd = os.open(destination, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except FileNotFoundError:
            document = {'version': 1, 'providers': {}}
        else:
            with os.fdopen(fd, 'rb') as existing:
                restrict_file(existing.fileno())
                raw = existing.read(MAX_BYTES + 1)
            try:
                if len(raw) > MAX_BYTES:
                    raise ValueError()
                document = json.loads(raw)
                if document['version'] != 1 or not isinstance(document['providers'], dict):
                    raise ValueError()
            except (ValueError, TypeError, KeyError):
                raise RuntimeError('Invalid credential file; existing data was preserved') from None
        statuses = {}
        for provider in ['deepgram', 'elevenLabs', 'doubao', 'gptLive']:
            if provider in document['providers']:
                statuses[provider] = 'existing file entry preserved'
                continue
            try:
                value = reader(provider)
                if value is not None:
                    document['providers'][provider] = value
                    statuses[provider] = 'imported'
                else:
                    statuses[provider] = 'no legacy entry'
            except RuntimeError as error:
                statuses[provider] = str(error)
        encoded = json.dumps(document, indent=2).encode()
        if len(encoded) > MAX_BYTES:
            raise RuntimeError('Credential file is too large; existing data was preserved')
        fd, temporary = tempfile.mkstemp(prefix='.credentials-', dir=directory)
        try:
            with os.fdopen(fd, 'wb') as output:
                os.fchmod(output.fileno(), 0o600)
                output.write(encoded)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, destination)
            parent = os.open(directory, os.O_RDONLY)
            try:
                os.fsync(parent)
            finally:
                os.close(parent)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return statuses
    finally:
        os.close(lock)


if __name__ == '__main__':
    try:
        print(json.dumps(migrate(Path.home() / '.arco'), indent=2))
    except Exception:
        # Do not print tracebacks or JSON parser errors containing credential data.
        raise SystemExit('Credential migration failed; original Keychain entries were preserved.')
