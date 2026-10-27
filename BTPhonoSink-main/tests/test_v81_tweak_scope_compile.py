"""Regression for v8.1 CI failure: a getter-hook guard was copied into v7.8.

The v7.8 capacity inspector verifies only register-prologue code that is not
hooked.  The v7.9 geometry inspector *does* inspect the getter entry, so it
needs the post-hook signature exception, declared in the proper C++ scope.
"""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT.joinpath('Tweak.xm').read_text(encoding='utf-8')


def function_block(start, stop):
    a = SOURCE.index(start)
    b = SOURCE.index(stop, a)
    return SOURCE[a:b]


class TweakScopeTests(unittest.TestCase):
    def test_capacity_audit_has_no_config_getter_guard(self):
        body = function_block('static int btps_v78_signature_matches(void)',
                              'static void btps_v78_snapshot_capacity(void)')
        self.assertNotIn('g_v80_enabled_for_v79_audit', body)
        self.assertNotIn('g_v81_verified_initial_signature', body)
        self.assertNotIn('0x1f5f20u', body)
        self.assertIn('0x0cee60u', body)

    def test_allocator_audit_retains_original_getter_guard(self):
        body = function_block('static int btps_v79_signatures_match(void)',
                              'static void btps_v79_snapshot_geometry(void)')
        self.assertIn('g_v80_enabled_for_v79_audit()', body)
        self.assertIn('g_v81_verified_initial_signature', body)
        self.assertIn('s[i].offset == 0x1f5f20u', body)
        self.assertLess(SOURCE.index('static int g_v80_enabled_for_v79_audit(void);'),
                        SOURCE.index('static int btps_v79_signatures_match(void)'))
        self.assertLess(SOURCE.index('static int g_v81_verified_initial_signature = 0;'),
                        SOURCE.index('static int btps_v79_signatures_match(void)'))

    def test_capacity_function_compiles_as_cpp(self):
        compiler = shutil.which('clang++') or shutil.which('c++')
        self.assertIsNotNone(compiler, 'Host C++ compiler required to detect scope errors')
        func = function_block('static int btps_v78_signature_matches(void)',
                              'static void btps_v78_snapshot_capacity(void)')
        skeleton = '''#include <cstdint>\n#include <cstddef>\n'''
        skeleton += '''static int g_v78_exact_uuid=1;\nstatic uintptr_t g_v78_base=0;\nstatic int btps_peek(uint64_t, void*, size_t) { return 1; }\n'''
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp, 'capacity_probe.cpp')
            path.write_text(skeleton + func, encoding='utf-8')
            result = subprocess.run([compiler, '-std=c++17', '-fsyntax-only',
                                     '-Werror', str(path)], capture_output=True,
                                    text=True)
            self.assertEqual(result.returncode, 0,
                             'The v7.8 capacity function failed to compile: ' + result.stderr)


if __name__ == '__main__':
    unittest.main()
