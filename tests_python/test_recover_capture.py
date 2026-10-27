import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from test_analyze import analyze, event

PATH = Path(__file__).resolve().parents[1] / "scripts/recover_capture.py"
spec = importlib.util.spec_from_file_location("recover_capture", PATH)
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class RecoveryTests(unittest.TestCase):
    def recover(self, root, payload):
        source, output = root / "raw.jsonl", root / "recovered.jsonl"
        source.write_bytes(payload)
        result = recovery.recover(source, output)
        self.assertEqual(source.read_bytes(), payload)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(root.glob(".ghost-recovery-*")), [])
        return output, result

    def test_complete_prefix_and_explicit_gap_preserve_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prefix = (json.dumps(event("key_down", 0, key_code=1)) + "\n").encode()
            output, result = self.recover(root, prefix + b'{"text":"private unfinished')
            self.assertTrue(output.read_bytes().startswith(prefix))
            rows = list(analyze.read_events([output]))
            self.assertEqual(rows[-1]["details"], "recovered_unterminated_tail")
            summary, _ = analyze.analyze(rows + [event("key_up", 20, key_code=1)])
            self.assertEqual(summary["timing"]["key_hold"]["count"], 0)
            self.assertEqual(summary["quality"]["unmatched_key_ups"], 1)
            self.assertNotIn("private unfinished", output.read_text())
            self.assertEqual(result["completed_events"], 1)

    def test_partial_utf8_tail_can_be_recovered(self):
        with tempfile.TemporaryDirectory() as directory:
            prefix = (json.dumps(event("context", 1)) + "\n").encode()
            output, result = self.recover(Path(directory), prefix + b'{"text":"\xe2\x82')
            self.assertEqual(result["discarded_tail_bytes"], 11)
            self.assertEqual(len(list(analyze.read_events([output]))), 2)

    def test_interior_or_terminated_corruption_is_never_ignored(self):
        prefix = (json.dumps(event("context", 1)) + "\n").encode()
        for bad in (b'{bad}\n', b'{bad}\n' + prefix, b'null', b'[]', b'{"text":"no complete prefix'):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                payload = bad if bad.startswith(b'{"text"') else prefix + bad
                source, output = root / "raw.jsonl", root / "new.jsonl"
                source.write_bytes(payload)
                with self.assertRaises(ValueError):
                    recovery.recover(source, output)
                self.assertFalse(output.exists())
                self.assertEqual(source.read_bytes(), payload)
                self.assertEqual(list(root.glob(".ghost-recovery-*")), [])

    def test_complete_file_and_existing_output_are_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / "raw.jsonl", root / "new.jsonl"
            source.write_text(json.dumps(event("context", 1)) + "\n")
            with self.assertRaises(ValueError):
                recovery.recover(source, output)
            self.assertFalse(output.exists())
            output.write_bytes(b"keep this")
            with self.assertRaises(ValueError):
                recovery.recover(source, output)
            self.assertEqual(output.read_bytes(), b"keep this")

    def test_public_repository_destination_is_rejected(self):
        with self.assertRaises(ValueError):
            recovery.recover("unused", PATH.parent / "never-created.jsonl")
