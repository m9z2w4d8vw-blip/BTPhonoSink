"""Repository layout guards: keep the structure described in README.md ("Repository layout") true.

Browser uploads sometimes drop a file's folder and put it at the root, or add a " (1)" duplicate. That is how
25 stale copies and leftovers had accumulated by v8.9.4. These checks turn each of those mistakes into a CI
failure with an explanation, instead of clutter that nobody notices.
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SUBPROJECTS = ("btpsaudiohelper", "btphonosinkprefs")
FETCHED_AT_BUILD = {"btpsaudiohelper/vendor_sbc/sbc.c", "btpsaudiohelper/vendor_sbc/bits.c"}  # tools/fetch_google_sbc.sh
SKIP_DIRS = {".git", ".theos", "packages", "obj", "__pycache__"}
SOURCE_SUFFIXES = {".c", ".h", ".m", ".mm", ".xm"}


def makefile_inputs(makefile):
    text = makefile.read_text().replace("\\\n", " ")
    files = []
    for match in re.finditer(r"^\s*\w+_FILES\s*[:+]?=\s*(.+)$", text, re.M):
        files += match.group(1).split()
    return files


def repo_files():
    for path in ROOT.rglob("*"):
        if path.is_file() and not SKIP_DIRS.intersection(path.relative_to(ROOT).parts):
            yield path


class RepoLayout(unittest.TestCase):
    def test_every_build_input_exists(self):
        top = (ROOT / "Makefile").read_text()
        for makefile in [ROOT / "Makefile"] + [ROOT / sub / "Makefile" for sub in SUBPROJECTS]:
            inputs = makefile_inputs(makefile)
            self.assertTrue(inputs, f"no *_FILES found in {makefile.relative_to(ROOT)}")
            for name in inputs:
                path = makefile.parent / name
                rel = path.relative_to(ROOT).as_posix()
                if rel not in FETCHED_AT_BUILD:
                    self.assertTrue(path.is_file(), f"{makefile.relative_to(ROOT)} compiles {rel}, which is missing")
        for sub in SUBPROJECTS:
            self.assertIn(f"SUBPROJECTS += {sub}", top)

    def test_shared_sources_exist_once_at_the_root(self):
        root_files = {path.name for path in ROOT.iterdir() if path.is_file()}
        for sub in SUBPROJECTS:
            for path in sorted((ROOT / sub).iterdir()):
                if not path.is_file() or path.name == "Makefile" or path.name not in root_files:
                    continue
                code = [line for line in path.read_text().splitlines()
                        if line.strip() and not line.lstrip().startswith("/*")]
                self.assertEqual(code, [f'#include "../{path.name}"'],
                                 f"{path.name} exists both at the root and in {sub}/. If the root copy is a misplaced "
                                 f"upload, delete it; if the file is shared, make {sub}/{path.name} a one-line "
                                 f'#include "../{path.name}" like the other shared sources.')

    def test_root_holds_only_build_inputs(self):
        allowed = {"Makefile", "control", "BTPhonoSink.plist", "README.md", ".gitignore"}
        for path in ROOT.iterdir():
            if path.is_dir() or path.name in allowed or path.suffix in SOURCE_SUFFIXES:
                continue
            if path.name.startswith(("LICENSE", "CHANGELOG", ".gitattributes")):
                continue
            self.fail(f"{path.name} is at the repository root: notes go in docs/, scripts in tools/, tests in tests/")

    def test_every_root_source_is_used(self):
        """A root source must be compiled by a Makefile, included by another file, or read by a test."""
        compiled = set(makefile_inputs(ROOT / "Makefile"))
        included, tested = set(), ""
        for path in repo_files():
            if path.suffix in SOURCE_SUFFIXES:
                included |= {pathlib.PurePosixPath(name).name for name in
                             re.findall(r'^\s*#\s*(?:include|import)\s+"([^"]+)"', path.read_text(errors="replace"), re.M)}
        for path in (ROOT / "tests").glob("*.py"):
            tested += path.read_text()
        for path in ROOT.iterdir():
            if path.is_file() and path.suffix in SOURCE_SUFFIXES:
                self.assertTrue(path.name in compiled or path.name in included or f"'{path.name}'" in tested,
                                f"{path.name} at the root is not compiled, included or tested: remove it")

    def test_no_browser_duplicate_uploads(self):
        for path in repo_files():
            self.assertIsNone(re.search(r" \(\d+\)(\.|$)", path.name),
                              f"{path.relative_to(ROOT)} looks like a duplicate upload")

    def test_release_notes_live_in_docs_history_and_are_indexed(self):
        stray = [path.relative_to(ROOT).as_posix() for path in repo_files()
                 if re.match(r"(TESTING|PROVENANCE)-v.*\.md$", path.name) and path.parent != ROOT / "docs" / "history"]
        self.assertEqual(stray, [], "release notes belong in docs/history/")
        readme = (ROOT / "README.md").read_text()
        for path in sorted((ROOT / "docs" / "history").glob("*.md")):
            self.assertIn(f"docs/history/{path.name}", readme, f"README's version history does not link {path.name}")
        for path in sorted((ROOT / "docs" / "research").glob("*.md")):
            self.assertIn(f"docs/research/{path.name}", readme, f"README does not link {path.name}")

    def test_readme_links_resolve(self):
        readme = (ROOT / "README.md").read_text()
        targets = re.findall(r"\]\(([^)\s#]+)(?:#[^)]*)?\)", readme)
        self.assertGreater(len(targets), 20)
        for target in targets:
            if re.match(r"[a-z]+:", target):
                continue
            self.assertTrue((ROOT / target).exists(), f"README links to {target}, which does not exist")


if __name__ == "__main__":
    unittest.main()
