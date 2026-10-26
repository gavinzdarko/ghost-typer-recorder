import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / "scripts" / "analyze.py"
spec = importlib.util.spec_from_file_location("analyze", MODULE)
analyze = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analyze)


def event(kind, ms, **fields):
    return {"schema_version": 1, "kind": kind, "timestamp_ns": int(ms * 1e6),
            "session_id": "session-a", **fields}


class TimingTests(unittest.TestCase):
    def test_overlap_repeat_and_timing_identity(self):
        events = [event("key_down", 0, key_code=1, text="DO NOT LEAK"),
                  event("key_down", 10, key_code=1, is_repeat=True),
                  event("key_down", 50, key_code=2),
                  event("key_up", 80, key_code=1),
                  event("key_up", 100, key_code=2),
                  event("key_down", 150, key_code=3),
                  event("key_up", 160, key_code=3)]
        summary, _ = analyze.analyze(events)
        timing = summary["timing"]
        self.assertEqual(timing["key_hold"]["count"], 3)
        self.assertAlmostEqual(timing["key_hold"]["mean_ms"], 140 / 3)
        self.assertEqual(timing["press_to_press"]["mean_ms"], 75)
        self.assertEqual(timing["release_to_next_press_signed"]["min_ms"], -30)
        self.assertEqual(timing["release_to_next_press_signed"]["max_ms"], 50)
        self.assertEqual(summary["quality"]["repeated_key_downs"], 1)
        self.assertNotIn("DO NOT LEAK", json.dumps(summary))

    def test_boundary_never_joins_partial_holds_or_sequences(self):
        events = [event("key_down", 0, key_code=1),
                  event("mouse_down", 1, button=0, x=-1, y=200, app_bundle_id="app"),
                  event("boundary", 2),
                  event("key_up", 4, key_code=1),
                  event("mouse_up", 5, button=0),
                  event("key_down", 7, key_code=2),
                  event("key_up", 8, key_code=2)]
        summary, clicks = analyze.analyze(events)
        self.assertEqual(summary["timing"]["key_hold"]["count"], 1)
        self.assertEqual(summary["timing"]["press_to_press"]["count"], 0)
        self.assertEqual(summary["timing"]["mouse_hold"]["count"], 0)
        self.assertEqual(summary["quality"]["unclosed_key_presses"], 1)
        self.assertEqual(summary["quality"]["unmatched_key_ups"], 1)
        self.assertEqual(clicks[0]["cell"], "-1,2")

    def test_session_change_allows_clock_restart_and_resets(self):
        events = [event("key_down", 100, key_code=1),
                  event("key_up", 1, key_code=1, session_id="session-b")]
        summary, _ = analyze.analyze(events)
        self.assertEqual(summary["timing"]["key_hold"]["count"], 0)
        self.assertEqual(summary["quality"]["session_segments"], 2)

    def test_out_of_order_rejected(self):
        with self.assertRaisesRegex(ValueError, "chronological"):
            analyze.analyze([event("key_down", 2, key_code=1), event("key_up", 1, key_code=1)])

    def test_newer_metadata_receipt_time_allows_older_queued_input(self):
        events = [event("mouse_down", 0, button=0, x=1, y=1, app_bundle_id="app-a"),
                  event("mouse_up", 1, button=0), event("key_down", 10, key_code=1),
                  event("context", 100, app_bundle_id="app-b"),
                  event("display", 101), event("key_up", 20, key_code=1),
                  event("mouse_down", 30, button=0, x=101, y=1, app_bundle_id="app-a")]
        summary, clicks = analyze.analyze(events)
        self.assertEqual(summary["timing"]["key_hold"]["mean_ms"], 10)
        self.assertIsNone(clicks[1]["previous_cell"])

    def test_metadata_never_masks_genuinely_out_of_order_input(self):
        with self.assertRaisesRegex(ValueError, "chronological"):
            analyze.analyze([event("key_down", 10, key_code=1),
                             event("context", 100, app_bundle_id="app"),
                             event("key_up", 9, key_code=1)])

    def test_boundary_resets_input_chronology_and_discards_pending_hold(self):
        events = [event("key_down", 100, key_code=1), event("boundary", 200),
                  event("key_up", 90, key_code=1),
                  event("key_down", 110, key_code=2), event("key_up", 120, key_code=2)]
        summary, _ = analyze.analyze(events)
        self.assertEqual(summary["timing"]["key_hold"]["count"], 1)
        self.assertEqual(summary["timing"]["key_hold"]["mean_ms"], 10)
        self.assertEqual(summary["quality"]["unmatched_key_ups"], 1)

    def test_writer_data_loss_resets_hold_and_counts_dropped_records(self):
        summary, _ = analyze.analyze([event("key_down", 0, key_code=1),
                                     event("data_loss", 1, dropped_record_count=12),
                                     event("key_up", 2, key_code=1)])
        self.assertEqual(summary["timing"]["key_hold"]["count"], 0)
        self.assertEqual(summary["quality"]["writer_dropped_records"], 12)

    def test_duplicate_down_does_not_shorten_mouse_hold(self):
        events = [event("mouse_down", 0, button=0, x=2, y=2, app_bundle_id="app"),
                  event("mouse_down", 10, button=0, x=2, y=2, app_bundle_id="app"),
                  event("mouse_up", 100, button=0)]
        summary, clicks = analyze.analyze(events)
        self.assertEqual(summary["timing"]["mouse_hold"]["mean_ms"], 100)
        self.assertEqual(len(clicks), 1)
        self.assertEqual(summary["quality"]["duplicate_mouse_downs"], 1)

    def test_missing_app_still_appears_in_heatmap_but_not_model(self):
        summary, clicks = analyze.analyze([event("mouse_down", 0, button=0, x=1, y=1)])
        self.assertEqual(summary["click_heatmap"]["counts"], {"0,0": 1})
        self.assertEqual(clicks, [])

    def test_non_click_app_switch_resets_previous_click_even_when_returning(self):
        events = [event("mouse_down", 0, button=0, x=1, y=1, app_bundle_id="app-a"),
                  event("mouse_up", 1, button=0),
                  event("context", 2, app_bundle_id="app-b"),
                  event("context", 3, app_bundle_id="app-a"),
                  event("mouse_down", 4, button=0, x=101, y=1, app_bundle_id="app-a")]
        _, clicks = analyze.analyze(events)
        self.assertIsNone(clicks[1]["previous_cell"])

    def test_keyboard_app_change_and_unknown_context_break_click_continuity(self):
        events = [event("mouse_down", 0, button=0, x=1, y=1, app_bundle_id="app-a"),
                  event("mouse_up", 1, button=0),
                  event("key_down", 2, key_code=1, app_bundle_id="app-b"),
                  event("mouse_down", 3, button=0, x=101, y=1, app_bundle_id="app-a"),
                  event("mouse_up", 4, button=0), event("context", 5),
                  event("mouse_down", 6, button=0, x=201, y=1, app_bundle_id="app-a")]
        _, clicks = analyze.analyze(events)
        self.assertEqual([c["previous_cell"] for c in clicks], [None, None, None])

    def test_same_app_context_preserves_previous_click(self):
        events = [event("mouse_down", 0, button=0, x=1, y=1, app_bundle_id="app"),
                  event("mouse_up", 1, button=0), event("context", 2, app_bundle_id="app"),
                  event("mouse_down", 3, button=0, x=101, y=1, app_bundle_id="app")]
        _, clicks = analyze.analyze(events)
        self.assertEqual(clicks[1]["previous_cell"], "0,0")

    def test_invalid_events_break_pending_holds(self):
        for invalid in ([], event([], 1), event("key_down", 1, key_code=-1),
                        {"schema_version": 1, "kind": "key_down", "timestamp_ns": True}):
            with self.subTest(invalid=invalid):
                summary, _ = analyze.analyze([event("key_down", 0, key_code=1), invalid,
                                             event("key_up", 2, key_code=1)])
                self.assertEqual(summary["timing"]["key_hold"]["count"], 0)
                self.assertEqual(summary["quality"]["unclosed_key_presses"], 1)

    def test_mouse_hold_and_no_raw_context_output(self):
        summary, _ = analyze.analyze([
            event("mouse_down", 10, button=2, x=101, y=201, app_bundle_id="app",
                  text="raw text secret", window_title="private document title", app_name="private name"),
            event("mouse_up", 62, button=2)])
        self.assertEqual(summary["timing"]["mouse_hold"]["mean_ms"], 52)
        output = json.dumps(summary)
        for secret in ("raw text secret", "private document title", "private name"):
            self.assertNotIn(secret, output)


