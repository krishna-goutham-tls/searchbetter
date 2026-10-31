# SearchBetter app

A menu bar app. Option+Space opens a search box. Results show while you type.
It searches file names, words inside files, and meaning in text, code, PDFs and images.
Nothing leaves the Mac.

## Build and check

    ./build.sh
    build.noindex/SearchBetter.app/Contents/MacOS/SearchBetter --selftest

## Run

    open build.noindex/SearchBetter.app

To use it day to day, run `./install.sh`. It puts the app in /Applications, so Spotlight and Launchpad can open it.

The first run may ask for access to Desktop, Documents and Downloads. Allow all three.

File names work at once. The menu line says what is ready. Passes run in this order: exact words, notes and
PDFs, images, code and data, then a full read of notes and PDFs. Model work stops while the search
box is open, and below 50% battery. The full read runs only on power.

A new build has a new ad hoc signature, so macOS asks for folder access again. Until someone allows
it, the app waits and shows no results.

`build.sh` puts the official llama.cpp `llama-server` (release pinned in the script) in `Contents/Helpers`. The Homebrew build cannot ship: it needs the macOS of the Mac that built it. On first open the setup screen downloads the model `ggml-org/embeddinggemma-2-GGUF`, from a copy on this repo's `model-v1` release, to `~/Library/Application Support/mac-search/models`. A copy in the Hugging Face cache also counts, so a developer Mac skips setup.

`./make-dmg.sh` builds `build.noindex/SearchBetter-<version>.dmg`.

Test first run as a stranger, with no window and no keyboard use: set `CFFIXED_USER_HOME` to an empty folder and run the app binary with `--setup-auto`. `--render-setup <start|downloading|checking|failed|ready> --out x.png` draws the setup screen. `--ignore-power` runs model work on battery.

| Key | Does |
|---|---|
| Option+Space | Open or close the search box |
| Up, Down | Move through results |
| Return | Open the file |
| Command+Return | Show the file in Finder |
| Esc | Clear the search, then close |

## Flags

These never open the search box or take the keyboard:

    SearchBetter --selftest
    SearchBetter --index --root <folder>                 # fill the index for one folder
    SearchBetter --root <folder> --query "text"          # print results and times
    SearchBetter --root <folder> --queries file.txt      # one search per line
    SearchBetter --root <folder> --render "text" --out panel.png

Without `--root` these use the real index of the home folder.

This one opens the search box for one folder, for recording a video:

    open build.noindex/SearchBetter.app --args --root <folder>

This one opens the box and takes the keyboard, so do not run it while someone uses the Mac:

    SearchBetter --show "query" --snapshot /tmp/panel.png

## What it reads

The home folder, minus junk that exists on any Mac: hidden folders, `~/Library`,
`node_modules`, `.git`, `build`, `dist`, `venv`, lock files. Plus apps in `/Applications`
and `/System/Applications`. FSEvents keeps the list current.

Inside files, it reads text and code files up to 1 MB and PDFs up to 100 MB. For images of at least
160 by 300 pixels, Apple's on-device recognition supplies labels and any text in the image. It never reads key files or files with `secret`, `password`, `token`, `credential` or
`api_key` in the name.

The index is at `~/Library/Application Support/mac-search/`, readable only by this user. It holds
the text of each piece and a small copy of each image. Delete that folder to remove it all.
