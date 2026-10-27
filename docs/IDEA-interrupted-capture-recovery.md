# Recover the owner's valid events after an interrupted write

References: OpenAdapt's [producer/writer recorder](https://github.com/OpenAdaptAI/openadapt-capture/blob/6e2e1ad6e882a99b6e6e742a85cb812aee82c59f/openadapt_capture/recorder.py) and Open Record/Replay's [session data contract](https://github.com/humblebanana/open-record-replay/blob/8eff3fa6217810a809b4f1e32ff5273416d36d63/docs/recording-data-contract.md). They motivate preserving the source event stream and validating it before downstream use. This is our original recovery tool, not a copied implementation.

Normal recording/analysis is unchanged. If analysis reports an interrupted tail, turn recording OFF and run:

```sh
python3 scripts/recover_capture.py "/private/path/broken.jsonl" \
  --output "$HOME/Library/Application Support/Ghost Recorder/recovered-session.jsonl"
```

The tool writes a NEW private `0600` copy containing complete original lines plus an explicit boundary/count of discarded bytes. Only a malformed final line without a newline can be discarded, after at least one valid event; interior/terminated corruption and invalid schema still fail. A partial final UTF-8 character is supported. This is an explicit loss decision, not a guarantee that the tail was caused by a crash. Original bytes are untouched; existing outputs are never replaced, and changing sources fail before publication.

Analyze the recovered file **instead of** its original. Keep recovered copies outside the raw Recordings directory and do not pass both copies to the analyzer, which would count the prefix twice. The boundary prevents a held key/button from being paired across the lost tail. Recovery never fabricates missing input or changes the user's settings. Temporary output is private and removed on failure; no raw text is printed.
