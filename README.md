# mTerm — macOS native port of Terminator

A native SwiftUI/AppKit macOS port of [gnome-terminator](https://gnome-terminator.readthedocs.io/).
Arranges terminals in a grid of resizable panes with broadcast-group support, like the original.

> MVP. Splits, tabs, broadcast group, multiple panes per window. Settings, profiles,
> drag-drop rearrange, and plugin host are not implemented yet — see `TODO.md`.

## Build & run

```sh
git clone https://github.com/chengmingbo/mterm.git
cd mterm
swift run mterm
```

Requires macOS 13+, Xcode 16 / Swift 6 toolchain. SwiftTerm 1.20.0 is fetched
at build time.

## MVP controls

| Action | Shortcut |
|---|---|
| New tab | ⌘T |
| Close tab | ⌘W |
| Split horizontally (left/right) | ⇧⌘D |
| Split vertically (top/bottom) | ⇧⌘E |
| Close pane | ⌥⌘W |
| Toggle broadcast group | ⇧⌘G |

Click a pane to make it the active pane — its border highlights and keystrokes
go to it. Toggle broadcast to fan keystrokes out to every pane in the active
broadcast group.

## Architecture

```
Sources/mterm/
├── App.swift             SwiftUI App, menus, AppDelegate
├── ContentView.swift     Tab bar + recursive split tree renderer
├── TabSession.swift      One tab; owns split tree + broadcast state
├── Split.swift           SplitDirection, Split, SplitNode
├── Pane.swift            One terminal pane + PTY host
├── TerminalHost.swift    SwiftTerm LocalProcessTerminalView + delegate
├── TerminalView.swift    NSViewRepresentable wrapper + broadcast fan-out
└── SessionStore.swift    Window-wide state: tabs, active tab
```

`Pane` holds a SwiftTerm `LocalProcessTerminalView` inside a `HostBox` (a
reference box so the NSViewRepresentable can update its broadcast list on
every SwiftUI rebuild). `TabSession.split(.horizontal|.vertical)` rebuilds
the split tree, marking the newly created pane active.

## Next

- Drag-rearrange dividers (already 50/50, no drag yet)
- Persist/restore layouts
- Per-profile colour/font
- Plugins (Terminator's `~/.config/terminator/plugins` equivalent)