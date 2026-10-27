"""Regression test: Objective-C++ caller must link C-defined probe entry points.

An earlier v7.5 build failed because BTPSDaemonProbeStartV75 was declared
outside extern "C" in BTPSDaemonProbe.h; compilers accepted the source but
ld could not resolve the C++-mangled name against the actual C symbol.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CLinkageTests(unittest.TestCase):
    def test_both_daemon_entrypoints_resolve_from_cpp(self):
        cc = shutil.which('clang') or shutil.which('cc')
        cxx = shutil.which('clang++') or shutil.which('c++')
        if not cc or not cxx:
            self.skipTest('native C and C++ compilers unavailable')
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            c_source = td / 'provider.c'
            cpp_source = td / 'consumer.cpp'
            object_file = td / 'provider.o'
            executable = td / 'check_linkage'
            c_source.write_text('''#include "BTPSDaemonProbe.h"
void BTPSDaemonProbeStart(void) {}
void BTPSDaemonProbeStartV75(void) {}
''')
            cpp_source.write_text('''#include "BTPSDaemonProbe.h"
int main() {
    BTPSDaemonProbeStart();
    BTPSDaemonProbeStartV75();
    return 0;
}
''')
            subprocess.run([cc, '-std=c11', '-Wall', '-Werror', '-I', str(ROOT),
                            '-c', str(c_source), '-o', str(object_file)], check=True)
            subprocess.run([cxx, '-std=c++17', '-Wall', '-Werror', '-I', str(ROOT),
                            str(cpp_source), str(object_file), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_both_entrypoints_are_called_and_defined(self):
        tweak = (ROOT / 'Tweak.xm').read_text()
        code = (ROOT / 'BTPSDaemonProbe.c').read_text()
        for name in ('BTPSDaemonProbeStart', 'BTPSDaemonProbeStartV75'):
            self.assertIn(name + '();', tweak)
            self.assertIn('void ' + name + '(void)', code)


if __name__ == '__main__':
    unittest.main()
