import json
from pathlib import Path
import tempfile
import unittest
from test_analyze import analyze, event


class PersonalSourceSelectionTests(unittest.TestCase):
    def test_selected_automation_never_trains_holds_or_clicks(self):
        events = [event("key_down", 0, key_code=1, source_pid=42),
                  event("key_up", 10, key_code=1, source_pid=42),
                  event("mouse_down", 20, button=0, x=1, y=1, app_bundle_id="app", source_pid=42),
                  event("mouse_up", 30, button=0, source_pid=42),
                  event("key_down", 40, key_code=2, source_pid=43),
                  event("key_up", 60, key_code=2, source_pid=43)]
        original = json.dumps(events)
        selected, clicks = analyze.analyze(events, excluded_source_pids=[42])
        self.assertEqual(selected["timing"]["key_hold"]["mean_ms"], 20)
        self.assertEqual(selected["quality"]["excluded_source_events"], 4)
        self.assertEqual(clicks, [])
        self.assertEqual(json.dumps(events), original)
        all_events, all_clicks = analyze.analyze(events)
        self.assertEqual(all_events["timing"]["key_hold"]["count"], 2)
        self.assertEqual(len(all_clicks), 1)

    def test_exclusion_breaks_physical_pairs_and_click_history(self):
        events = [event("mouse_down", 0, button=0, x=1, y=1, app_bundle_id="app"),
                  event("mouse_up", 1, button=0), event("key_down", 2, key_code=1),
                  event("key_down", 3, key_code=2, source_pid=42),
                  event("key_up", 4, key_code=1),
                  event("mouse_down", 5, button=0, x=101, y=1, app_bundle_id="app")]
        summary, clicks = analyze.analyze(events, excluded_source_pids=[42])
        self.assertEqual(summary["timing"]["key_hold"]["count"], 0)
        self.assertIsNone(clicks[-1]["previous_cell"])

    def test_cli_records_only_the_owners_explicit_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            capture, summary, model = [root / f for f in ("input.jsonl", "summary.json", "model.json")]
            capture.write_text(json.dumps(event("mouse_down", 0, source_pid=42, button=0,
                                                x=1, y=1, app_bundle_id="app")) + "\n")
            before = capture.read_bytes()
            result = analyze.main([str(capture), "--summary", str(summary), "--model", str(model),
                                   "--exclude-source-pid", "42", "--exclude-source-pid", "99"])
            self.assertEqual(result, 0)
            for output in (summary, model):
                self.assertEqual(json.loads(output.read_text())["selection"]["excluded_source_pids"], [42, 99])
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(capture.read_bytes(), before)

    def test_untrusted_or_missing_source_metadata_does_not_match_a_selection(self):
        for value in (None, True, "42", [42], {"pid": 42}):
            events = [event("key_down", 0, key_code=1, source_pid=value),
                      event("key_up", 10, key_code=1, source_pid=value)]
            summary, _ = analyze.analyze(events, excluded_source_pids=[1, 42])
            self.assertEqual(summary["timing"]["key_hold"]["count"], 1)
            self.assertEqual(summary["quality"].get("excluded_source_events", 0), 0)

    def test_invalid_pid_is_rejected(self):
        for pid in (-1, 0, True, "42"):
            with self.assertRaises(ValueError):
                analyze.analyze([], excluded_source_pids=[pid])
        with self.assertRaises(SystemExit):
            analyze.main(["unused", "--summary", "/tmp/unused-report.json", "--exclude-source-pid", "0"])
