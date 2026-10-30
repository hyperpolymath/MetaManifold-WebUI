#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Run: python3 -m unittest discover -s bench/null_calibration -p 'test_cluster_check.py'"""
import csv
import io
import unittest
from cluster_check import analyse_rows


class ClusterCheckTests(unittest.TestCase):
    FIELDS = "sim,test,taxon,status,pvalue,true_log2fc\n"

    def run_rows(self, content, **kwargs):
        return analyse_rows(csv.DictReader(io.StringIO(self.FIELDS + content)), **kwargs)

    def test_correlated_taxa_are_one_simulation_cluster(self):
        # Two simulations, two perfectly correlated taxa in each.
        data = ("1,wald_ml,1,ok,0.01,0\n1,wald_ml,2,ok,0.02,0\n"
                "2,wald_ml,1,ok,0.6,0\n2,wald_ml,2,ok,0.9,0\n")
        x = self.run_rows(data, min_clusters=2)[0]
        self.assertEqual((x["n_sims"], x["n_pvalues"], x["n_rejected"]), (2, 4, 2))
        self.assertAlmostEqual(x["rate"], 0.5)
        self.assertAlmostEqual(x["cluster_se"], 0.5)
        self.assertEqual((x["cluster_95_lo"], x["cluster_95_hi"]), (0.0, 1.0))

    def test_pooled_rate_weights_clusters_by_test_count(self):
        # One rejection in a one-taxon dataset; three valid non-rejections
        # in another dataset. Pooled rate = 1/4, not mean(1, 0) = 1/2.
        data = ("1,m,1,ok,0.01,0\n"
                "2,m,1,ok,0.6,0\n2,m,2,ok,0.9,0\n2,m,3,ok,0.7,0\n")
        x = self.run_rows(data, min_clusters=2)[0]
        self.assertEqual((x["n_sims"], x["n_pvalues"], x["n_rejected"]), (2, 4, 1))
        self.assertAlmostEqual(x["rate"], 0.25)
        self.assertNotAlmostEqual(x["rate"], 0.5)

    def test_failed_and_nonnull_excluded(self):
        data = ("1,m,1,ok,0.01,0\n1,m,2,failed,,0\n"
                "2,m,1,ok,0.02,1\n2,m,2,boundary,0.90,0\n")
        x = self.run_rows(data, min_clusters=2)[0]
        self.assertEqual((x["n_sims"], x["n_pvalues"], x["n_rejected"]), (2, 2, 1))

    def test_invalid_and_duplicate_refused(self):
        with self.assertRaisesRegex(ValueError, "missing or nonnumeric"):
            self.run_rows("1,m,1,ok,,0\n", min_clusters=2)
        with self.assertRaisesRegex(ValueError, "duplicated"):
            self.run_rows("1,m,1,ok,0.5,0\n1,m,1,ok,0.5,0\n", min_clusters=2)
        with self.assertRaisesRegex(ValueError, "independent simulation clusters"):
            self.run_rows("1,m,1,ok,0.5,0\n", min_clusters=30)

    def test_missing_taxon_column_and_identifier_refused(self):
        raw = csv.DictReader(io.StringIO(
            "sim,test,status,pvalue,true_log2fc\n1,m,ok,0.01,0\n"))
        with self.assertRaisesRegex(ValueError, "taxon"):
            analyse_rows(raw, min_clusters=2)
        with self.assertRaisesRegex(ValueError, "missing taxon identifier"):
            self.run_rows("1,m,,ok,0.01,0\n", min_clusters=2)

    def test_nonfinite_truth_refused(self):
        for value in ("nan", "inf", "-inf"):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, "non-finite true_log2fc"):
                    self.run_rows(f"1,m,1,ok,0.01,{value}\n", min_clusters=2)

    def test_no_null_method_and_empty_input_refused(self):
        with self.assertRaisesRegex(ValueError, "no null observations"):
            self.run_rows("1,m,1,ok,0.01,1\n", min_clusters=2)
        with self.assertRaisesRegex(ValueError, "no method records"):
            self.run_rows("", min_clusters=2)
        # Even with another sufficient method, the nonnull-only method
        # cannot silently disappear from the output.
        rows = ("1,m,1,ok,0.01,0\n2,m,1,ok,0.03,0\n"
                "1,other,1,ok,0.04,1\n")
        with self.assertRaisesRegex(ValueError, "other: no null observations"):
            self.run_rows(rows, min_clusters=2)

    def test_custom_alpha_is_in_machine_readable_output(self):
        from cluster_check import main
        from contextlib import redirect_stdout
        from pathlib import Path
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "pvalues_test.csv"
            path.write_text(self.FIELDS + "1,m,1,ok,0.08,0\n2,m,1,ok,0.5,0\n")
            output = io.StringIO()
            with redirect_stdout(output):
                main([str(path), "--alpha=0.1", "--min-clusters=2"])
            row = list(csv.DictReader(io.StringIO(output.getvalue())))[0]
            self.assertEqual(float(row["alpha"]), 0.1)
            self.assertEqual(int(row["n_rejected"]), 1)

    def test_reject_invalid_settings(self):
        data = "1,m,1,ok,0.5,0\n"
        with self.assertRaisesRegex(ValueError, "alpha"):
            self.run_rows(data, alpha=1, min_clusters=2)
        with self.assertRaisesRegex(ValueError, "at least two"):
            self.run_rows(data, min_clusters=1)


if __name__ == "__main__":
    unittest.main()
