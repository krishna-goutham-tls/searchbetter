# Tracker

Next: Krishna tries his real searches on his own index. Then record the video (LOG 2026-10-30).

## Stage 1: file names (built 2026-10-29)

- [x] Menu bar app, Option+Space hotkey, search panel
- [x] Home folder walk with skip rules, apps included
- [x] Live updates through FSEvents
- [x] Return opens, Command+Return shows in Finder
- [x] Selftest: ranking, skip rules, live updates, timing
- [ ] Krishna uses it for a few days and compares it with Spotlight
- [ ] Start at login
- [ ] Ranking: learn from the files Krishna opens

## Stage 2: meaning search for the demo (built 2026-10-30)

- [x] Read text, code and PDF files, in pieces
- [x] EmbeddingGemma 2 through a llama-server child process
- [x] Images, newest first, with small thumbnails stored in the index
- [x] Binary vectors plus full int8 vectors in RAM
- [x] Exact-word index (SQLite FTS5); common words skip ranking
- [x] One merged list that does not jump; weak matches hidden
- [x] Thumbnails and matching lines in result rows
- [x] `--root` for a safe demo folder; `--index`, `--queries`, `--render` for checks without the panel
- [ ] Krishna starts the index from the menu bar and tries his real searches
- [ ] Choose what goes in the demo folder, and record the video

## After the video

- [ ] Setup screen with progress by folder
- [ ] Pause on battery
- [ ] Word, Excel and PowerPoint files
- [ ] Ship llama-server and the model with the app, in place of the Homebrew and Hugging Face copies

## Later

- Face tagging for "me" (LOG 2026-10-29)
- Audio and video
- Installer for other people
