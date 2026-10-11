#!/usr/bin/env python3
"""Exercise the workflow's NAS packaging section, without Docker or release keys."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]


class NasReleaseAssetsTests(unittest.TestCase):
    def test_workflow_packages_pinned_templates_and_checksums(self):
        workflow = (ROOT / '.github/workflows/pipeline.yml').read_text()
        match = re.search(
            r'      - name: Build versioned Android packages\n(.*?)'
            r'\n      - name: Remove temporary Android signing material', workflow, re.DOTALL)
        self.assertIsNotNone(match, 'Expected release packaging step not found')
        run = match[1].split('        run: |\n', 1)[1]
        commands = textwrap.dedent(run)
        self.assertIn('mkdir -p dist\n', commands)
        commands = 'mkdir -p dist\n' + commands.split('mkdir -p dist\n', 1)[1]
        with tempfile.TemporaryDirectory(prefix='momobox-release-assets-') as temp:
            stage = Path(temp)
            shutil.copytree(ROOT / 'deploy/nas/variants', stage / 'deploy/nas/variants',
                            ignore=shutil.ignore_patterns('.env', 'backups'))
            for name in ('docker-compose.yaml', '.env.example'):
                shutil.copyfile(ROOT / 'deploy/nas' / name, stage / 'deploy/nas' / name)
            # Placeholder bytes test packaging only, never APK/AAB signing.
            for name in ('build/app/outputs/flutter-apk/app-release.apk',
                         'build/app/outputs/bundle/release/app-release.aab'):
                path = stage / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'packaging fixture only')
            env = dict(os.environ, VERSION='0.12.35', GITHUB_REPOSITORY_OWNER='DavisDing')
            subprocess.run(['bash', '-euo', 'pipefail', '-c', commands],
                           cwd=stage, env=env, check=True, capture_output=True, timeout=30)
            dist = stage / 'dist'
            expected = {'MomoBox-v0.12.35.apk', 'MomoBox-v0.12.35.aab',
                        'MomoBox-v0.12.35-docker-compose.yaml',
                        'MomoBox-v0.12.35-nas.env.example',
                        'MomoBox-v0.12.35-nas-variants-README.md', 'SHA256SUMS.txt'}
            for variant in ('with-postgres', 'external-postgres'):
                expected.add(f'MomoBox-v0.12.35-{variant}-docker-compose.yaml')
                expected.add(f'MomoBox-v0.12.35-{variant}.env.example')
            self.assertEqual({p.name for p in dist.iterdir()}, expected)
            for path in dist.glob('*.env.example'):
                self.assertIn('MOMO_BACKEND_IMAGE=ghcr.io/davisding/momobox-backend:v0.12.35',
                              path.read_text())
                self.assertIn('APP_VERSION=v0.12.35', path.read_text())
            for path in dist.glob('*docker-compose.yaml'):
                variant = next((v for v in ('with-postgres', 'external-postgres')
                                if v in path.name), None)
                source = (ROOT / 'deploy/nas/variants' / variant / 'docker-compose.yaml'
                          if variant else ROOT / 'deploy/nas/docker-compose.yaml')
                self.assertEqual(path.read_bytes(), source.read_bytes())
            self.assertEqual((dist / 'MomoBox-v0.12.35-nas-variants-README.md').read_bytes(),
                             (ROOT / 'deploy/nas/variants/README.md').read_bytes())
            sums = (dist / 'SHA256SUMS.txt').read_text().splitlines()
            self.assertEqual(len(sums), len(expected) - 1)
            for line in sums:
                digest, name = line.split('  ', 1)
                self.assertEqual(hashlib.sha256((stage / name).read_bytes()).hexdigest(), digest)
            # Every built file must also be included in the publication list.
            assets = re.search(r'          assets=\(\n(.*?)\n          \)', workflow, re.DOTALL)
            self.assertIsNotNone(assets)
            published = {line.strip().strip('"\'').removeprefix('dist/').replace('${VERSION}', '0.12.35')
                         for line in assets[1].splitlines()}
            self.assertEqual(published, expected)


if __name__ == '__main__':
    unittest.main()
