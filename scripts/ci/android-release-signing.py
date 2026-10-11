#!/usr/bin/env python3
"""Fail-closed signing setup/checks. Never print tool output or secret values."""
import argparse
import base64
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


FIELDS = (
    'ANDROID_SIGNING_KEYSTORE_BASE64', 'ANDROID_SIGNING_STORE_PASSWORD',
    'ANDROID_SIGNING_KEY_PASSWORD', 'ANDROID_SIGNING_KEY_ALIAS',
    'ANDROID_SIGNING_CERT_SHA256',
)
MARKER = '// MomoBox fixed release signing'


class SigningError(Exception):
    pass


def fingerprint(value):
    result = value.replace(':', '').strip().lower()
    if not re.fullmatch(r'[0-9a-f]{64}', result):
        raise SigningError('Signing certificate SHA-256 must contain exactly 64 hex digits.')
    return result


def config(env):
    missing = [key for key in FIELDS if not env.get(key)]
    if missing:
        raise SigningError('Missing required signing configuration: ' + ', '.join(missing))
    pin = fingerprint(env['ANDROID_SIGNING_CERT_SHA256'])
    try:
        key = base64.b64decode(env['ANDROID_SIGNING_KEYSTORE_BASE64'], validate=True)
    except (ValueError, base64.binascii.Error):
        raise SigningError('Signing keystore is not valid base64.') from None
    if not key or len(key) > 4 * 1024 * 1024:
        raise SigningError('Signing keystore is empty or exceeds the 4 MiB limit.')
    return key, pin


def run(command, env, accepted=(0,)):
    try:
        result = subprocess.run(command, env=env, capture_output=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        raise SigningError('Required signing tool is unavailable or timed out.') from None
    if result.returncode not in accepted:
        raise SigningError('Signing tool validation failed; verify the key, alias, passwords and artifact.')
    return result.stdout


def paths(root):
    android = root / 'android'
    private = android / '.momo-release-signing'
    if android.is_symlink() or private.is_symlink():
        raise SigningError('Refusing symlinked signing directories.')
    return android, private


def patch_gradle(text, kotlin):
    if MARKER in text:
        raise SigningError('Signing patch is already present; regenerate the platform shell before setup.')
    if kotlin:
        pattern = r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)'
        replacement = 'signingConfig = signingConfigs.getByName("momoRelease")'
        signing = '''
    signingConfigs {
        create("momoRelease") {
            storeFile = rootProject.file(".momo-release-signing/release.keystore")
            storePassword = System.getenv("ANDROID_SIGNING_STORE_PASSWORD")
            keyAlias = System.getenv("ANDROID_SIGNING_KEY_ALIAS")
            keyPassword = System.getenv("ANDROID_SIGNING_KEY_PASSWORD")
        }
    }
'''
    else:
        pattern = r'signingConfig\s*(?:=\s*)?signingConfigs\.debug\b'
        replacement = 'signingConfig signingConfigs.momoRelease'
        signing = '''
    signingConfigs {
        momoRelease {
            storeFile rootProject.file('.momo-release-signing/release.keystore')
            storePassword System.getenv('ANDROID_SIGNING_STORE_PASSWORD')
            keyAlias System.getenv('ANDROID_SIGNING_KEY_ALIAS')
            keyPassword System.getenv('ANDROID_SIGNING_KEY_PASSWORD')
        }
    }
'''
    # Only patch the single known generated release block. Unexpected templates
    # must fail rather than guessing or changing a debug build's signing.
    release = re.search(r'\brelease\s*\{[^{}]*\}', text)
    if not release:
        raise SigningError('Generated release Gradle block is not recognized.')
    block, count = re.subn(pattern, replacement, release.group())
    if count != 1:
        raise SigningError('Expected exactly one generated debug signing assignment in release.')
    text = text[:release.start()] + block + text[release.end():]
    text, count = re.subn(r'(?m)^(\s*)buildTypes\s*\{', MARKER + signing + r'\1buildTypes {', text)
    if count != 1:
        raise SigningError('Generated buildTypes block is not recognized.')
    return text


def cleanup(root):
    _, private = paths(root)
    if private.exists():
        shutil.rmtree(private)


