#!/usr/bin/env python3
"""Fault-inject script control flow; no Docker/database/runtime acceptance."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, signal, sys
from pathlib import Path
root = Path(os.environ['FAKE_ROOT'])
scenario = os.environ.get('SCENARIO', '')
args = sys.argv[1:]
with (root / 'calls').open('a') as f: f.write(json.dumps(args) + '\n')
state = root / 'state'
if args[0] == 'inspect':
    if scenario == 'inspect-failure': sys.exit(1)
    if 'Config.Labels' in args[2]: print('momo-pg-client' if args[-1]=='client-id' else 'momo-backend'); sys.exit(0)
    if args[-1]=='client-id': print('running'); sys.exit(0)
    if 'Health' in args[2]: print(state.read_text() + (' unhealthy' if scenario == 'health-failure' else ' healthy'))
    else: print(state.read_text())
    sys.exit(0)
if args[0] == 'ps':
    if scenario=='ps-failure': sys.exit(1)
    if 'label=com.docker.compose.service=momo-pg-client' in args:
        if scenario=='client-busy': print('client-id')
    elif state.read_text()!='absent': print('backend-id')
    sys.exit(0)
if args[:2] == ['compose', 'version']: sys.exit(0)
args = args[1:]
while args and args[0] in ['--project-directory', '--project-name', '--env-file', '-f']: args = args[2:]
command = args[0]
if command == 'pull': sys.exit(1 if scenario == 'pull-failure' else 0)
if command == 'stop':
    if scenario == 'stop-failure': sys.exit(1)
    if state.read_text() != 'absent': state.write_text('exited')
    sys.exit(0)
if command == 'ps':
    if scenario == 'ps-failure': sys.exit(1)
    if state.read_text() != 'absent': print('backend-id')
    sys.exit(0)
if command in ['up', 'start']:
    if args[-1] == 'momo-backend': state.write_text('running')
    sys.exit(0)
if command == 'run' and 'momo-pg-client' in args:
    operation=args[-1]
    if operation=='probe':
        if scenario=='identity-failure': sys.exit(1)
        print('database='+os.environ['MOMO_EXPECTED_DATABASE'])
        print('role='+os.environ['MOMO_EXPECTED_ROLE'])
        print('pg_major=18\nserver_address=10.0.0.2:5432\ndatabase_oid=42')
        if os.environ['MOMO_DATABASE_MODE']=='managed': print('cluster=12345')
        sys.exit(0)
    if operation=='schema-signature':
        if scenario=='signature-failure': sys.exit(1)
        print('ledger-v1'); sys.exit(0)
    if operation in ['writers','empty']:
        sys.exit(1 if scenario in ['writers-present','candidate-not-empty'] else 0)
    if operation=='restore-candidate':
        sys.stdin.read()
        if scenario=='restore-interrupted':
            os.kill(os.getppid(), signal.SIGTERM); sys.exit(143)
        sys.exit(1 if scenario=='restore-failure' else 0)
    if operation=='dump': command='exec'; args=['exec','pg_dump']
    elif operation=='dump-list': command='exec'; args=['exec','pg_restore','--list']
    else: raise SystemExit('unexpected client operation')
if command == 'run':
    if args[-1] == 'migrate':
        if scenario == 'migration-interrupted':
            os.kill(os.getppid(), signal.SIGTERM)
            sys.exit(143)
        sys.exit(1 if scenario == 'migration-failure' else 0)
    if args[-1] == 'schema-check': sys.exit(1 if scenario == 'schema-failure' else 0)
    raise SystemExit('unexpected run')
if command == 'exec':
    text = ' '.join(args)
    if 'pg_isready' in text: sys.exit(0)
    if 'pg_control_system' in text: print('99999' if scenario=='cluster-mismatch' else '12345'); sys.exit(0)
    if 'pg_dump' in text:
        count = root / 'dump-count'
        n = int(count.read_text()) + 1 if count.exists() else 1
        count.write_text(str(n))
        if scenario == 'final-backup-failure' and n == 2: sys.exit(1)
        if scenario == 'backend-reactivated' and n == 2: state.write_text('running')
        if scenario == 'configuration-drift':
            context = root / 'chosen deployment' / '.env'
            context.write_text(context.read_text()+'# changed during operation\n')
        print('valid-mock-dump'); sys.exit(0)
    if '--list' in text:
        sys.stdin.read(); sys.exit(1 if scenario == 'dump-list-failure' else 0)
    if 'pg_terminate_backend' in text: sys.exit(1 if scenario == 'terminate-failure' else 0)
    if 'pg_restore --clean' in text:
        sys.stdin.read()
        if scenario == 'restore-interrupted':
            os.kill(os.getppid(), signal.SIGTERM)
            sys.exit(143)
        sys.exit(1 if scenario == 'restore-failure' else 0)
    raise SystemExit('unexpected exec: ' + text)
raise SystemExit('unexpected command: ' + str(args))
'''


class ScriptSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='momobox-script-safety-')
        self.root = Path(self.temp.name)
        self.nas = self.root / 'nas'
        self.nas.mkdir()
        shutil.copytree(Path(__file__).parent, self.nas / 'scripts')
        (self.nas / 'docker-compose.yaml').write_text('services: {}\n')
        (self.root / 'state').write_text('running')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        (self.bin / 'docker').write_text(FAKE_DOCKER)
        (self.bin / 'docker').chmod(0o755)
        (self.bin / 'sleep').write_text('#!/bin/sh\nexit 0\n')
        (self.bin / 'sleep').chmod(0o755)
        (self.root / 'input.dump').write_text('mock dump')
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'], FAKE_ROOT=str(self.root))
        for key in ('MOMOBOX_DEPLOYMENT_LOCK_DIR', 'MOMOBOX_DEPLOYMENT_LOCK_HELD', 'MOMOBOX_DEPLOYMENT_LOCK_CREATED'):
            self.env.pop(key, None)

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self, name, scenario='', state='running', extra=()):
        (self.root / 'state').write_text(state)
        (self.root / 'calls').write_text('')
        env = dict(self.env, SCENARIO=scenario)
        args = ['sh', str(self.nas / 'scripts' / (name + '.sh'))]
        if name == 'restore': args += ['--yes', str(self.root / 'input.dump')]
        result = subprocess.run(args + list(extra), env=env, text=True, capture_output=True, timeout=10)
        self.calls = [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()]
        self.text_calls = [' '.join(call) for call in self.calls]
        return result

    def called(self, text):
        return any(text in call for call in self.text_calls)

    def assert_stopped(self):
        self.assertEqual((self.root / 'state').read_text(), 'exited')

    def test_update_stops_restarting_before_final_dump_and_migration(self):
        result = self.run_script('update', state='restarting')
        self.assertEqual(result.returncode, 0, result.stderr)
        stop = next(i for i, c in enumerate(self.text_calls) if ' stop ' in c)
        dumps = [i for i, c in enumerate(self.text_calls) if 'pg_dump' in c]
        migrate = next(i for i, c in enumerate(self.text_calls) if c.endswith('migrate'))
        check = next(i for i, c in enumerate(self.text_calls) if c.endswith('schema-check'))
        start = next(i for i, c in enumerate(self.text_calls) if c.endswith('up -d momo-backend'))
        self.assertEqual(len(dumps), 2)
        self.assertLess(dumps[0], stop)
        self.assertLess(stop, dumps[1])
        self.assertLess(dumps[1], migrate)
        self.assertLess(migrate, check)
        self.assertLess(check, start)
        self.assertFalse((self.nas / '.momobox-deployment.lock').exists())

    def test_pull_failure_does_not_stop_existing_service(self):
        result = self.run_script('update', 'pull-failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / 'state').read_text(), 'running')
        self.assertFalse(self.called(' stop '))
        self.assertFalse(self.called('migrate'))

    def test_final_backup_failure_does_not_migrate_or_start(self):
        result = self.run_script('update', 'final-backup-failure')
        self.assertNotEqual(result.returncode, 0)
        self.assert_stopped()
        self.assertFalse(self.called('migrate'))
        self.assertFalse(self.called('up -d momo-backend'))

    def test_update_failures_keep_backend_isolated(self):
        for scenario in ('migration-failure', 'schema-failure', 'health-failure'):
            with self.subTest(scenario=scenario):
                (self.root / 'calls').write_text('')
                lock = self.nas / '.momobox-deployment.lock'
                if lock.exists(): shutil.rmtree(lock)
                result = self.run_script('update', scenario, extra=('--skip-backup',))
                self.assertNotEqual(result.returncode, 0)
                self.assert_stopped()
                if scenario != 'health-failure': self.assertFalse(self.called('up -d momo-backend'))

    def test_unverified_stop_or_ps_retains_lock(self):
        for scenario in ('stop-failure', 'ps-failure', 'inspect-failure'):
            with self.subTest(scenario=scenario):
                lock = self.nas / '.momobox-deployment.lock'
                if lock.exists(): shutil.rmtree(lock)
                (self.root / 'calls').write_text('')
                result = self.run_script('update', scenario, extra=('--skip-backup',))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.called('migrate'))
                self.assertTrue(lock.exists())

    def test_update_absent_backend(self):
        result = self.run_script('update', state='absent', extra=('--skip-backup',))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_update_migration_signal_retains_lock(self):
        result = self.run_script('update', 'migration-interrupted', extra=('--skip-backup',))
        self.assertNotEqual(result.returncode, 0)
        self.assert_stopped()
        self.assertTrue((self.nas / '.momobox-deployment.lock').exists())
        self.assertFalse(self.called('up -d momo-backend'))

    def test_backend_reactivation_during_final_backup_refuses_migration(self):
        result = self.run_script('update', 'backend-reactivated')
        self.assertNotEqual(result.returncode, 0)
        self.assert_stopped()
        self.assertFalse(self.called('migrate'))

    def test_restore_success_does_not_reopen_service(self):
        result = self.run_script('restore', state='restarting')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_stopped()
        self.assertTrue(self.called('schema-check'))
        self.assertFalse(self.called(' start '))
        self.assertFalse(self.called('up -d momo-backend'))
        self.assertIn('not deployment approval', result.stdout)

    def test_restore_failures_never_restart(self):
        for scenario in ('restore-failure', 'schema-failure', 'terminate-failure'):
            with self.subTest(scenario=scenario):
                (self.root / 'calls').write_text('')
                lock = self.nas / '.momobox-deployment.lock'
                if lock.exists(): shutil.rmtree(lock)
                result = self.run_script('restore', scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assert_stopped()
                self.assertFalse(self.called(' start '))
                self.assertFalse(self.called('up -d momo-backend'))
                if scenario in ('restore-failure', 'terminate-failure'):
                    self.assertTrue(lock.exists())

    def test_restore_signal_retains_lock_and_stays_stopped(self):
        result = self.run_script('restore', 'restore-interrupted')
        self.assertNotEqual(result.returncode, 0)
        self.assert_stopped()
        self.assertTrue((self.nas / '.momobox-deployment.lock').exists())
        self.assertFalse(self.called(' start '))

    def test_invalid_dump_never_stops_or_writes(self):
        result = self.run_script('restore', 'dump-list-failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.called(' stop '))
        self.assertFalse(self.called('pg_restore --clean'))


if __name__ == '__main__':
    unittest.main()
