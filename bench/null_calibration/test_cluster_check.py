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

    def test_reject_invalid_settings(self):
        data = "1,m,1,ok,0.5,0\n"
        with self.assertRaisesRegex(ValueError, "alpha"):
            self.run_rows(data, alpha=1, min_clusters=2)
        with self.assertRaisesRegex(ValueError, "at least two"):
            self.run_rows(data, min_clusters=1)


if __name__ == "__main__":
    unittest.main()