def prepare(root, env):
    key, pin = config(env)
    android, private = paths(root)
    candidates = [path for path in (android / 'app/build.gradle.kts', android / 'app/build.gradle') if path.is_file()]
    if len(candidates) != 1 or candidates[0].is_symlink():
        raise SigningError('Expected one regular generated Android Gradle file.')
    gradle = candidates[0]
    original = gradle.read_text()
    patched = patch_gradle(original, gradle.suffix == '.kts')
    if private.exists():
        raise SigningError('Signing directory already exists; clean up the previous setup first.')
    private.mkdir(mode=0o700)
    try:
        key_file = private / 'release.keystore'
        fd = os.open(str(key_file), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(key)
        cert = run(['keytool', '-exportcert', '-keystore', str(key_file),
                    '-alias', env['ANDROID_SIGNING_KEY_ALIAS'],
                    '-storepass:env', 'ANDROID_SIGNING_STORE_PASSWORD'], env)
        if hashlib.sha256(cert).hexdigest() != pin:
            raise SigningError('Keystore certificate does not match the pinned SHA-256.')
        # Retain a non-secret source backup solely for cleanup of the patch.
        (private / 'original-gradle').write_text(original)
        (private / 'gradle-name').write_text(gradle.name)
        gradle.write_text(patched)
    except BaseException:
        restore_and_cleanup(root)
        raise


def restore_and_cleanup(root):
    android, private = paths(root)
    if private.exists():
        try:
            name = private / 'gradle-name'
            original = private / 'original-gradle'
            if name.is_file() and original.is_file():
                filename = name.read_text()
                if filename not in ('build.gradle', 'build.gradle.kts'):
                    raise SigningError('Signing cleanup metadata is invalid.')
                target = android / 'app' / filename
                if target.is_symlink():
                    raise SigningError('Refusing symlinked Gradle cleanup target.')
                target.write_text(original.read_text())
        finally:
            # Source restoration failure must not retain the private key.
            cleanup(root)


def verify_apk_certificate(output, pin):
    # apksigner uses SDK-range labels for v3.1 instead of numbered labels.
    # Require one effective signer AND pin every scheme's certificate: merely
    # finding one matching digest would accept a different rotation certificate.
    lines = output.splitlines()
    counts = [match[1] for line in lines
              if (match := re.fullmatch(r'Number of signers:[ \t]*(\d+)[ \t]*', line))]
    if counts != ['1']:
        raise SigningError('APK verification must report exactly one effective signer.')
    digests = []
    numbered = []
    for line in lines:
        if ' certificate SHA-256 digest:' not in line:
            continue
        if line.startswith('Source Stamp Signer certificate SHA-256 digest:'):
            continue  # A source stamp is not the application signing identity.
        match = re.fullmatch(
            r'(Signer #([1-9]\d*)|Signer \(minSdkVersion=\d+'
            r'(?: \(dev release=true\))?, maxSdkVersion=\d+\))'
            r' certificate SHA-256 digest:[ \t]*([0-9a-fA-F]{64})[ \t]*', line)
        if not match:
            raise SigningError('APK signer certificate output format is not recognized.')
        if match[2]:
            numbered.append(match[2])
        digests.append(match[3].lower())
    if not digests:
        raise SigningError('APK verification did not report a signer certificate SHA-256.')
    if numbered and (numbered != ['1'] or len(digests) != 1):
        raise SigningError('APK verification reported ambiguous or multiple signer certificates.')
    if any(digest != pin for digest in digests):
        raise SigningError('APK signer certificate does not match the pinned SHA-256.')


def verify(apk, aab, env, root=None):
    pin = fingerprint(env.get('ANDROID_SIGNING_CERT_SHA256', ''))
    sdk = Path(env.get('ANDROID_HOME') or env.get('ANDROID_SDK_ROOT') or '/nonexistent')
    tools = sorted((sdk / 'build-tools').glob('*/apksigner'), key=lambda path: tuple(int(n) for n in re.findall(r'\d+', path.parent.name)))
    if not tools:
        raise SigningError('Android apksigner is unavailable.')
    output = run([str(tools[-1]), 'verify', '--verbose', '--print-certs', str(apk)], env).decode('utf-8', errors='replace')
    verify_apk_certificate(output, pin)
    verify_aab(aab, env, root)


def verify_aab(aab, env, root=None):
    pin = fingerprint(env.get('ANDROID_SIGNING_CERT_SHA256', ''))
    _, private = paths(root or Path.cwd())
    key_file = private / 'release.keystore'
    if not key_file.is_file() or key_file.is_symlink():
        raise SigningError('Validated release keystore is missing for AAB verification.')
    # Trust only the already pinned key/alias. Do NOT blanket-accept status 4:
    # that status also includes expiry and disabled algorithms, not just trust.
    run(['jarsigner', '-J-Duser.language=en', '-verify', '-strict',
         '-keystore', str(key_file), '-storepass:env', 'ANDROID_SIGNING_STORE_PASSWORD',
         str(aab), env['ANDROID_SIGNING_KEY_ALIAS']], env)
    output = run(['keytool', '-J-Duser.language=en', '-printcert', '-jarfile', str(aab), '-rfc'], env).decode('ascii', errors='replace')
    if len(re.findall(r'^Signer #\d+:', output, re.MULTILINE)) != 1:
        raise SigningError('Expected exactly one AAB signer.')
    certificates = re.findall(r'-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----', output, re.DOTALL)
    if not certificates or hashlib.sha256(base64.b64decode(''.join(certificates[0].split()))).hexdigest() != pin:
        raise SigningError('AAB signer certificate does not match the pinned SHA-256.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'cleanup', 'verify'))
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--apk', type=Path)
    parser.add_argument('--aab', type=Path)
    args = parser.parse_args()
    try:
        if args.action == 'prepare':
            prepare(args.root.resolve(), os.environ)
        elif args.action == 'cleanup':
            restore_and_cleanup(args.root.resolve())
        else:
            if not args.apk or not args.aab:
                raise SigningError('Both APK and AAB paths are required.')
            verify(args.apk, args.aab, os.environ, args.root.resolve())
    except SigningError as error:
        print(str(error), file=sys.stderr)
        return 1
    print('Signing ' + args.action + ' completed.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
