# mac-search app

A menu bar app. Option+Space opens a search box. Results show while you type.
It searches file names, words inside files, and meaning in text, code, PDFs and images.
Nothing leaves the Mac.

## Build and check

    ./build.sh
    build/mac-search.app/Contents/MacOS/mac-search --selftest

## Run

    open build/mac-search.app

The first run may ask for access to Desktop, Documents and Downloads. Allow all three, then
choose "Read all files again" from the menu bar icon.

File names work at once. To search inside files, choose "Start indexing file contents" from the
menu bar icon. The menu line says what is ready. Passes run in this order: exact words, notes and
PDFs, images, code and data, then a full read of notes and PDFs. Model work stops while the search
box is open, and below 50% battery. The full read runs only on power.

A new build has a new ad hoc signature, so macOS asks for folder access again. Until someone allows
it, the app waits and shows no results.

It needs `llama-server` (`brew install llama.cpp`) and the model `ggml-org/embeddinggemma-2-GGUF`
(Q8_0) in the Hugging Face cache.

| Key | Does |
|---|---|
| Option+Space | Open or close the search box |
| Up, Down | Move through results |
| Return | Open the file |
| Command+Return | Show the file in Finder |
| Esc | Clear the search, then close |

## Flags

These never open the search box or take the keyboard:

    mac-search --selftest
    mac-search --index --root <folder>                 # fill the index for one folder
    mac-search --root <folder> --query "text"          # print results and times
    mac-search --root <folder> --queries file.txt      # one search per line
    mac-search --root <folder> --render "text" --out panel.png

Without `--root` these use the real index of the home folder.

This one opens the search box for one folder, for recording a video:

    open build/mac-search.app --args --root <folder>

This one opens the box and takes the keyboard, so do not run it while someone uses the Mac:

    mac-search --show "query" --snapshot /tmp/panel.png

## What it reads

The home folder, minus junk that exists on any Mac: hidden folders, `~/Library`,
`node_modules`, `.git`, `build`, `dist`, `venv`, lock files. Plus apps in `/Applications`
and `/System/Applications`. FSEvents keeps the list current.

Inside files, it reads text and code files up to 1 MB and PDFs up to 100 MB. For images of at least
160 by 300 pixels, Apple's on-device recognition supplies labels and any text in the image. It never reads key files or files with `secret`, `password`, `token`, `credential` or
`api_key` in the name.

The index is at `~/Library/Application Support/mac-search/`, readable only by this user. It holds
the text of each piece and a small copy of each image. Delete that folder to remove it all.
