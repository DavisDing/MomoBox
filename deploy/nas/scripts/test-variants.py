#!/usr/bin/env python3
"""Exercise real operation scripts with a fake daemon; never a DB acceptance test."""
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import time
import unittest

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('safety', ROOT / 'test-safety.py')
safety = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safety)
DIGEST = 'docker.io/library/postgres@sha256:' + 'a' * 64


class VariantOperationsTests(unittest.TestCase):
    setUp = safety.ScriptSafetyTests.setUp
    tearDown = safety.ScriptSafetyTests.tearDown
    called = safety.ScriptSafetyTests.called
    assert_stopped = safety.ScriptSafetyTests.assert_stopped

    def prepare(self, mode='external', database='momo'):
        shutil.copytree(ROOT.parent / 'operations', self.nas / 'operations')
        self.deploy = self.root / 'chosen deployment'
        self.deploy.mkdir()
        (self.deploy / 'docker-compose.yaml').write_text('services: {}\n')
        (self.deploy / '.env').write_text('DATABASE_URL=postgres://user:private@db/momo\n')
        self.options = ('--deployment-dir', str(self.deploy), '--project-name', 'chosen-momo',
                        '--database-mode', mode, '--expected-database', database,
                        '--expected-role', 'momo_user', '--pg-client-image', DIGEST)

    def run_script(self, name, scenario='', state='running', extra=()):
        return safety.ScriptSafetyTests.run_script(self, name, scenario, state, self.options + extra)

    def proof(self, **overrides):
        values = dict(format='1', database='momo', role='momo_user', pg_major='18',
                      server_address='10.0.0.2:5432', database_oid='42', cluster='12345',
                      client_image=DIGEST, schema_signature='ledger-v1', sha256='a' * 64,
                      candidate_database='momo_candidate',
                      verified='candidate-schema-check', verified_at=str(int(time.time())))
        values.update(overrides)
        path = self.root / 'restore proof'
        path.write_text(''.join(f'{k}={v}\n' for k, v in values.items()))
        return ('--exclusive-writer', '--restore-proof', str(path), '--proof-max-age', '3600')

    def source_meta(self, **overrides):
        data = dict(format='1', database='momo', role='momo_user', pg_major='18',
                    server_address='10.0.0.2:5432', database_oid='42', client_image=DIGEST,
                    schema_signature='ledger-v1',
                    sha256=hashlib.sha256((self.root / 'input.dump').read_bytes()).hexdigest())
        data.update(overrides)
        (self.root / 'input.dump.meta').write_text(''.join(f'{k}={v}\n' for k, v in data.items()))

    def test_external_backup_uses_selected_context_and_no_postgres_service(self):
        self.prepare()
        result = self.run_script('backup')
        self.assertEqual(result.returncode, 0, result.stderr)
        path = Path(result.stdout.strip())
        self.assertEqual(path.parent, (self.deploy / 'backups').resolve())
        self.assertTrue(Path(str(path) + '.meta').is_file())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertFalse(self.called('up -d postgres'))
        self.assertFalse((self.deploy / '.momobox-deployment.lock').exists())
        for args in self.calls:
            if args[:2] == ['compose', 'version'] or args[0] != 'compose':
                continue
            self.assertIn('--project-name', args)
            self.assertEqual(args[args.index('--project-name') + 1], 'chosen-momo')
            self.assertIn(str((self.deploy / '.env').resolve()), args)

    def test_external_update_orders_final_backup_and_keeps_other_db_running(self):
        self.prepare()
        result = self.run_script('update', state='restarting', extra=self.proof())
        self.assertEqual(result.returncode, 0, result.stderr)
        stop = next(i for i, c in enumerate(self.text_calls) if ' stop ' in c)
        dumps = [i for i, c in enumerate(self.text_calls) if c.endswith('momo-pg-client dump')]
        migrate = next(i for i, c in enumerate(self.text_calls) if c.endswith('momo-backend migrate'))
        self.assertEqual(len(dumps), 2)
        self.assertLess(dumps[0], stop)
        self.assertLess(stop, dumps[1])
        self.assertLess(dumps[1], migrate)
        self.assertFalse(self.called('up -d postgres'))
        self.assertFalse(self.called('stop postgres'))

    def test_new_update_cannot_skip_backup(self):
        self.prepare()
        result = self.run_script('update', extra=self.proof() + ('--skip-backup',))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.called(' stop '))
        self.assertFalse(self.called('migrate'))

    def test_expired_or_foreign_restore_proof_blocks_before_stop(self):
        self.prepare()
        for override in ({'verified_at': '1'}, {'database': 'litellm'}, {'schema_signature': 'other'},
                         {'server_address': '10.0.0.3:5432'}):
            with self.subTest(override=override):
                result = self.run_script('update', extra=self.proof(**override))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.called(' stop '))
                self.assertFalse(self.called('migrate'))

    def test_managed_cluster_mismatch_refuses_operation(self):
        self.prepare('managed')
        result = self.run_script('backup', 'cluster-mismatch')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.called('momo-pg-client dump'))

    def test_final_backup_failure_preserves_isolation(self):
        self.prepare()
        result = self.run_script('update', 'final-backup-failure', extra=self.proof())
        self.assertNotEqual(result.returncode, 0)
        self.assert_stopped()
        self.assertFalse(self.called('migrate'))
        self.assertFalse(self.called('up -d momo-backend'))

    def test_other_clients_refuse_migration(self):
        self.prepare()
        result = self.run_script('update', 'writers-present', extra=self.proof())
        self.assertNotEqual(result.returncode, 0)
        self.assert_stopped()
        self.assertFalse(self.called('migrate'))

    def test_backup_client_unknown_retains_lock(self):
        self.prepare()
        result = self.run_script('backup', 'client-busy')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.deploy / '.momobox-deployment.lock').is_dir())

    def test_update_preflight_client_unknown_retains_lock_without_stopping_backend(self):
        self.prepare()
        result = self.run_script('update', 'client-busy', extra=self.proof())
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.deploy / '.momobox-deployment.lock').is_dir())
        self.assertFalse(self.called(' stop '))

    def test_signature_error_and_unbounded_timestamp_refuse_before_stop(self):
        self.prepare()
        result = self.run_script('update', 'signature-failure', extra=self.proof())
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.called(' stop '))
        result = self.run_script('update', extra=self.proof(verified_at='9' * 100))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('timestamp exceeds supported bound', result.stderr)
        self.assertFalse(self.called(' stop '))

    def test_configuration_drift_refuses_further_commands_and_retains_lock(self):
        self.prepare()
        result = self.run_script('backup', 'configuration-drift')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.deploy / '.momobox-deployment.lock').is_dir())
        self.assertFalse(self.called('momo-pg-client dump-list'))
        self.assertFalse(list((self.deploy / 'backups').glob('*.dump')))

    def test_quarantine_blocks_update_even_with_fresh_proof(self):
        self.prepare()
        (self.deploy / '.momobox-restored').touch()
        result = self.run_script('update', extra=self.proof())
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.called(' stop '))

    def test_candidate_restore_writes_proof_without_clean_or_start(self):
        self.prepare(database='momo_candidate')
        self.source_meta()
        output = self.root / 'candidate proof'
        result = self.run_script('restore', extra=('--proof-output', str(output)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_stopped()
        self.assertIn('verified=candidate-schema-check', output.read_text())
        self.assertIn('database=momo\n', output.read_text())
        self.assertIn('candidate_database=momo_candidate\n', output.read_text())
        self.assertTrue((self.deploy / '.momobox-restored').is_file())
        self.assertFalse(self.called('--clean'))
        self.assertFalse(self.called('up -d momo-backend'))
        self.assertFalse(self.called('pg_terminate_backend'))

    def test_candidate_restore_rejects_source_database_or_bad_checksum(self):
        self.prepare(database='momo')
        self.source_meta()
        result = self.run_script('restore', extra=('--proof-output', str(self.root / 'proof')))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.called(' stop '))
        self.assertFalse(self.called('restore-candidate'))

    def test_nonempty_candidate_never_restores(self):
        self.prepare(database='momo_candidate')
        self.source_meta()
        result = self.run_script('restore', 'candidate-not-empty', extra=('--proof-output', str(self.root / 'proof')))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.called('restore-candidate'))

    def test_candidate_restore_interruption_quarantines_and_retains_lock(self):
        self.prepare(database='momo_candidate')
        self.source_meta()
        result = self.run_script('restore', 'restore-interrupted', extra=('--proof-output', str(self.root / 'proof')))
        self.assertNotEqual(result.returncode, 0)
        self.assert_stopped()
        self.assertTrue((self.deploy / '.momobox-restored').is_file())
        self.assertTrue((self.deploy / '.momobox-deployment.lock').is_dir())
        self.assertFalse((self.root / 'proof').exists())

    def test_duplicate_options_and_forged_inherited_lock_fail_closed(self):
        self.prepare()
        result = self.run_script('backup', extra=('--project-name', 'other'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('duplicate', result.stderr)
        (self.deploy / '.momobox-deployment.lock').mkdir()
        self.env['MOMOBOX_DEPLOYMENT_LOCK_HELD'] = '1'
        result = self.run_script('backup')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('lease/context mismatch', result.stderr)


if __name__ == '__main__':
    unittest.main()
