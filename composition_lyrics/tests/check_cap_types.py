"""Compile-fail checks for the composition core's type-based authorization.

Run with: python3 tests/check_cap_types.py
Requires sui on PATH and access to its dependency cache.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

PACKAGE = Path(__file__).resolve().parents[1]

for operation, args in (("set_lyrics", ', vector[1u8]'), ("clear_lyrics", '')):
    with tempfile.TemporaryDirectory(prefix="composition-lyrics-cap-") as directory:
        root = Path(directory)
        shutil.copy(PACKAGE / "Move.toml", root / "Move.toml")
        shutil.copy(PACKAGE / "Move.lock", root / "Move.lock")
        shutil.copytree(PACKAGE / "sources", root / "sources")
        (root / "sources" / "wrong_cap.move").write_text(f'''module composition_lyrics::wrong_cap;
use composition_lyrics::composition_lyrics;
use language_code::language_code;
use musicos::composition::{{Composition, CompositionAdminCap}};
public struct SongA has drop {{}}
public struct SongB has drop {{}}
public fun rejected(comp: &mut Composition<SongA>, cap: &CompositionAdminCap<SongB>) {{
    composition_lyrics::{operation}(comp, cap, language_code::new("en"){args});
}}
''')
        result = subprocess.run(
            ["sui", "move", "build", "--path", str(root)],
            capture_output=True, text=True,
        )
        output = result.stdout + result.stderr
        if result.returncode == 0 or not all(
            marker in output for marker in ("EC04007", "SongA", "SongB", "wrong_cap.move", "parameter 'cap'")
        ):
            raise SystemExit(f"Unexpected result for {operation}:\n{output}")
        print(f"PASS: {operation} rejects a capability with another share type")
