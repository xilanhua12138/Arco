import unittest

from tools.perf.arco_perf_probe import (
    percentile,
    summarize_gpu_samples,
    summarize_intervals,
    summarize_process_samples,
)


class ArcoPerfStatisticsTests(unittest.TestCase):
    def test_percentile_uses_nearest_rank_and_rejects_empty_samples(self):
        self.assertEqual(percentile([1.0, 2.0, 3.0, 100.0], 0.95), 100.0)
        self.assertIsNone(percentile([], 0.95))

    def test_display_summary_learns_a_120_hz_baseline(self):
        intervals = [8.2, 8.3, 8.4, 8.3, 8.2, 8.4, 8.3, 17.1]

        summary = summarize_intervals(intervals, stall_threshold_ms=16.7)

        self.assertAlmostEqual(summary["baseline_ms"], 8.3, places=1)
        self.assertEqual(summary["sample_count"], 8)
        self.assertEqual(summary["missed_refresh_count"], 1)
        self.assertEqual(summary["stall_count"], 1)
        self.assertAlmostEqual(summary["missed_refresh_ratio"], 0.125)

    def test_scheduler_summary_uses_fixed_stall_threshold(self):
        summary = summarize_intervals(
            [0.1, 0.2, 0.4, 2.0, 20.0],
            baseline_ms=0.0,
            missed_multiplier=None,
            stall_threshold_ms=16.7,
        )

        self.assertEqual(summary["missed_refresh_count"], 0)
        self.assertEqual(summary["stall_count"], 1)
        self.assertEqual(summary["max_ms"], 20.0)

    def test_process_summary_keeps_mean_p95_peak_and_memory(self):
        samples = {
            "systemstatusd": [
                {"cpu": 1.0, "rss_kb": 100},
                {"cpu": 3.0, "rss_kb": 120},
                {"cpu": 90.0, "rss_kb": 140},
            ],
            "recorder": [],
        }

        summary = summarize_process_samples(samples)

        self.assertAlmostEqual(summary["systemstatusd"]["cpu_mean"], 31.333, places=3)
        self.assertEqual(summary["systemstatusd"]["cpu_p95"], 90.0)
        self.assertEqual(summary["systemstatusd"]["cpu_max"], 90.0)
        self.assertAlmostEqual(summary["systemstatusd"]["rss_peak_mb"], 140 / 1024, places=3)
        self.assertEqual(summary["recorder"]["sample_count"], 0)

    def test_gpu_summary_reports_saturation_ratio_not_only_average(self):
        summary = summarize_gpu_samples([
            {"device": 10.0, "renderer": 8.0, "tiler": 4.0},
            {"device": 85.0, "renderer": 80.0, "tiler": 70.0},
            {"device": 100.0, "renderer": 99.0, "tiler": 95.0},
        ])

        self.assertEqual(summary["sample_count"], 3)
        self.assertEqual(summary["device_mean"], 65.0)
        self.assertEqual(summary["device_p95"], 100.0)
        self.assertEqual(summary["device_max"], 100.0)
        self.assertAlmostEqual(summary["device_above_80_ratio"], 2 / 3, places=6)
        self.assertEqual(summary["renderer_p95"], 99.0)
        self.assertEqual(summary["tiler_p95"], 95.0)


if __name__ == "__main__":
    unittest.main()
