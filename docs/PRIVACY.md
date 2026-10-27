# Privacy and publication boundaries

WoDue is a local macOS app. It has no app-owned backend, analytics SDK, advertising SDK, email connector or Canvas credential store.

## What is read

- Text you explicitly paste or import. The clipboard is not monitored in the background.
- Events from calendars you connect and select through macOS EventKit. The app uses read-only operations even though macOS requires full calendar permission for reading events.
- The app's own JSON documents and preferences.

Cloud calendar synchronization belongs to macOS and the calendar provider. Opening a link uses the system browser and visits that destination.

## What is saved

Tasks, copied calendar events, notes, imported original text, meeting details, draft text, focus sessions and reminder decisions are saved locally. Completing a calendar item changes only the app's local state.

Normal documents live under `~/Library/Application Support/io.github.amalia6767.wodue/`. `--data-dir` can select a different directory. Demo documents live under the ignored `.build/demo-data/` directory and calendar connection is disabled in demo mode.

macOS manages notification authorization and delivery. Notification content includes task titles and dates, so it may be visible in Notification Center or on the lock screen according to your macOS settings.

Meeting acknowledgment and snooze records are saved locally in `event-reminders.json` and excluded from source control. Meeting notification actions resolve the current link from the local task; they do not store the full meeting URL or passcode in notification metadata.

## What belongs in the public repository

Only source code, documentation, generated illustrations and fictional fixtures. All example meeting links use reserved documentation domains; placeholder meeting IDs and passcodes are not live credentials. Personal data and the original development history are not part of this public export.

`.gitignore` and `scripts/privacy_check.py` help reject app data, generated bundles, credentials, private meeting URLs, real course links and local workstation paths. The scanner is not proof that arbitrary prose or an image is safe; review screenshots and example text manually.

When reporting a bug, reproduce it with fictional data. Share the smallest relevant example rather than an entire data directory, inbox or calendar export.
