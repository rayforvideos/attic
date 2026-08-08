<div align="center">

<img src="https://rayforvideos.github.io/attic/icon.png" width="120" alt="Attic">

# Attic

**Finds the files you stopped using but never deleted.**

App caches, stale build output, downloads you forgot about. Attic finds what is scattered
across your Mac. Only what you pick goes to the Trash, and nothing is deleted on its own.

[![Latest](https://img.shields.io/github/v/release/rayforvideos/attic?label=latest&color=7fb2e5&style=flat-square)](https://github.com/rayforvideos/attic/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/rayforvideos/attic/total?label=downloads&color=7fb2e5&style=flat-square)](https://github.com/rayforvideos/attic/releases)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-1b2027?style=flat-square)](https://github.com/rayforvideos/attic/releases/latest)
[![MIT](https://img.shields.io/badge/license-MIT-1b2027?style=flat-square)](LICENSE)

**[Website](https://rayforvideos.github.io/attic/)** · **[Download](https://github.com/rayforvideos/attic/releases/latest)** · **[한국어](README.ko.md)**

<img src="https://rayforvideos.github.io/attic/screenshot.png" width="400" alt="Attic">

</div>

## What it finds

| Kind | Details |
|---|---|
| **App caches** | Web caches from browser-based apps, per-app temporary files |
| **Stale build output** | Xcode derived data, device support files, package manager caches, unused `node_modules` |
| **Forgotten downloads** | Installers you already used, old screenshots, large files |
| **Old release archives** | `.xcarchive` bundles you shipped long ago |
| **Things running quietly** | Programs that launch at login or boot, startup entries left behind by deleted apps |

What rebuilds itself is kept separate from what is gone for good. Anything irreversible stays
out of "select all caches" and is shown with the folder it lives in.

## What it will not do

You are handing it your disk, so what it refuses to do comes first.

**Only what you pick, and only to the Trash.** Nothing is deleted on its own.

**It never invents a number.** If a size could not be measured, the item is left out and you
are told. If a folder could not be read all the way through, it will not claim there is
nothing to clean.

**It measures again right before moving.** A scan result can be stale. The freed space you
see is measured at the moment it happens.

**It says when something cannot come back.** A cache rebuilds itself. A photo someone sent
you does not. It only claims what it knows.

**It moves inside an allowlist.** The places it may touch are fixed in advance, everything
else is refused, and it verifies once more right before acting.

## Install

**[Download the latest release](https://github.com/rayforvideos/attic/releases/latest)**

Open the DMG and drag Attic to your Applications folder. Launch it and a disk icon appears in
the menu bar. It is notarized by Apple, so it opens without warnings.

Requires macOS 26 or later. Universal binary: Apple Silicon and Intel.

## Permissions and network

**Full Disk Access.** Finding caches means looking inside other apps' folders, and macOS asks
for each app separately. Grant it once from the prompt inside the app and it stops asking.

**The network is used only to check for a new version.** It reads the latest version number
and sends nothing about you or what it found. You can turn it off in Settings.

## Updates

Attic downloads and replaces itself. Before replacing, it verifies that the downloaded app
carries the same developer signature and passed notarization; if either check fails, nothing
is installed. The old version is moved to the Trash rather than deleted.

## Contributing

PRs are welcome. All you need is `swift test` passing. You do not have to build or sign the
app: the logic lives in `AtticCore` and is verified by tests.

This app deletes things on other people's disks, so there are rules. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) first.

## License

[MIT](LICENSE). Use it, change it, ship it, sell it. Just keep the copyright notice.

Copyright (c) 2026 Sangjun Park
