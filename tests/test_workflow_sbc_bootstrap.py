"""Regression for v7.6 CI: dependency fetch must precede Theos build.

The workflow at .github/workflows/build.yml is authoritative. A similarly
named file in the repository root does NOT run under GitHub Actions.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github' / 'workflows' / 'build.yml'

class BuildDependencyBootstrap(unittest.TestCase):
    def test_correct_workflow_exists(self):
        self.assertTrue(WORKFLOW.is_file())

    def test_decoder_fetch_before_tests_before_make(self):
        text = WORKFLOW.read_text()
        fetch = text.index('bash tools/fetch_google_sbc.sh')
        tests = text.index('python3 -m unittest discover -s tests -v')
        build = text.index('make clean package FINALPACKAGE=1')
        self.assertLess(fetch, tests)
        self.assertLess(tests, build)

    def test_required_decoder_sources_checked_before_build(self):
        text = WORKFLOW.read_text()
        for name in ('sbc.c', 'bits.c', 'sbc.h', 'bits.h', 'LICENSE', 'UPSTREAM_COMMIT'):
            self.assertIn(name, text)
        self.assertIn('BTPSAudioHelper missing from the .deb', text)

    def test_upstream_commit_pinned(self):
        fetch = (ROOT / 'tools' / 'fetch_google_sbc.sh').read_text()
        self.assertIn('6e505650145c9973d08a0bdd5e5f5e1914305e40', fetch)
        self.assertIn('git -C "$work/src" fetch', fetch)

if __name__ == '__main__':
    unittest.main()