class PredictionTests(unittest.TestCase):
    def test_chronological_holdout_has_no_future_target_leakage(self):
        clicks = [{"app": "app", "previous_cell": "0,0", "cell": "1,1"}] * 8
        clicks += [{"app": "app", "previous_cell": "0,0", "cell": "9,9"}] * 2
        evaluation = analyze.evaluate(clicks, min_support=1)
        self.assertEqual(evaluation["train_clicks"], 8)
        self.assertEqual(evaluation["transition_model"]["top3_accuracy_all_test"], 0)
        self.assertEqual(evaluation["app_popularity_baseline"]["top1_accuracy_all_test"], 0)

    def test_abstains_on_unseen_or_unsupported_context(self):
        model = analyze.fit([{"app": "app", "previous_cell": None, "cell": "0,0"}], min_support=2)
        self.assertTrue(analyze.predict(model, "app")["abstained"])
        self.assertTrue(analyze.predict(model, "other")["abstained"])

    def test_transition_model_can_outperform_app_popularity(self):
        clicks = ([{"app": "app", "previous_cell": "0,0", "cell": "1,1"}] * 6
                  + [{"app": "app", "previous_cell": "1,1", "cell": "0,0"}] * 4)
        model = analyze.fit(clicks, min_support=1)
        prediction = analyze.predict(model, "app", "1,1")
        baseline = analyze.predict(model, "app", "1,1", baseline=True)
        self.assertEqual(prediction["candidates"][0]["cell"], "0,0")
        self.assertEqual(baseline["candidates"][0]["cell"], "1,1")

    def test_empty_evaluation_is_explicit(self):
        report = analyze.evaluate([])
        self.assertEqual(report["status"], "insufficient_data")
        self.assertIsNone(report["transition_model"]["top1_accuracy_all_test"])

    def test_cli_creates_private_files_and_refuses_to_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            capture, summary, model = [directory / name for name in ("capture.jsonl", "summary.json", "model.json")]
            capture.write_text(json.dumps(event("key_down", 1, key_code=0, text="secret")) + "\n")
            self.assertEqual(analyze.main([str(capture), "--summary", str(summary), "--model", str(model)]), 0)
            self.assertEqual(summary.stat().st_mode & 0o777, 0o600)
            self.assertEqual(model.stat().st_mode & 0o777, 0o600)
            self.assertNotIn("secret", summary.read_text())
            with self.assertRaises(SystemExit):
                analyze.main([str(capture), "--summary", str(summary)])

    def test_cli_blocks_repo_output(self):
        with self.assertRaises(SystemExit):
            analyze.main(["unused.jsonl", "--summary", str(MODULE.parent / "should-not-exist.json")])

    def test_directory_file_sort_uses_event_time_not_random_uuid_name(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            early, late = directory / "z_uuid.jsonl", directory / "a_uuid.jsonl"
            early.write_text(json.dumps(event("key_down", 0, key_code=1, wall_time="2026-10-26T00:00:00.000Z")) + "\n")
            late.write_text(json.dumps(event("key_up", 100, key_code=1, wall_time="2026-10-26T00:01:00.000Z")) + "\n")
            self.assertEqual(sorted([late, early], key=analyze.capture_file_order), [early, late])
            summary = directory / "summary.json"
            self.assertEqual(analyze.main([str(directory), "--summary", str(summary)]), 0)
            self.assertEqual(json.loads(summary.read_text())["timing"]["key_hold"]["mean_ms"], 100)

    def test_malformed_or_truncated_input_fails_without_creating_summary(self):
        for tail in ('{"text":"do not print this",', '[1, 2]', 'null'):
            with tempfile.TemporaryDirectory() as directory:
                directory = Path(directory)
                capture, summary = directory / "capture.jsonl", directory / "summary.json"
                capture.write_text(json.dumps(event("key_down", 0, key_code=1)) + "\n" + tail)
                with self.assertRaises(ValueError) as error:
                    list(analyze.read_events([capture]))
                self.assertNotIn("do not print this", str(error.exception))
                self.assertEqual(analyze.main([str(capture), "--summary", str(summary)]), 1)
                self.assertFalse(summary.exists())


if __name__ == "__main__":
    unittest.main()
