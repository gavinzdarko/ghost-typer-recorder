#!/usr/bin/env python3
"""Recover a complete JSONL prefix to a NEW private file; never rewrite a capture."""
import argparse
import json
import os
from pathlib import Path
import tempfile


def recover(source, output):
    source, output = Path(source), Path(output)
    repo = Path(__file__).resolve().parents[1]
    destination = output.resolve()
    if destination == repo or repo in destination.parents:
        raise ValueError("Keep recovered personal captures outside this public repository")
    if source.resolve() == destination or output.exists():
        raise ValueError("Recovery needs a new output path distinct from the source")
    initial = source.stat()
    signature = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns)
    temporary = None
    completed = discarded = 0
    last = None
    try:
        with tempfile.NamedTemporaryFile(mode="wb", dir=output.parent, prefix=".ghost-recovery-",
                                         delete=False) as target:
            temporary = Path(target.name)
            os.fchmod(target.fileno(), 0o600)
            with source.open("rb") as stream:
                for number, raw in enumerate(stream, 1):
                    if not raw.strip():
                        target.write(raw)
                        continue
                    try:
                        event = json.loads(raw.decode("utf-8"))
                    except (UnicodeDecodeError, json.JSONDecodeError):
                        if raw.endswith(b"\n") or stream.peek(1) or last is None:
                            raise ValueError(f"Invalid complete/interior line at {source.name}:{number}") from None
                        discarded = len(raw)
                        # The final unterminated malformed line is an explicit loss.
                        # Do not infer missing releases or copy any partial text.
                        gap = {"schema_version": 1, "kind": "boundary",
                               "timestamp_ns": last["timestamp_ns"], "session_id": last["session_id"],
                               "details": "recovered_unterminated_tail", "discarded_tail_bytes": discarded}
                        if isinstance(last.get("wall_time"), str):
                            gap["wall_time"] = last["wall_time"]
                        target.write((json.dumps(gap, separators=(",", ":")) + "\n").encode("utf-8"))
                        break
                    if (not isinstance(event, dict) or event.get("schema_version") != 1
                            or not isinstance(event.get("kind"), str) or not event["kind"]
                            or not isinstance(event.get("timestamp_ns"), int)
                            or isinstance(event["timestamp_ns"], bool) or event["timestamp_ns"] < 0
                            or not isinstance(event.get("session_id"), str) or not event["session_id"]):
                        raise ValueError(f"Invalid event schema at {source.name}:{number}")
                    target.write(raw)
                    last = event
                    completed += 1
            if not discarded:
                raise ValueError("No malformed unterminated final line found; original needs no tail recovery")
            if signature(source.stat()) != signature(initial):
                raise ValueError("Source changed during recovery; turn recording OFF before retrying")
            target.flush()
            os.fsync(target.fileno())
        # Exclusive atomic publication; a destination appearing concurrently is never replaced.
        os.link(temporary, output)
        return {"completed_events": completed, "discarded_tail_bytes": discarded}
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", required=True, type=Path, help="NEW private file outside the repository and raw capture set")
    args = parser.parse_args(argv)
    try:
        result = recover(args.source, args.output)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Recovery failed: {error}\n")
    print(f"Recovered {result['completed_events']} complete events; marked {result['discarded_tail_bytes']} lost tail bytes. Original unchanged.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
