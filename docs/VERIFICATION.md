# Verification and owner checklist

## Noninteractive verification (2026-10-26)

- Swift: full Xcode SDK build and **8 RecorderCore tests passed** (encoding, concurrency/order, rotation, file permissions, bounded overflow markers, flush/drain, disk errors).
- Python: **23 offline analysis tests passed**, using synthetic data. Includes overlaps, signed intervals, repeats, gap resets, app switches, mixed metadata/input clocks, chronological holdout, sparse abstention and private outputs.
- Release binary: built on Apple Silicon (`arm64`). App bundle metadata passes `plutil -lint`; build script passes `bash -n`.
- Packaging: locally ad-hoc signed. Strict signature verification passes on the staging bundle and again on the ZIP extracted into a fresh temporary directory. This is not Developer ID signing or notarization.
- Initial strict validation failed because `com.apple.FinderInfo` was attached to the generated app under the synced Documents folder. Removing it briefly resolved validation, but the File Provider reattached it during a subsequent signing attempt. Final packaging signs and validates outside the synced folder and creates a ZIP without extended attributes. The convenient `dist/Ghost Recorder.app` copy can still be decorated by the File Provider; the verified ZIP is the portable deliverable.
- Source review fixed common-mode timers (so menu tracking does not suspend health/context updates), explicit menu validation (so recording options stay disabled while recording), lock/sleep suspension reasons, event chronology and gap handling.
- Personal captures, derived models/reports, credentials, and build intermediates are excluded from Git. No live personal input dataset was collected during implementation.

## Owner-unverified behavior

The live menu, macOS permission flow, event delivery, secure-input gaps, login launch, lock/wake handling, multi-monitor behavior and multi-day reliability are **not verified on the owner's Mac**. The optional computer-use check was skipped. No Input Monitoring or Accessibility permission was granted and recording was not enabled during implementation. Code tests do not substitute for this check.

## Exact owner steps

1. If an earlier Ghost Recorder instance is present, choose **Quit Ghost Recorder** from its circle menu. Open the latest `dist/Ghost Recorder.app`, or extract `dist/Ghost-Recorder-macOS-arm64.zip` and put **Ghost Recorder.app** in a stable `~/Applications` folder. First launch should show the circle and **OFF** in the menu bar.
2. While OFF, review **Record typed characters** and **Record window titles**. Both default ON. The latter reads only accessible window titles, not document contents.
3. Choose **Turn Recording ON**, read the notice and choose **Start Recording**. macOS requires your manual permission: **System Settings → Privacy & Security → Input Monitoring → Ghost Recorder**. Enable it. Quit/reopen the app if macOS requires that, then turn recording ON again. If the app is absent from the list, add the exact stable app bundle with the `+` control.
4. Optional: choose **Enable window context permission…** and manually approve Ghost Recorder in Accessibility. Input/app collection works without this; titles will be absent.
5. Confirm red **REC** and an increasing event count. In a throwaway document type harmless sample text, hold a key briefly (including repeat), overlap two keys, then hold/release left and right mouse buttons, drag, and scroll. **Open Recordings Folder** shows the private files. Inspect the gap/unmatched counters with the offline analyzer before trusting the dataset. Do not publish the files.
6. Turn OFF. Confirm **OFF** and that no new input events are added once the writer finishes saving. Repeat ON/OFF to check separate sessions. Check that cancellation/permission refusal leaves it OFF.
7. Before a multi-day run, check sleep/wake and lock/unlock: collection should pause and resume only after the session is active while recording remains ON. Secure Event Input should pause collection without revealing protected values. Use harmless sample content; do not enter real secrets for testing. Some OS lock signals are undocumented, so treat these checks as required.
8. After those checks pass, turn ON and optionally enable **Launch at login** plus **Resume recording when app opens**. For 3–4 days keep Ghost Typer's automatic typing OFF, keep the display layout stable and check free disk space/data-loss counters. Turning recording OFF clears persisted recording intent. There is no automatic retention deletion.
9. Run the private offline analyzer from the README. Keep outputs outside the public repository. Its count model is an exploratory next-click baseline, not a validated complete prediction model. Reserve later unseen days before claiming accuracy.
