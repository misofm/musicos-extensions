"""Compile-fail checks for the composition core's type-based authorization.

The pinned core binds a `CompositionAdminCap<CompositionShare>` to a
`Composition<CompositionShare>` by share type, so a cap with another share
type is rejected by the compiler rather than at runtime. This script proves
that for both write entry points.

Run with: python3 tests/check_cap_types.py
Requires sui on PATH (or `SUI=/path/to/sui`) and access to its dependency cache.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

PACKAGE = Path(__file__).resolve().parents[1]
SUI = os.environ.get("SUI", "sui")

for operation, args in (("set_title", ', b"Song".to_string()'), ("clear_title", "")):
    with tempfile.TemporaryDirectory(prefix="composition-title-cap-") as directory:
        root = Path(directory)
        shutil.copy(PACKAGE / "Move.toml", root / "Move.toml")
        shutil.copy(PACKAGE / "Move.lock", root / "Move.lock")
        shutil.copytree(PACKAGE / "sources", root / "sources")
        (root / "sources" / "wrong_cap.move").write_text(f'''module composition_title::wrong_cap;
use composition_title::composition_title;
use musicos::composition::{{Composition, CompositionAdminCap}};
public struct SongA has drop {{}}
public struct SongB has drop {{}}
public fun rejected(comp: &mut Composition<SongA>, cap: &CompositionAdminCap<SongB>) {{
    composition_title::{operation}(comp, cap{args});
}}
''')
        result = subprocess.run(
            [SUI, "move", "build", "--path", str(root)],
            capture_output=True, text=True,
        )
        output = result.stdout + result.stderr
        if result.returncode == 0 or not all(
            marker in output for marker in ("EC04007", "SongA", "SongB", "wrong_cap.move", "parameter 'cap'")
        ):
            raise SystemExit(f"Unexpected result for {operation}:\n{output}")
        print(f"PASS: {operation} rejects a capability with another share type")
