import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def test_selfcheck_imports_everything_a_run_needs():
    done = subprocess.run([sys.executable, str(ROOT / "translate_book.py"), "--selfcheck"],
                          capture_output=True, text=True, timeout=120)
    assert done.returncode == 0, done.stderr
    assert "selfcheck ok" in done.stdout


def test_selfcheck_fails_when_a_module_is_missing(tmp_path):
    """The Mac app bundles translate_book.py, translate.py and src/: without translate.py it must fail loudly."""
    import shutil
    shutil.copy(ROOT / "translate_book.py", tmp_path / "translate_book.py")
    shutil.copytree(ROOT / "src", tmp_path / "src", ignore=shutil.ignore_patterns("__pycache__"))
    done = subprocess.run([sys.executable, str(tmp_path / "translate_book.py"), "--selfcheck"],
                          capture_output=True, text=True, cwd=tmp_path, timeout=120)
    assert done.returncode == 1 and "translate:" in done.stderr
