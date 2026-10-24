# SPDX-License-Identifier: MPL-2.0
"""CSV parsing and annotation escaping for null-calibration package failures."""
import csv
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "bench/null_calibration"))
from report_failures import LEGACY_FIELDS, RESULT_FIELDS, failure_annotations


class FailureAnnotationTests(unittest.TestCase):
    def write_rows(self, path, fields, rows):
        with path.open("w", encoding="utf-8", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=fields, lineterminator="\n")
            writer.writeheader()
            writer.writerows(
                {field: row.get(field) for field in fields} for row in rows
            )

    def row(self, *, test, status, note=None):
        return {
            "truth": "null",
            "shape": "original",
            "offset": "tss",
            "n_per": 4,
            "taxa": 40,
            "sim": 1,
            "taxon": 1,
            "true_log2fc": 0,
            "test": test,
            "status": status,
            "pvalue": "NA" if status == "failed" else 0.01,
            "note": note,
        }

    def test_distinct_failures_are_csv_aware_deduplicated_and_escaped(self):
        note_one = 'comma, quote " and newline\ncontinued'
        note_two = "second 50% and carriage\rreturn\ncontinued"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pvalues_smoke.csv"
            self.write_rows(
                path,
                RESULT_FIELDS,
                [
                    self.row(test="duplicate_test", status="failed", note=note_one),
                    self.row(test="duplicate_test", status="failed", note=note_one),
                    self.row(test="duplicate_test", status="failed", note=note_two),
                    self.row(test="missing_note", status="failed", note="NA"),
                    self.row(test="ok_test", status="ok"),
                ],
            )
            cell = "null_original_tss_n4_t40_smoke"
            self.assertEqual(
                failure_annotations(path, cell),
                [
                    f"::warning title={cell}: a requested test failed::duplicate_test :: "
                    'comma, quote " and newline%0Acontinued',
                    f"::warning title={cell}: a requested test failed::duplicate_test :: "
                    "second 50%25 and carriage%0Dreturn%0Acontinued",
                ],
            )

    def test_legacy_header_without_notes_and_missing_note_are_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "legacy.csv"
            self.write_rows(
                path,
                LEGACY_FIELDS,
                [self.row(test="old_test", status="failed")],
            )
            self.assertEqual(failure_annotations(path, "legacy_cell"), [])

    def test_extra_csv_field_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "malformed.csv"
            path.write_text(
                ",".join(RESULT_FIELDS) + "\n"
                + "null,original,tss,4,40,1,1,0,edger_ql,failed,NA,reason,extra\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "malformed CSV record"):
                failure_annotations(path, "bad_cell")


if __name__ == "__main__":
    unittest.main()
