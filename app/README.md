# mac-search app

A menu bar app. Option+Space opens a search box. Results show while you type.
Stage 1 searches file, folder and app names. Nothing leaves the Mac.

## Build and check

    ./build.sh
    build/mac-search.app/Contents/MacOS/mac-search --selftest

## Run

    open build/mac-search.app

The first run may ask for access to Desktop, Documents and Downloads. Allow all three, then
choose "Read all files again" from the menu bar icon.

| Key | Does |
|---|---|
| Option+Space | Open or close the search box |
| Up, Down | Move through results |
| Return | Open the file |
| Command+Return | Show the file in Finder |
| Esc | Clear the search, then close |

## Demo flags

    mac-search --show "query" --snapshot /tmp/panel.png

Opens the panel with the query typed in, and saves a picture of it. The panel takes the
keyboard, so do not run this while someone uses the Mac.

## What it reads

The home folder, minus junk that exists on any Mac: hidden folders, `~/Library`,
`node_modules`, `.git`, `build`, `dist`, `venv`, lock files. Plus apps in `/Applications`
and `/System/Applications`. FSEvents keeps the list current.
