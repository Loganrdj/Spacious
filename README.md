# Spacious

Split every monitor into your own grid and give each app its place, all from the menu bar.

Spacious is a macOS menu bar app for people with several monitors. Divide each display into any grid you like (2×1, 3×2, 20×10, and so on), drag across cells to create **zones**, and assign apps to them. For example: *left half of the widescreen → Chrome, the vertical monitor → Slack on top and Terminal below.* Then click **Apply** and every window moves into place.

The app runs entirely on your Mac, with no accounts, no backend, and no network.

## Features

- **Monitor map**: shows your displays in their actual physical arrangement. Click one to edit it.
- **A custom grid for each monitor**: up to 48×48. Choose a quick layout (halves, thirds, quarters, and so on) or draw your own zones on a fine grid.
- **Assign apps, windows, or websites to zones**:
  - **App**: all of its windows. If an app is assigned to several zones, its windows are spread across them.
  - **Window**: one specific window, matched by its title (for example, a Notes window titled "Groceries").
  - **Website**: a browser tab such as `mail.google.com`. On Apply, Spacious moves the tab into a window of its own, keeping the page intact, and places that window. If the site isn't open, Spacious opens it. Works with Chrome, Safari, Edge, Brave, and Vivaldi. Firefox doesn't let other apps read its tabs.
- **Minimum window sizes**: some apps (Spotify, for example) can't shrink below a certain size. Spacious measures this, marks zones that are too small with ⚠︎, and offers *Grow zone to fit*.
- **Multiple layouts**: for example "Coding" and "Meeting". Switch and apply from the menu or with a hotkey.
- **Snap any window**: press <kbd>⌃⌥Space</kbd>, then click a zone or drag across cells.
- **Shift-drag**: hold <kbd>Shift</kbd> while dragging a window to see the zones, then drop it into one.
- Adjustable gaps, custom hotkeys, launch at login, and an option to open assigned apps that aren't running.
- Remembers grids for monitors that are unplugged and uses them again when the monitor comes back.

## Install

Download the latest `Spacious-x.y.z.dmg` from [Releases](https://github.com/Loganrdj/Spacious/releases), drag Spacious to Applications, and open it.

On first launch, macOS asks you to allow **Accessibility** access (System Settings → Privacy & Security → Accessibility). Spacious needs it to move other apps' windows.

The first time you assign a website, macOS asks whether Spacious may control your browser (**Automation**). Spacious uses that only to read tab addresses and move the tabs you assigned.

## Build from source

Requirements: macOS 14+, Xcode 15+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate          # creates Spacious.xcodeproj from project.yml
open Spacious.xcodeproj    # then Run (⌘R)

swift test --package-path Packages/SpaciousCore   # unit tests
scripts/release.sh 0.1.0                          # build a DMG into build/
```

`project.yml` signs Debug builds with an Apple Development certificate, so the Accessibility permission stays granted across rebuilds. To use your own certificate, change `DEVELOPMENT_TEAM` in `project.yml`.

## Project layout

```
Packages/SpaciousCore/   Platform-neutral model + geometry (grid math, coordinates, JSON store) + tests
Spacious/Platform/       macOS integration: displays, Accessibility window control, hotkeys, overlays
Spacious/UI/             SwiftUI menu bar interface
scripts/                 release.sh (DMG + notarization), make-icon.swift
.github/workflows/       CI (build + tests) and tagged releases
```

Layouts are stored in `~/Library/Application Support/Spacious/layouts.json`. Zones are saved in **cell units** rather than pixels, so they survive resolution changes. The format is platform-neutral so it can be shared with a future Windows version.

## Releasing

Push a tag such as `v0.1.0`, and GitHub Actions builds the DMG and attaches it to a GitHub Release. To produce a signed and notarized build, add these repository secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERT_P12` | base64 of your *Developer ID Application* certificate exported as .p12 |
| `CERT_PASSWORD` | password for the .p12 |
| `APPLE_TEAM_ID` | your team ID |
| `APPLE_ID` | Apple ID email used for notarization |
| `APP_SPECIFIC_PASSWORD` | an [app-specific password](https://support.apple.com/102654) |

Without these secrets, the release contains an unsigned DMG. To open it, right-click the app and choose **Open**.

## Roadmap

- [x] macOS menu bar app
- [ ] Windows version (paused until the Mac app is complete)

## License

MIT
