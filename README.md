# Ghost Recorder

A separate, native macOS menu bar data collector for [Ghost Typer](https://github.com/gavinzdarko/ghost-typer). Click the circle in the menu bar, choose **Turn Recording ON**, and use your Mac normally. A red **REC** stays visible while collecting. Choose **Turn Recording OFF** to stop and flush the file. No Python runtime or third-party dependencies are needed to run the app.

This is a personal dataset recorder plus an offline next-click baseline. It does **not** yet predict arbitrary UI controls, understand complete documents, or drive Ghost Typer. The existing Ghost Typer repository and its Forge automation are untouched.

Current tested preview: **0.1.1, build 2** ([download the Apple Silicon build](https://github.com/gavinzdarko/ghost-typer-recorder/releases/tag/v0.1.1)). The release uses the same app executable as the owner's installed preview. See [version and verification details](docs/CURRENT_VERSION.md).

## Build and open

Requires macOS 13 or newer and the Swift command line tools. Build on the machine/architecture where you will run it:

```sh
bash scripts/build-app.sh
open "dist/Ghost Recorder.app"
```

The app starts **OFF** on first launch. To collect:

1. Optionally adjust **Record typed characters** and **Record window titles** while OFF. Both default on. Approve the clear recording notice the first time you turn ON.
2. Enable **Ghost Recorder** in **System Settings → Privacy & Security → Input Monitoring**. The menu links there. macOS may require quitting and reopening the app after permission changes.
3. Optional: use **Enable window context permission…** to grant Accessibility. Without it, input/app data still works but window titles are absent.
4. Turn ON again; confirm red **REC** and a rising event count. **OFF** and **PAUSED** mean no input is collected.
5. For a roughly 3–4 day collection, optionally enable **Launch at login** and **Resume recording when app opens**. Resume is opt-in; recording intent stays ON through a normal quit when that option is enabled. Turning recording OFF clears the intent. Keep the app in one stable location; for long-term use move it to `~/Applications` before granting permissions/registering login launch. Only one instance can run at a time.

Builds are locally ad-hoc signed, not Developer ID signed or notarized. Moving or rebuilding the app can require granting permission again. Login item registration uses macOS Service Management and may require approval in System Settings.

The build also creates `dist/Ghost-Recorder-macOS-<architecture>.zip`. Packaging signs in a temporary folder and verifies both the bundle and a freshly extracted ZIP. Synced folders can automatically attach Finder metadata that makes strict signing checks fail on the convenient local copy; extract the verified ZIP into a stable Applications folder in that case.

## What is collected

- Key down/up with virtual key code, modifier flags, repeat marker, keyboard type, original event timestamp, and optional event Unicode text. Modifiers are preserved as raw `flags_changed` records.
- Mouse down/up for all buttons, movement and drag events, position, deltas, available pressure and click count; scroll point deltas. These are the events macOS delivers, without extra movement sampling or screenshots.
- App bundle ID/name, optional accessible window title, source PID, session ID, UTC wall time, and display-layout metadata. Context is refreshed on app activation and every 500 ms; it is approximate and can race an app/window switch. Source PID identifies the event source, not necessarily the target app.
- Explicit lifecycle and overflow gap markers; display metadata at session start and display changes.

The analyzer derives physical key hold duration, press-to-press intervals, signed release-to-next-press intervals (including overlap), and mouse button holds. It skips repeats as extra physical presses. Modifier hold durations are not derived yet. All delivered moves are retained; macOS/hardware can coalesce or omit events. Nanosecond timestamp units do not mean nanosecond physical accuracy.

Event text is **not a final document transcript**. IMEs, dead keys, autocorrect, shortcuts, paste, dictation, and application edits can differ. No clipboard contents, focused-field values, full documents, browser DOM/URLs, screenshots, video, or page contents are read. Titles sometimes contain document names or page titles. Protected Secure Event Input is respected and skipped; pending timing relationships are reset at observed gaps. Do not expect every secure-input transition to be detected. Sensitive text typed into ordinary fields can still be saved.

The session stream can include remote or software-generated input. Keep Ghost Typer's automatic typing OFF while gathering a personal training sample, or exclude known generated activity later. Source PID is a useful hint, not authenticated proof of a physical device.

Recording pauses on observed sleep, display sleep, inactive session or lock and resumes only when the session is active and recording is still ON. Some lock notifications/session dictionary keys are undocumented, so OS changes can affect detection. A health timer checks session activity, Input Monitoring, listener state and writer failures; gaps reset timing continuity. Test these on your own Mac before a multi-day run.

## Your data stays local

**Open Recordings Folder** opens:

```text
~/Library/Application Support/Ghost Recorder/Recordings/
```

The app has no networking or upload mechanism. The public repository contains source code and evidence only. App-specific folders use owner-only `0700` permissions and recording files `0600`. Files are plaintext, not encrypted; other processes running as your user may read them. Turn OFF before sensitive work you do not want saved. Git ignores captures and derived JSON, and the analyzer refuses to save outputs inside this repository.

The bounded writer flushes in batches, rotates at 64 MiB or a UTC date change, marks queue overflow with `data_loss`, and stops collection on detected disk errors. A crash/power loss can lose queued data or leave a partial last line. Accepted events are drained on normal OFF/Quit. There is no automatic data deletion or size cap: check free space during several days of movement-heavy recording. Do not upload personal captures in issues or commits.

## Analyze and build a first model

Use Python 3.9+ only for offline analysis:

```sh
python3 scripts/analyze.py \
  "$HOME/Library/Application Support/Ghost Recorder/Recordings" \
  --summary "$HOME/Library/Application Support/Ghost Recorder/summary.json" \
  --model "$HOME/Library/Application Support/Ghost Recorder/click-model.json"
```

Choose fresh output filenames each run. [Analysis details](scripts/README.md) explain chronology and data-quality counters. The model predicts a coarse screen cell from app + previous click cell, abstains for sparse contexts, and reports chronological holdout top-1/top-3 accuracy and coverage against an app-popularity baseline. It is an offline baseline with no accuracy claim and no automatic clicking. It is not a text-generation or complete next-action model. Collect initial data for 3–4 days, then reserve later unseen days for honest evaluation. Keep display layout stable or analyze layouts separately.

All four agents contributed to the single [research and evidence notebook](docs/EVIDENCE.md). It compares Apple APIs and GitHub projects, records source links and limitations, and lays out the route from this dataset to a richer personal prediction model. No third-party implementation was copied or vendored.

## Development

```sh
swift test
python3 -m unittest discover -s tests_python -v
bash scripts/build-app.sh
```

Swift tests need the full Xcode XCTest SDK. If your selected command line tools lack it, use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` without changing global settings. Tests use synthetic events and temporary directories; no real keystrokes are needed. Granting permissions and live lock/wake/secure-field capture still require manual verification on the target Mac.

- `Sources/`: native menu bar app, passive input listener, schema and bounded local writer.
- `Tests/` and `tests_python/`: storage, timing, gap and model evaluation tests.
- `scripts/`: app packaging and offline personal analysis.
- `resources/`: app bundle metadata.
- `docs/`: shared research evidence and verification notes.

MIT licensed.
