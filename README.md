# Grimmory plugin for KOReader

This plugin syncs a Grimmory library to a local KOReader folder. It uses the
versioned KOReader library sync endpoint, including server-side snapshot deltas
via `x-booklore-synctoken`.

## Install

Copy `grimmory.koplugin` into KOReader's `plugins` directory and restart
KOReader.

## Configure

Open `Tools -> Grimmory` in KOReader and set:

- `Server`: the Grimmory base URL, for example `http://192.168.1.10:8080`
- `User`: the Grimmory KOReader sync username
- `Auth key`: the KOReader sync key, matching Grimmory's existing progress sync
- `Sync folder`: where downloaded books should be placed

Then run `Sync library now`.

## Behaviour

- **Delta sync.** Only added, changed, and removed books are transferred, tracked
  by the server snapshot token (`x-booklore-synctoken`).
- **Content-hash currency.** A book is re-downloaded only when its server-side
  content hash changes, not when its size or metadata changes. Files already on
  the device are skipped, and a book that merely moved on the server is relocated
  locally instead of re-downloaded.
- **Progress and cancel.** Large syncs show per-book progress; tap the message to
  abort. Downloaded files are kept, and the sync resumes cleanly next time.
- **Interruption-safe.** The sync token only advances once a run finishes, so an
  interrupted sync restarts against the last completed point without losing or
  needlessly re-downloading books.
