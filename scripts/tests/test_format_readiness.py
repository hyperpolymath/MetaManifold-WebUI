# SPDX-License-Identifier: MPL-2.0
"""Tests of the harness itself; fake children are NOT parser conformance evidence."""
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/formats"))
from conformance import check, load_cases, main as conformance_main
from inventory import inventory
from process import ToolError, run
from probe_kyq import main as probe_main


class ProcessTests(unittest.TestCase):
    def test_round_trip_binary_io(self):
        raw = bytes(range(256)) * 200
        result = run([sys.executable, "-c", "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())"], raw)
        self.assertEqual((result.code, result.stdout, result.stderr), (0, raw, b""))

    def test_stderr_separate_and_exit_preserved(self):
        result = run([sys.executable, "-c", "import sys; sys.stderr.write('private'); sys.exit(7)"])
        self.assertEqual((result.code, result.stdout, result.stderr), (7, b"", b"private"))

    def test_missing_binary_is_infrastructure_not_document_rejection(self):
        with self.assertRaises(ToolError):
            run(["/nonexistent/format-tool"])

    def test_timeout(self):
        with self.assertRaisesRegex(ToolError, "time budget"):
            run([sys.executable, "-c", "import time; time.sleep(10)"], timeout=0.15)

    def test_output_budget_covers_both_streams(self):
        with self.assertRaisesRegex(ToolError, "output budget"):
            run([sys.executable, "-c", "import sys; sys.stderr.write('x' * 10000)"], limit=100)

    def test_input_and_deadline_budgets(self):
        for kwargs in ({"timeout": 0}, {"timeout": float("nan")}, {"timeout": float("inf")}, {"limit": 0}, {"data": b"xx", "limit": 1}):
            with self.assertRaises(ToolError):
                run([sys.executable, "-c", "pass"], **kwargs)

    def test_descendant_keeping_pipe_open_is_bounded(self):
        with self.assertRaisesRegex(ToolError, "time budget"):
            run([sys.executable, "-c", "import os,time; p=os.fork(); time.sleep(10) if p==0 else None"], timeout=0.2)


class CorpusTests(unittest.TestCase):
    def test_raw_fixtures_survive_loading(self):
        cases = list(load_cases(ROOT / "test/fixtures/formats/ijson-jcs.toml"))
        self.assertGreaterEqual(len(cases), 30)
        by_id = {c[0]: c for c in cases}
        self.assertEqual(by_id["invalid-utf8"][1], b'["\xff"]')
        self.assertEqual(by_id["escaped-equivalent-key"][1], b'{"a":1,"\\u0061":2}')
        self.assertEqual(by_id["exponent-thresholds"][3], b'[0.000001,1e-7,1e+21]')

    def test_bad_and_ambiguous_corpora_fail_before_running_tools(self):
        for contents in (
            "schema=2\ncase=[]\n", "schema=1\ncase=[]\n",
            "schema=1\n[[case]]\nid='a'\ninput='{}'\nvalid=true\n",
            "schema=1\n[[case]]\nid='a'\ninput='{}'\nhex='ff'\nvalid=false\n",
            "schema=1\n[[case]]\nid='a'\ninput='{}'\nvalid='false'\n",
            "schema=1\n[[case]]\nid='a'\ninput='{}'\nvalid=false\nunknown=1\n",
            "schema=1\n[[case]]\nid='a'\nhex='not-hex'\nvalid=false\n",
        ):
            with self.subTest(contents=contents), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "cases.toml"
                path.write_text(contents)
                with self.assertRaises((ValueError, TypeError)):
                    list(load_cases(path))

    def test_duplicate_ids_fail(self):
        case = "\n[[case]]\nid='a'\ninput='{}'\nvalid=false\n"
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "cases.toml"
            path.write_text("schema=1\n" + case * 2)
            with self.assertRaises(ValueError):
                list(load_cases(path))

    def fake(self, directory, body):
        path = Path(directory) / "tool with spaces"
        path.write_text(f"#!{sys.executable}\n{body}\n")
        path.chmod(0o700)
        return str(path)

    def test_mutants_cannot_pass_as_canonicalizers(self):
        cases = [("valid", b' {"a":1} ', True, b'{"a":1}'),
                 ("invalid", b'{"a":1,"a":2}', False, b'')]
        # Always-success, always-invalid, crashes, and passthrough all fail.
        for body in ("raise SystemExit(0)", "raise SystemExit(2)",
                     "raise SystemExit(1)", "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())"):
            with self.subTest(body=body), tempfile.TemporaryDirectory() as tmp:
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertFalse(check(self.fake(tmp, body), cases))

    def test_correct_adapter_protocol_passes_and_redacts_diagnostics(self):
        cases = [("valid", b"true", True, b"true"), ("invalid", b"broken", False, b"")]
        body = """import sys
raw = sys.stdin.buffer.read()
if raw == b'true':
    sys.stdout.buffer.write(raw)
else:
    sys.stderr.write('private input')
    raise SystemExit(2)
"""
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertTrue(check(self.fake(tmp, body), cases))
        self.assertNotIn("private input", out.getvalue())

    def test_exact_bytes_no_newline_or_wrong_order(self):
        cases = [("order", b'{}', True, b'{"a":1,"z":2}')]
        for output in (b'{"z":2,"a":1}', b'{"a":1,"z":2}\n'):
            with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
                executable = self.fake(tmp, f"import sys; sys.stdout.buffer.write({output!r})")
                self.assertFalse(check(executable, cases))

    def test_missing_tool_cli_fails_closed_without_echoing_input(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = conformance_main(["--tool", "/nonexistent/format-tool"])
        self.assertEqual(code, 2)
        self.assertIn("no conformance pass", err.getvalue())
        self.assertNotIn("9007199254740992", out.getvalue() + err.getvalue())

    def test_kyq_probe_missing_source_is_not_a_pass(self):
        with contextlib.redirect_stderr(io.StringIO()):
            code = probe_main(["--source", "/nonexistent/kyq"])
        self.assertEqual(code, 2)


class InventoryTests(unittest.TestCase):
    def test_inventory_covers_hidden_new_files_and_never_echoes_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(["git", "init", "-q", tmp], check=True)
            (root / ".github/workflows").mkdir(parents=True)
            (root / ".github/workflows/probe.yml").write_text('name: "private-value"\n')
            (root / "client.ts").write_text('res.json();\nJSON.parse("private-value")\n')
            (root / "foreign.json").symlink_to("/etc/passwd")
            (root / ".gitignore").write_text('ignored.py\n')
            (root / "ignored.py").write_text('json.loads("ignore")')
            rows = list(inventory(root))
            self.assertTrue(any(r[2] == ".github/workflows/probe.yml" for r in rows))
            self.assertTrue(any(r[0] == "symlink" and r[2] == "foreign.json" for r in rows))
            self.assertTrue(any(r[3] == 2 and r[4] == "JSON.parse" for r in rows))
            self.assertFalse(any(r[2] == "ignored.py" for r in rows))
            self.assertNotIn("private-value", repr(rows))


if __name__ == "__main__":
    unittest.main()
