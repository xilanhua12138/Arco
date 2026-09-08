import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('migration', Path(__file__).with_name('migrate-credentials.py'))
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)

class MigrationTests(unittest.TestCase):
    def test_import_preserves_existing_and_only_reports_status(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / '.arco'
            fixture = {'apiKey': 'fixture-secret'}
            result = migration.migrate(directory, lambda provider: fixture if provider == 'deepgram' else None)
            self.assertEqual(result['deepgram'], 'imported')
            self.assertNotIn('fixture-secret', json.dumps(result))
            result = migration.migrate(directory, lambda provider: self.fail('existing provider was read') if provider == 'deepgram' else None)
            self.assertEqual(result['deepgram'], 'existing file entry preserved')
            self.assertEqual(json.loads((directory / 'credentials.json').read_text())['providers']['deepgram'], fixture)
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
            self.assertEqual((directory / 'credentials.json').stat().st_mode & 0o777, 0o600)

    def test_invalid_destination_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            destination = directory / 'credentials.json'
            destination.write_text('broken fixture-secret')
            with self.assertRaises(RuntimeError) as caught:
                migration.migrate(directory)
            self.assertNotIn('fixture-secret', str(caught.exception))
            self.assertEqual(destination.read_text(), 'broken fixture-secret')

    def test_missing_doubao_token_does_not_import_half_a_pair(self):
        original = migration.read_legacy
        migration.read_legacy = lambda service, account: 'fixture-app' if account == 'app-id' else None
        try:
            with self.assertRaises(RuntimeError):
                migration.legacy_provider('doubao')
        finally:
            migration.read_legacy = original

    def test_one_provider_failure_does_not_discard_other_imports(self):
        with tempfile.TemporaryDirectory() as temporary:
            def reader(provider):
                if provider == 'doubao':
                    raise RuntimeError('Keychain access failed; credential was not imported')
                return {'apiKey': 'fixture'} if provider == 'deepgram' else None
            directory = Path(temporary)
            migration.migrate(directory, reader)
            providers = json.loads((directory / 'credentials.json').read_text())['providers']
            self.assertIn('deepgram', providers)
            self.assertNotIn('doubao', providers)

if __name__ == '__main__':
    unittest.main()
