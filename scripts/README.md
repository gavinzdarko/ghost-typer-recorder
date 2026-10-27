# Private offline analysis

Requires Python 3.9+ and its standard library. The recorder and analyzer never
upload data. Keep input captures, summaries, and learned models outside this
public repository; summaries can still reveal personal habits and app usage.

After recording, choose a **new** output path in the private recording folder:

```sh
python3 scripts/analyze.py \
  "$HOME/Library/Application Support/Ghost Recorder/Recordings" \
  --summary "$HOME/Library/Application Support/Ghost Recorder/summary.json" \
  --model "$HOME/Library/Application Support/Ghost Recorder/click-model.json"
```

Use the actual capture directory shown in the app if it differs. Directories are
searched for `*.jsonl` recursively in first-event UTC wall-time order; explicit file arguments are
processed in argument order. Preserve chronological capture order and analyze
one person at a time. Display geometry is automatically partitioned when present; missing or corrupt geometry is isolated by session/segment. Input timestamps come from
CGEvent occurrence time; context/display/boundary metadata uses callback receipt
time. A new context record can therefore have a newer timestamp than a queued
input delivered immediately afterward. Metadata does not advance the analyzer's
input timestamp baseline. The analyzer rejects time moving backward between
input events within an uninterrupted segment; boundaries, data-loss markers,
and session changes reset that baseline. It preserves stream order rather than
silently sorting events or joining holds across gaps.

The summary reports key dwell times, press-to-press intervals, signed
release-to-next-press intervals (negative means overlap), mouse button hold
times, key-code aggregates, and a spatial click heatmap. Auto-repeat events do
not create additional physical presses. Pauses/session boundaries discard
incomplete holds and break sequences; writer `data_loss` markers do the same and
report the lost count. Invalid event records also break continuity. Malformed
JSON, non-object JSON, or a truncated final line causes analysis to stop before
writing a summary. Preserve the original capture; recover complete lines into a
separate copy if needed. Unmatched and duplicate events are counted
in `quality`. Statistics are streaming population mean/stddev/min/max, not
percentiles. No raw typed text or window titles are copied into analysis output.
The timing unit does not imply nanosecond hardware accuracy.

The optional model learns app + display geometry + previous click cell → next click cell counts,
using 100-point absolute spatial cells by default. It is a personal baseline,
not a complete next-action model or text model. `--cell-size` changes the grid;
`--min-support` controls abstention (default five matching historical examples).
App context must have been enabled during capture to train click predictions. New schema-2 models condition both transitions and the popularity baseline on geometry. `predict(..., display_layout=...)` abstains for unseen layouts; a missing argument cannot borrow known-layout counts.
The first click after a boundary/app change uses a distinct start context.
App switches observed on keyboard or context events also break click continuity,
including switching away and back without clicking in the other app. A context
refresh with missing app identity also resets previous-click history.

Evaluation trains on the oldest 80% of clicks and tests on the remaining 20%,
without updating the model during testing. It reports top-1/top-3 accuracy,
coverage, abstentions, and an app-popularity baseline. Accuracy across all test
clicks counts abstentions as misses; conditional accuracy is also shown. It
uses only context already observed before each target click, and a fixed grid
chosen before testing. This split is exploratory; reserve later unseen days
before choosing model settings or claiming improvement. The exported model is
then fitted on **all** supplied clicks for future use; its training counts must
not be mistaken for the held-out evaluation model.

No live predictions, automatic clicks, screenshot collection, language model,
or cross-app semantic target recognition are implemented here. Absolute cells
change meaning when windows move; recorded display geometry prevents pooling across changed displays, while semantic window movement remains unmodeled. Research and the path
toward richer action labels are recorded in `docs/EVIDENCE.md`.

Run meaningful synthetic checks with:

```sh
python3 -m unittest discover -s tests_python -v
```

They check overlapping key holds, signed intervals, repeats, boundary resets,
mouse holds, sparse-data abstention, private output permissions, and exclusion
of future labels from chronological holdout training.
