import json
import unittest
from test_analyze import analyze, event


def screen(ms, display_id=1, x=0, width=1440, height=900):
    return event("display", ms, x=x, y=0, coordinate_system="quartz_global_points_top_left",
                 details=f"display_id={display_id};width={width};height={height};pixels_w={width * 2};pixels_h={height * 2}")


def click(ms, x=1):
    return [event("mouse_down", ms, button=0, x=x, y=1, app_bundle_id="app"),
            event("mouse_up", ms + 1, button=0)]


class PersonalDisplayContextTests(unittest.TestCase):
    def test_same_cell_on_two_layouts_never_shares_counts(self):
        events = [event("boundary", 0, details="recording_started"), screen(1)] + click(10)
        events += [event("boundary", 20, details="display_layout_changed"), screen(21, width=1920)] + click(30)
        summary, clicks = analyze.analyze(events)
        first, second = [c["display_layout"] for c in clicks]
        self.assertNotEqual(first, second)
        self.assertIsNone(clicks[1]["previous_cell"])
        self.assertEqual(len(summary["click_heatmap"]["by_display_layout"]), 2)
        model = analyze.fit(clicks, min_support=2)
        for layout in (first, second):
            for baseline in (False, True):
                self.assertTrue(analyze.predict(model, "app", display_layout=layout, baseline=baseline)["abstained"])

    def test_geometry_order_and_transient_display_ids_do_not_change_identity(self):
        events = [event("boundary", 0, details="recording_started"), screen(1), screen(2, 2, -1920, 1920)] + click(10)
        events += [event("boundary", 20, details="display_layout_changed"),
                   screen(21, 9, -1920, 1920), screen(22, 8)] + click(30)
        _, clicks = analyze.analyze(events)
        self.assertEqual(clicks[0]["display_layout"], clicks[1]["display_layout"])

    def test_geometry_does_not_use_target_positions_and_negative_origins_are_preserved(self):
        _, clicks = analyze.analyze([screen(0, x=-1440)] + click(1, x=-1400) + click(3, x=-1000))
        self.assertEqual(clicks[0]["display_layout"], clicks[1]["display_layout"])
        self.assertEqual(clicks[0]["cell"], "-14,0")
        self.assertEqual(clicks[1]["previous_cell"], "-14,0")

    def test_missing_or_corrupt_metadata_abstains_from_known_layout(self):
        _, known = analyze.analyze([screen(0)] + click(1))
        _, unknown = analyze.analyze(click(1))
        model = analyze.fit(known * 5, min_support=1)
        self.assertTrue(analyze.predict(model, "app", display_layout=unknown[0]["display_layout"])["abstained"])
        self.assertTrue(analyze.predict(model, "app")["abstained"])
        summary, corrupt = analyze.analyze([screen(0), event("display", 1, details="invalid")] + click(2))
        self.assertTrue(corrupt[0]["display_layout"].startswith("unknown:"))
        self.assertEqual(summary["quality"]["invalid_display_records"], 1)

    def test_invalid_record_header_invalidates_previously_known_geometry(self):
        broken = screen(1)
        broken.pop("timestamp_ns")
        summary, clicks = analyze.analyze([screen(0), broken] + click(2))
        self.assertEqual(summary["quality"]["invalid_events"], 1)
        self.assertTrue(clicks[0]["display_layout"].startswith("unknown:"))

    def test_unknown_layouts_are_isolated_between_sessions(self):
        events = click(1) + [dict(e, session_id="session-b") for e in click(3)]
        _, clicks = analyze.analyze(events)
        self.assertNotEqual(clicks[0]["display_layout"], clicks[1]["display_layout"])

    def test_loss_cannot_accept_a_partial_display_batch_as_complete(self):
        events = [screen(0), event("data_loss", 1, dropped_record_count=2), screen(2, display_id=2)] + click(3)
        _, clicks = analyze.analyze(events)
        self.assertTrue(clicks[0]["display_layout"].startswith("unknown:"))

    def test_unclassified_loss_boundary_does_not_preserve_known_geometry(self):
        for reason in ("recovered_unterminated_tail", "tap_disabled_detected", None):
            _, clicks = analyze.analyze([screen(0), event("boundary", 1, details=reason)] + click(2))
            self.assertTrue(clicks[0]["display_layout"].startswith("unknown:"))

    def test_holdout_cannot_borrow_other_layouts_popularity(self):
        clicks = [{"app": "app", "previous_cell": None, "cell": "0,0", "display_layout": "laptop"}] * 8
        clicks += [{"app": "app", "previous_cell": None, "cell": "0,0", "display_layout": "external"}] * 2
        result = analyze.evaluate(clicks, min_support=1)
        for name in ("transition_model", "app_popularity_baseline"):
            self.assertEqual(result[name]["coverage"], 0)
            self.assertEqual(result[name]["top1_accuracy_all_test"], 0)

    def test_legacy_model_is_readable_but_cannot_claim_a_known_geometry(self):
        model = {"schema_version": 1, "min_support": 1,
                 "transitions": {json.dumps(["app", None], separators=(",", ":")): {"0,0": 2}},
                 "app_popularity": {"app": {"0,0": 2}}}
        self.assertFalse(analyze.predict(model, "app")["abstained"])
        self.assertTrue(analyze.predict(model, "app", display_layout="new-geometry")["abstained"])
