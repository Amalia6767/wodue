# Contributing

Use a small, focused pull request with a description of the resulting behavior and relevant validation.

Run these checks on macOS before submitting:

```sh
python3 scripts/privacy_check.py
zsh scripts/test.sh
zsh scripts/build.sh
```

Use only fictional event text and reserved example.org/example.com/example.net links in tests and examples. The demo must remain separate from normal app data and must not connect to a real calendar. Do not commit app bundles, data backups, drafts, private URLs or screenshots containing personal calendars.

Tests belong under `Tests/`; generated test data belongs under `.build/`. A fresh installation should remain empty. Keep deadline nodes separate from preparation blocks, preserve completed text, and keep read-only calendar integration read-only.

When changing parsing, cover ambiguity and ordering. A notification's publication time is not its deadline, and a newer notification may move a deadline earlier.
