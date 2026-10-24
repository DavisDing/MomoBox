#!/usr/bin/env python3
"""Dependency-free signing control-flow tests, not real Android acceptance."""
import base64
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('signing', Path(__file__).with_name('android-release-signing.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


def jdk_available():
    try:
        return subprocess.run(['java', '-version'], capture_output=True, timeout=5).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False

KOTLIN = '''plugins { id("com.android.application") }
android {
    buildTypes {
        release {
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}
'''
GROOVY = '''android {
    buildTypes {
        release {
            signingConfig signingConfigs.debug
        }
    }
}
'''


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.app = self.root / 'android/app'
        self.app.mkdir(parents=True)
        self.gradle = self.app / 'build.gradle.kts'
        self.gradle.write_text(KOTLIN)
        self.cert = b'fixture certificate (not a real key)'
        self.pin = hashlib.sha256(self.cert).hexdigest()
        self.baseline = self.root / 'release-cert.sha256'
        self.baseline.write_text(self.pin + '\n')
        baseline_patch = patch.object(signing, 'RELEASE_CERTIFICATE', self.baseline)
        baseline_patch.start()
        self.addCleanup(baseline_patch.stop)
        self.env = dict(zip(signing.FIELDS, (base64.b64encode(b'fixture keystore').decode(),
                                           'store-secret', 'key-secret', 'fixture-alias', self.pin)))

    def tearDown(self):
        self.tmp.cleanup()

    def assert_no_material(self):
        self.assertFalse((self.root / 'android/.momo-release-signing').exists())

    def test_missing_each_field_and_partial_configuration(self):
        for field in signing.FIELDS:
            with self.subTest(field=field):
                env = dict(self.env)
                env.pop(field)
                with self.assertRaises(signing.SigningError): signing.prepare(self.root, env)
                self.assert_no_material()
                self.assertEqual(self.gradle.read_text(), KOTLIN)

    def test_invalid_base64_empty_oversize_and_fingerprint(self):
        cases = [('ANDROID_SIGNING_KEYSTORE_BASE64', '!malformed!'),
                 ('ANDROID_SIGNING_KEYSTORE_BASE64', ''),
                 ('ANDROID_SIGNING_KEYSTORE_BASE64', base64.b64encode(b'x' * (4 * 1024 * 1024 + 1)).decode()),
                 ('ANDROID_SIGNING_CERT_SHA256', 'abc')]
        for field, value in cases:
            with self.subTest(field=field, length=len(value)):
                env = dict(self.env, **{field: value})
                with self.assertRaises(signing.SigningError): signing.prepare(self.root, env)
                self.assert_no_material()

    def test_replacing_key_and_secret_pin_together_cannot_change_release_identity(self):
        new_cert = b'different certificate with its own matching secret pin'
        env = dict(self.env, ANDROID_SIGNING_CERT_SHA256=hashlib.sha256(new_cert).hexdigest(),
                   ANDROID_SIGNING_KEYSTORE_BASE64=base64.b64encode(b'different keystore').decode())
        with patch.object(signing, 'run', return_value=new_cert) as call:
            with self.assertRaisesRegex(signing.SigningError, 'committed release identity'):
                signing.prepare(self.root, env)
            # Check before even exporting a certificate or writing a key.
            call.assert_not_called()
        self.assert_no_material()
        self.assertEqual(self.gradle.read_text(), KOTLIN)

    def test_artifact_verification_also_rejects_replaced_secret_pin(self):
        env = dict(self.env, ANDROID_SIGNING_CERT_SHA256='0' * 64)
        with patch.object(signing, 'run') as call:
            for verify in (lambda: signing.verify(Path('a.apk'), Path('a.aab'), env, self.root),
                           lambda: signing.verify_aab(Path('a.aab'), env, self.root)):
                with self.assertRaisesRegex(signing.SigningError, 'committed release identity'):
                    verify()
            call.assert_not_called()

    def test_missing_invalid_or_unreadable_baseline_fails_closed(self):
        for value in (b'', b'0' * 63, b'0' * 64 + b'\n' + b'1' * 64, b'\xff'):
            with self.subTest(value=value):
                self.baseline.write_bytes(value)
                with self.assertRaisesRegex(signing.SigningError, 'invalid or unavailable'):
                    signing.prepare(self.root, self.env)
                self.assert_no_material()
                self.assertEqual(self.gradle.read_text(), KOTLIN)
        self.baseline.unlink()
        with self.assertRaisesRegex(signing.SigningError, 'invalid or unavailable'):
            signing.prepare(self.root, self.env)
        self.assert_no_material()

    def test_baseline_and_secret_allow_equivalent_fingerprint_formatting(self):
        self.baseline.write_text(':'.join(self.pin[i:i + 2] for i in range(0, 64, 2)).upper() + '\n')
        self.assertEqual(signing.release_pin(self.env), self.pin)
        self.assertEqual(signing.release_pin(dict(self.env, ANDROID_SIGNING_CERT_SHA256=self.pin.upper())), self.pin)

    def test_kotlin_and_groovy_patch_preserve_debug_and_original(self):
        for name, text in [('build.gradle.kts', KOTLIN), ('build.gradle', GROOVY)]:
            with self.subTest(name=name):
                self.gradle.unlink()
                self.gradle = self.app / name
                self.gradle.write_text(text)
                with patch.object(signing, 'run', return_value=self.cert):
                    signing.prepare(self.root, self.env)
                result = self.gradle.read_text()
                self.assertIn('momoRelease', result)
                self.assertIn('ANDROID_SIGNING_KEY_PASSWORD', result)
                for secret in ('store-secret', 'key-secret', 'fixture-alias'):
                    self.assertNotIn(secret, result)
                private = self.root / 'android/.momo-release-signing'
                self.assertEqual(private.stat().st_mode & 0o777, 0o700)
                self.assertEqual((private / 'release.keystore').stat().st_mode & 0o777, 0o600)
                signing.restore_and_cleanup(self.root)
                signing.restore_and_cleanup(self.root)
                self.assertEqual(self.gradle.read_text(), text)
                self.assert_no_material()

    def test_wrong_certificate_and_tool_failure_leave_source_unchanged(self):
        for result in ('wrong', 'failed'):
            with self.subTest(result=result):
                mock = dict(return_value=b'wrong') if result == 'wrong' else dict(side_effect=signing.SigningError('tool failed'))
                with patch.object(signing, 'run', **mock):
                    with self.assertRaises(signing.SigningError): signing.prepare(self.root, self.env)
                self.assertEqual(self.gradle.read_text(), KOTLIN)
                self.assert_no_material()

    def test_unknown_duplicate_and_repeated_templates_fail_closed(self):
        for text in (KOTLIN.replace('"debug"', '"unexpected"'),
                     KOTLIN + KOTLIN, KOTLIN + signing.MARKER, 'android {}'):
            with self.assertRaises(signing.SigningError): signing.patch_gradle(text, True)

    def test_symlink_directory_rejected(self):
        (self.root / 'android/.momo-release-signing').symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(signing.SigningError): signing.prepare(self.root, self.env)
        self.assertTrue(self.gradle.exists())

    def test_cleanup_removes_key_even_when_source_restore_fails(self):
        with patch.object(signing, 'run', return_value=self.cert):
            signing.prepare(self.root, self.env)
        original_write = Path.write_text
        def fail_gradle(path, *args, **kwargs):
            if path == self.gradle: raise OSError('fixture write failure')
            return original_write(path, *args, **kwargs)
        with patch.object(Path, 'write_text', fail_gradle):
            with self.assertRaises(OSError): signing.restore_and_cleanup(self.root)
        self.assert_no_material()

    def test_tool_errors_do_not_expose_output_or_password(self):
        failed = subprocess.CompletedProcess([], 1, stdout=b'store-secret', stderr=b'key-secret')
        with patch.object(signing.subprocess, 'run', return_value=failed) as call:
            with self.assertRaises(signing.SigningError) as caught:
                signing.run(['keytool', '-storepass:env', 'ANDROID_SIGNING_STORE_PASSWORD'], self.env)
        self.assertNotIn('store-secret', str(caught.exception))
        self.assertNotIn('key-secret', str(caught.exception))
        self.assertNotIn('store-secret', str(call.call_args.args))

    def sdk(self):
        tool = self.root / 'sdk/build-tools/37.0.0/apksigner'
        tool.parent.mkdir(parents=True)
        tool.write_text('mock')
        private = self.root / 'android/.momo-release-signing'
        private.mkdir()
        (private / 'release.keystore').write_bytes(b'mock validated key')
        return dict(self.env, ANDROID_HOME=str(self.root / 'sdk'))

    def test_actual_artifact_check_requires_matching_apk_and_aab(self):
        env = self.sdk()
        apk = ('Number of signers: 1\nSigner #1 certificate SHA-256 digest: ' + self.pin + '\n').encode()
        pem = b'Signer #1:\n-----BEGIN CERTIFICATE-----\n' + base64.b64encode(self.cert) + b'\n-----END CERTIFICATE-----'
        with patch.object(signing, 'run', side_effect=[apk, b'', pem]) as call:
            signing.verify(Path('release.apk'), Path('release.aab'), env, self.root)
            self.assertIn('-strict', call.call_args_list[1].args[0])

    def test_wrong_apk_multiple_signers_wrong_aab_and_unsigned_fail(self):
        env = self.sdk()
        apk = ('Number of signers: 1\nSigner #1 certificate SHA-256 digest: ' + self.pin + '\n').encode()
        wrong = b'Signer #1 certificate SHA-256 digest: ' + b'0' * 64 + b'\n'
        for output in (wrong, b'', apk + apk.replace(b'#1', b'#2')):
            with patch.object(signing, 'run', return_value=output):
                with self.assertRaises(signing.SigningError): signing.verify(Path('a'), Path('b'), env, self.root)
        with patch.object(signing, 'run', side_effect=[apk, b'', b'unsigned']):
            with self.assertRaises(signing.SigningError): signing.verify(Path('a'), Path('b'), env, self.root)
        pem = b'Signer #1:\n-----BEGIN CERTIFICATE-----\n' + base64.b64encode(self.cert) + b'\n-----END CERTIFICATE-----'
        with patch.object(signing, 'run', side_effect=[apk, b'', pem + b'\nSigner #2:\n' + pem]):
            with self.assertRaises(signing.SigningError): signing.verify(Path('a'), Path('b'), env, self.root)
        for status in (1, 4, 16, 32):
            with patch.object(signing.subprocess, 'run', return_value=subprocess.CompletedProcess([], status, b'', b'')):
                with self.assertRaises(signing.SigningError): signing.run(['jarsigner'], env)

    def test_apk_legacy_and_sdk_range_labels(self):
        for label in ('Signer #1',
                      'Signer (minSdkVersion=33, maxSdkVersion=2147483647)',
                      'Signer (minSdkVersion=33 (dev release=true), maxSdkVersion=2147483647)'):
            with self.subTest(label=label):
                output = ('Number of signers: 1\r\n' + label +
                          ' certificate SHA-256 digest: ' + self.pin.upper() + '\r\n')
                signing.verify_apk_certificate(output, self.pin)
        colon_pin = ':'.join(self.pin[index:index + 2] for index in range(0, len(self.pin), 2))
        signing.verify_apk_certificate(
            'Number of signers: 1\n'
            'Signer #1 certificate SHA-256 digest: ' + colon_pin + '\n', self.pin)
        for label in ('V2 Signer', 'V2 Signer #1', 'V3 Signer', 'V3 Signer #1',
                      'V3.0 Signer', 'V3.1 Signer', 'V4 Signer'):
            with self.subTest(label=label):
                signing.verify_apk_certificate(
                    'Number of signers: 1\n' + label +
                    ' certificate SHA-256 digest: ' + self.pin + '\n', self.pin)
                signing.verify_apk_certificate(
                    'Number of signers: 1\n' + label +
                    ': certificate SHA-256 digest: ' + self.pin + '\n', self.pin)
        scoped = ('Number of signers: 1\n'
                  'Signer (minSdkVersion=33, maxSdkVersion=2147483647) certificate SHA-256 digest: ' + self.pin + '\n'
                  'Signer (minSdkVersion=28, maxSdkVersion=32) certificate SHA-256 digest: ' + self.pin + '\n')
        signing.verify_apk_certificate(scoped, self.pin)
        signing.verify_apk_certificate(scoped + 'Source Stamp Signer certificate SHA-256 digest: ' + '0' * 64 + '\n', self.pin)

    def test_apk_all_ranges_must_match_and_unknown_output_fails_closed(self):
        line = 'Signer (minSdkVersion=33, maxSdkVersion=2147483647) certificate SHA-256 digest: ' + self.pin + '\n'
        good = 'Number of signers: 1\n' + line
        cases = (line, good.replace('signers: 1', 'signers: 2'),
                 good + 'Number of signers: 1\n',
                 good + line.replace('minSdkVersion=33', 'minSdkVersion=28').replace(self.pin, '0' * 64),
                 good + 'Signer #1 certificate SHA-256 digest: ' + self.pin + '\n',
                 good + 'V5 Signer certificate SHA-256 digest: ' + self.pin + '\n',
                 good.replace('Signer (', 'Unknown signer ('),
                 good.replace(self.pin, 'abc'),
                 'Number of signers: 1\nSource Stamp Signer certificate SHA-256 digest: ' + self.pin + '\n')
        for output in cases:
            with self.subTest(output=output):
                with self.assertRaises(signing.SigningError):
                    signing.verify_apk_certificate(output, self.pin)

    @unittest.skipUnless(jdk_available(), 'JDK unavailable; real keytool/jarsigner fixture NOT_EXECUTED')
    def test_real_ephemeral_jdk_signed_jar_and_tamper(self):
        # This key exists only in a temporary test directory, has no deployment
        # identity, and must never become the application's release key.
        fixture = self.root / 'fixture.p12'
        env = dict(os.environ, ANDROID_SIGNING_STORE_PASSWORD='test-only-password',
                   ANDROID_SIGNING_KEY_PASSWORD='test-only-password',
                   ANDROID_SIGNING_KEY_ALIAS='momo-ci-fixture')
        signing.run(['keytool', '-genkeypair', '-keystore', str(fixture), '-storetype', 'PKCS12',
                     '-alias', env['ANDROID_SIGNING_KEY_ALIAS'], '-keyalg', 'RSA', '-keysize', '2048',
                     '-validity', '30', '-dname', 'CN=MomoBoxIsolatedSigningTest',
                     '-storepass:env', 'ANDROID_SIGNING_STORE_PASSWORD',
                     '-keypass:env', 'ANDROID_SIGNING_KEY_PASSWORD', '-noprompt'], env)
        cert = signing.run(['keytool', '-exportcert', '-keystore', str(fixture),
                            '-alias', env['ANDROID_SIGNING_KEY_ALIAS'],
                            '-storepass:env', 'ANDROID_SIGNING_STORE_PASSWORD'], env)
        env['ANDROID_SIGNING_CERT_SHA256'] = hashlib.sha256(cert).hexdigest()
        env['ANDROID_SIGNING_KEYSTORE_BASE64'] = base64.b64encode(fixture.read_bytes()).decode()
        # Isolated fixture identity, never the committed production baseline.
        self.baseline.write_text(env['ANDROID_SIGNING_CERT_SHA256'] + '\n')
        signing.prepare(self.root, env)
        jar = self.root / 'signed-test.jar'
        with zipfile.ZipFile(jar, 'w') as archive:
            archive.writestr('payload.txt', 'isolated fixture')
        signing.run(['jarsigner', '-keystore', str(fixture),
                     '-storepass:env', 'ANDROID_SIGNING_STORE_PASSWORD',
                     '-keypass:env', 'ANDROID_SIGNING_KEY_PASSWORD',
                     str(jar), env['ANDROID_SIGNING_KEY_ALIAS']], env)
        signing.verify_aab(jar, env, self.root)
        # Optional CI integration: re-sign ONLY a temporary copy of the debug
        # APK. No production secret and no change to the uploaded debug artifact.
        apk_input = os.environ.get('MOMO_SIGNING_TEST_APK_PATH')
        if apk_input:
            sdk = Path(env.get('ANDROID_HOME') or env.get('ANDROID_SDK_ROOT') or '/nonexistent')
            tools = sorted((sdk / 'build-tools').glob('*/apksigner'),
                           key=lambda path: tuple(int(n) for n in signing.re.findall(r'\d+', path.parent.name)))
            self.assertTrue(tools, 'Required real Android signing tool unavailable')
            self.assertTrue(Path(apk_input).is_file(), 'Required CI debug APK fixture missing')
            apk = self.root / 'isolated-signed.apk'
            signing.run([str(tools[-1]), 'sign', '--ks', str(fixture),
                         '--ks-key-alias', env['ANDROID_SIGNING_KEY_ALIAS'],
                         '--ks-pass', 'env:ANDROID_SIGNING_STORE_PASSWORD',
                         '--key-pass', 'env:ANDROID_SIGNING_KEY_PASSWORD',
                         '--out', str(apk), apk_input], env)
            signing.verify(apk, jar, env, self.root)
            with self.assertRaises(signing.SigningError):
                signing.verify(apk, jar, dict(env, ANDROID_SIGNING_CERT_SHA256='0' * 64), self.root)
            with zipfile.ZipFile(apk, 'a') as archive:
                archive.writestr('unsigned.txt', 'must fail')
            with self.assertRaises(signing.SigningError):
                signing.verify(apk, jar, env, self.root)
        # An unsigned appended file must be rejected, not accepted as a trusted
        # self-signed-certificate warning or a partial signed artifact.
        with zipfile.ZipFile(jar, 'a') as archive:
            archive.writestr('unsigned.txt', 'must fail')
        with self.assertRaises(signing.SigningError): signing.verify_aab(jar, env, self.root)
        signing.restore_and_cleanup(self.root)
        self.assert_no_material()


if __name__ == '__main__':
    unittest.main()
