# Preserve the owner's actual keyboard input source

References: Karabiner-Elements optional input-source properties and KeyCastr's separation of native keys from rendered keystrokes; pinned source links are in `REPOSITORY_RESEARCH_2026-10-26.md`.

Key records now carry optional `input_source_id` and `input_source_name`, taken from the currently selected macOS input source without changing it. A `keyboard_layout` record snapshots it at capture start and after a selected-source notification. Layout changes create a boundary so incomplete holds do not cross representations. Legacy schema-1 captures without these optional fields remain readable. This preserves Gavin's chosen layout/IME; Unicode event text still does not prove committed text. No new menu or permission is needed.

Verification: Swift encoding/legacy compatibility test plus the existing capture build and timing-gap tests. Native notification delivery remains owner-unverified; no recorder was started.
