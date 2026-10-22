#!/usr/bin/env python3
"""Run actual URI parser/client shell with fake PG binaries, never a real DB."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

OPERATIONS = Path(__file__).resolve().parents[1] / 'operations'

FAKE_PG = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name=Path(sys.argv[0]).name
with open(os.environ['CALLS'], 'a') as out:
    out.write(json.dumps([name]+sys.argv[1:])+'\n')
if name=='pg_dump' and '--version' in sys.argv:
    print('pg_dump (PostgreSQL) '+os.environ.get('CLIENT_MAJOR','18')+'.6'); sys.exit(0)
if name=='psql':
    sql=sys.argv[-1]
    if os.environ.get('QUERY_ERROR'):
        print('private diagnostic',file=sys.stderr); sys.exit(1)
    if 'server_version_num' in sql:
        print('momo|momo_user|'+os.environ.get('SERVER_MAJOR','18'))
    elif 'NOT rolsuper' in sql: print(os.environ.get('ROLE_ALLOWED','true'))
    elif 'pg_stat_activity' in sql: print(os.environ.get('CLIENTS','0'))
    elif 'pg_class' in sql: print(os.environ.get('OBJECTS','0'))
    elif 'inet_server_addr' in sql: print('10.0.0.2:5432')
    elif 'pg_database' in sql: print('42')
    elif 'pg_control_system' in sql: print('12345')
    elif 'string_agg' in sql: print('ledger-v1')
    else: raise SystemExit('unexpected SQL')
elif name=='pg_restore':
    sys.stdin.read()
elif name=='pg_dump': print('mock archive')
'''


class PgClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='momobox-pg-client-')
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.calls = self.root / 'calls'
        self.calls.touch()
        # Relocate only container-private paths; the production files are tested
        # byte-for-byte apart from that replacement, without writing /tmp globals.
        self.parser = self.root / 'pg-connection.awk'
        self.parser.write_text((OPERATIONS / 'pg-connection.awk').read_text().replace('/tmp/', str(self.root) + '/'))
        self.script = self.root / 'pg-client.sh'
        self.script.write_text((OPERATIONS / 'pg-client.sh').read_text()
                               .replace('/momo/pg-connection.awk', str(self.parser))
                               .replace('/tmp/', str(self.root) + '/'))
        for name in ('psql', 'pg_dump', 'pg_restore'):
            path = self.bin / name
            path.write_text(FAKE_PG)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        CALLS=str(self.calls), MOMO_EXPECTED_DATABASE='momo',
                        MOMO_EXPECTED_ROLE='momo_user', MOMO_DATABASE_MODE='external',
                        DATABASE_URL='postgresql://momo_user:private@db:5432/momo?sslmode=disable')

    def tearDown(self):
        self.temp.cleanup()

    def parse(self, uri):
        env = dict(self.env, DATABASE_URL=uri)
        return subprocess.run(['awk', '-f', str(self.parser)], env=env,
                              input='', text=True, capture_output=True, timeout=5)

    def run_client(self, operation, **env):
        self.calls.write_text('')
        return subprocess.run(['sh', str(self.script), operation], env=dict(self.env, **env),
                              input='fixture archive', text=True, capture_output=True, timeout=5)

    def test_percent_decoding_and_pgpass_escaping_are_private(self):
        result = self.parse('postgresql://momo_user:p%3Aa%5Css%40%25@db/momo?sslmode=require')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'momo.pgpass').read_text(), 'db:5432:momo:momo_user:p\\:a\\\\ss@%\n')
        self.assertNotIn('p:a', (self.root / 'momo-service.conf').read_text())
        self.assertEqual(result.stdout + result.stderr, '')

    def test_ipv6_is_written_as_libpq_host_and_escaped_in_passfile(self):
        result = self.parse('postgres://momo_user:private@[2001:db8::2]:5433/momo')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('host=2001:db8::2\nport=5433', (self.root / 'momo-service.conf').read_text())
        self.assertTrue((self.root / 'momo.pgpass').read_text().startswith('2001\\:db8\\:\\:2:5433:'))

    def test_invalid_uris_and_wrong_identity_are_rejected_without_output(self):
        for uri in ('postgres://momo_user:@db/momo',
                    'postgres://other:secret@db/momo', 'postgres://momo_user:secret@db/litellm',
                    'postgres://momo_user:p%00@db/momo', 'postgres://momo_user:p%0a@db/momo',
                    'postgres://momo_user:p%xy@db/momo', 'postgres://momo_user:p@db:0/momo',
                    'postgres://momo_user:p@db:65536/momo',
                    'postgres://momo_user:p@db/momo?options=bad',
                    'postgres://momo_user:p@db/momo?sslmode=require&sslmode=disable',
                    'postgres://momo_user:p@db/momo?connect_timeout=0'):
            with self.subTest(uri=uri):
                result = self.parse(uri)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout + result.stderr, '')

    def test_probe_checks_actual_identity_and_keeps_password_out_of_arguments(self):
        result = self.run_client('probe')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('pg_major=18', result.stdout)
        self.assertIn('database_oid=42', result.stdout)
        self.assertNotIn('private', self.calls.read_text() + result.stdout + result.stderr)
        self.assertEqual((self.root / 'momo.pgpass').stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / 'momo-service.conf').stat().st_mode & 0o777, 0o600)

    def test_pg16_probe_and_managed_cluster(self):
        result = self.run_client('probe', CLIENT_MAJOR='16', SERVER_MAJOR='16', MOMO_DATABASE_MODE='managed')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('pg_major=16\n', result.stdout)
        self.assertIn('cluster=12345\n', result.stdout)

    def test_major_mismatch_and_elevated_role_refuse_before_dump(self):
        for env in ({'SERVER_MAJOR': '16'}, {'ROLE_ALLOWED': 'false'},
                    {'CLIENT_MAJOR': '17', 'SERVER_MAJOR': '17'}):
            with self.subTest(env=env):
                result = self.run_client('dump', **env)
                self.assertNotEqual(result.returncode, 0)
                calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
                self.assertFalse(any(c[0] == 'pg_dump' and '--version' not in c for c in calls))

    def test_candidate_restore_really_connects_without_clean(self):
        result = self.run_client('restore-candidate')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        restore = next(c for c in calls if c[0] == 'pg_restore')
        self.assertIn('--dbname=service=momobox', restore)
        self.assertIn('--single-transaction', restore)
        self.assertNotIn('--clean', restore)
        self.assertNotIn('private', self.calls.read_text())

    def test_candidate_objects_or_other_clients_prevent_restore(self):
        for env in ({'OBJECTS': '1'}, {'CLIENTS': '1'}):
            with self.subTest(env=env):
                result = self.run_client('restore-candidate', **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('pg_restore', self.calls.read_text())

    def test_raw_connection_errors_remain_in_private_file(self):
        result = self.run_client('probe', QUERY_ERROR='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('private diagnostic', result.stderr + result.stdout)
        self.assertEqual((self.root / 'momo-pg-error').stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
