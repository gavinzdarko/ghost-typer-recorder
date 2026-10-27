# Pre-live check — 2026-10-27

This verification branch combines PRs 1–5 without merging them into main. It adds save/sleep safeguards and noninteractive checks before the owner tests real input and laptop sleep. No input monitor, Accessibility grant, login item or recording preference was activated by these checks.

## Changes made during the check

- OFF already drained and closed accepted data. It now retains a visible saved-event summary after completion; a writer failure still displays an error rather than success.
- Sleep/session suspension now pauses the input source and requests an immediate bounded disk checkpoint. A timeout is marked as incomplete instead of falsely claiming guaranteed persistence before OS sleep.
- An explicit capture input gate rejects late callbacks while stopped and events preceding a start/privacy/sleep boundary.
- Native event decoding is separately testable without listening to or posting input. Event text is cleared before opt-out/release handling; actual Unicode length replaces the old fixed 64-code-unit buffer. Unusually large payloads have a bounded, explicitly marked truncation.
- Startup checks that macOS actually enabled the created tap.
- Added an explicit storage-only `RecorderStorageProbe` diagnostic; it never collects input or changes preferences. Preview bundle version is 0.1.1, build 2.

## Verified without live collection

- 27 Swift tests pass: native keyboard/Unicode/repeat/modifier/mouse/drag/scroll decoding; text opt-out; OFF/privacy/sleep input gating; bounded context replies; writer order, private permissions, overflow, disk/encoding errors, 5,001-event OFF drain, reopen retention, immediate sleep checkpoint, UTC-midnight rotation and a 20,000-event synthetic checkpoint stream.
- 43 Python tests pass: pairing, overlaps, gap resets, chronological evaluation, personal source selections, layout-specific training and interrupted-file recovery.
- The production writer was run against its actual default Recordings directory using 14 explicitly synthetic events. After OFF, a separate process verified the saved SHA-256 and the analyzer recovered the expected three key holds, signed overlap, 200 ms mouse hold and an invalidated hold across a sleep gap. Opening a second writer did not alter the first session.
- Probe files are retained in the app's private `Diagnostics` folder, outside `Recordings`, so they do not enter the owner's training data. No existing personal capture was read or changed.
- Files are 0600 and the Recordings directory is 0700. OFF and reopening do not delete completed sessions. No retention deletion is scheduled. These permissions are access control, not encryption or a backup.
- Release packaging verifies the staged ad-hoc signature and a fresh ZIP extraction. The portable ZIP avoids Finder metadata that synced folders can add to app copies. It is not notarized.

## Reproducible commands

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
python3 -m unittest discover -s tests_python -v
bash scripts/build-app.sh
# Explicit synthetic storage probe, not an input listener:
swift run RecorderStorageProbe --probe-default-storage
```

On this Mac, ThreadSanitizer binaries exit with signal 11 before tests start. An unrelated Foundation-only smoke executable built with ThreadSanitizer reproduces the same startup failure. This is unavailable runtime coverage, not a successful race check or evidence that a recorder test found a data race. A separate macOS 15 CI job attempts that coverage without changing the owner's machine.

## Owner live check still required

1. Quit an older Ghost Recorder instance, extract the verified 0.1.1 preview and open it. Confirm OFF. Manually grant Input Monitoring for this exact app if needed; Accessibility is optional for titles.
2. Turn ON. Type harmless sample text, hold/release a key, make a few clicks and scroll. Confirm REC and a rising count.
3. Leave recording ON, close the laptop for about 20 seconds, reopen and unlock. With no external display/clamshell arrangement preventing system sleep, capture should pause during sleep and resume only in the active unlocked session. Physical OS notification delivery is not established by synthetic tests.
4. Type a second harmless sample, then turn OFF. Wait for the saved-event summary. Open Recordings Folder; the normal capture should be there and remain after quitting/reopening. Keep recording OFF after this short test.
5. Inspect that session locally for pre/post-sleep boundaries, dropped events and unmatched edges before trusting a multi-day recording. Do not publish the personal log. Secure-input behavior and real device timing remain live-test items, not certified completeness.
