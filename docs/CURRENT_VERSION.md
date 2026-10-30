# Current tested preview

Ghost Recorder **0.1.1, build 2** is the preview verified against the installed app on October 30, 2026. The installed executable and bundle metadata match the retained tested release archive byte for byte. The app sources are from commit `a37d1e2db833ff842a72f209d2906110932be3ee`; subsequent publication changes add diagnostic coverage and documentation without changing the recorder app or core library.

The release asset is `Ghost-Recorder-0.1.1-arm64.zip`, for Apple Silicon Macs running macOS 13 or newer. The bundle is ad-hoc signed, not notarized. Build from source for other supported architectures.

SHA-256 of the release ZIP:

```text
f794769e397e598db1819e28ec0af7417cf10d86bf3f468ab9a13680dafffe9e
```

SHA-256 of `Contents/MacOS/GhostRecorder` inside that archive:

```text
ef7f97f054e843da0bb2cecf055a7c41b50a82afb7a40451ed6fd3abf33c7019
```

## Verification

- 29 Swift tests pass, including two integration tests for native event text and exact timestamp persistence through OFF and reopening storage. Debug and Release both passed on October 28; Release was rerun for publication on October 30.
- 43 Python tests pass, including timing relationships, data gaps, offline model evaluation and interrupted-file recovery. There are 72 distinct functional tests.
- The explicit storage-only probe decodes constructed native Unicode events, writes them using the production writer in the real default storage directory, stops, reads them back and checks exact equality. A second writer cannot overwrite the original. Its synthetic files move to Diagnostics, outside training recordings.
- The October 28 probe also passed a separate-process disk read, exact Unicode/timestamp comparison and SHA-256 verification.
- Earlier remote macOS 15 ThreadSanitizer coverage passed for the app/core source commit. The local ThreadSanitizer runtime cannot start even an unrelated Foundation smoke executable; this is not claimed as local race-test success.

Constructed native events are never posted as user input. Automated tests do not certify physical hardware accuracy, current permissions, real sleep/wake delivery or complete capture in every application. Event text may differ from pasted, dictated, autocorrected or input-method committed document text. Protected input is skipped.

Only source, synthetic diagnostics and verification notes are published. Personal captures, preferences and derived analysis remain outside this repository.
