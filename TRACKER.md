# Tracker

Next: friend test on another Mac, then Krishna records the Spotlight race on his own account and the agent checks every frame. Then the landing page at searchbetter.thelaunch.space.

Before launch: Developer ID signing, menu bar icon, start at login, formal trademark check on SearchBetter.

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
- [x] Images through Apple Vision labels and text, with small thumbnails stored in the index
- [x] Indexing in passes: words, notes and PDFs, images, code and data, deep read on power
- [x] Your own folders first, status that says what is ready, pause on battery
- [x] Binary vectors plus full int8 vectors in RAM
- [x] Exact-word index (SQLite FTS5); common words skip ranking
- [x] One merged list that does not jump; weak matches hidden
- [x] Thumbnails and matching lines in result rows
- [x] `--root` for a safe demo folder; `--index`, `--queries`, `--render` for checks without the panel
- [ ] Krishna tries his real searches
- [ ] Choose what goes in the demo folder, and record the video

## After the video

- [ ] Stable signing, so a new build does not ask for folder access again
- [ ] Read text in scanned PDFs with Apple Vision
- [ ] Optional image model pass, if real searches show the labels are too general
- [ ] Word, Excel and PowerPoint files
- [x] Ship llama-server in the app, download the model on a setup screen, pack a DMG
- [ ] Friend test on another Mac: Open Anyway, three folder prompts, setup, search

## Later

- Face tagging for "me" (LOG 2026-10-29)
- Audio and video
