# mTerm — macOS native port of Terminator

A native SwiftUI/AppKit macOS port of [gnome-terminator](https://gnome-terminator.readthedocs.io/).
Arranges terminals in a grid of resizable panes with broadcast-group support, like the original.

> Splits, tabs, broadcast groups, themes, saved layouts, and iTerm2-style
> navigation. Settings, profiles, drag-drop rearrange, and a plugin host are not
> implemented yet — see `TODO.md`.

## Build & run

```sh
git clone https://github.com/chengmingbo/mterm.git
cd mterm
swift run mterm
```

Requires macOS 13+, Xcode 16 / Swift 6 toolchain. SwiftTerm 1.20.0 is fetched
at build time.

## Controls

| Action | Shortcut |
|---|---|
| New tab (opens in the current directory) | ⌘T |
| Close tab | ⌘W |
| Select tab 1–8 / last tab | ⌘1 … ⌘8 / ⌘9 |
| Next / previous tab | ⇧⌘] / ⇧⌘[ |
| Split side by side | ⌘D or ⇧⌘E |
| Split stacked | ⇧⌘D |
| Close pane | ⌥⌘W |
| Move to pane left / right / above / below | ⌥⌘← ⌥⌘→ ⌥⌘↑ ⌥⌘↓ |
| Next / previous pane | ⌘] / ⌘[ |
| Zoom pane (+2pt) / maximise pane | ⇧⌘Z / ⇧⌘X |
| Toggle broadcast group | ⇧⌘G |
| Find / next / previous / use selection | ⌘F / ⌘G / ⇧⌘G / ⌘E |
| Clear buffer (screen + scrollback) | ⌘K |
| Bigger / smaller / reset font | ⌘= or ⌘+ / ⌘- / ⌘0 |
| Save layout | ⇧⌘S |
| Settings (scrollback lines, font, theme, dimming) | ⌘, |

Natural text editing, as in iTerm2 (translated to readline/zle sequences):

| Keys | Effect |
|---|---|
| ⌘← / ⌘→ | Start / end of line (⌃A / ⌃E) |
| ⌥← / ⌥→ | Back / forward one word |
| ⌘⌫ | Delete to start of line (⌃U) |
| ⌥⌫ / ⌥⌦ | Delete previous / next word |

Control keys such as ⌃A, ⌃E, ⌃L, ⌃R, ⌃U go to the shell unchanged.

Drag a divider to resize panes; double-click it to split evenly. Clicking
into a pane makes it active, and inactive panes are dimmed (View → Dim
Inactive Panes). Tabs show a dot for new output and a bell when the shell
rings. Closing a pane, tab, or the app asks first if a program is still
running.

Scrollback defaults to 10,000 lines per pane. Change it in Settings (⌘,),
from 0 (off) to 1,000,000; open panes resize their history immediately.

Shells belong to their panes, so splitting, zooming, and switching tabs never
restart them. When a shell exits, its pane closes.

## Build a .app

```sh
bash scripts/build.sh            # Packaging/mterm.app
bash scripts/build.sh --install  # also replace /Applications/mterm.app
bash Packaging/make-icns.sh      # regenerate the icon from Resources/mterm_logo.png
```

## Architecture

```
Sources/mterm/
├── App.swift                AppDelegate, menus, focus sync, quit confirmation
├── ContentView.swift        Tab bar + recursive split tree with draggable dividers
├── TabSession.swift         One tab: split tree, active pane, navigation, broadcast
├── Split.swift              SplitDirection, PaneNavigation, SplitNode
├── Pane.swift               One pane; owns its TerminalHostView (and shell)
├── PaneView.swift           Pane header, terminal, context menu, dimming
├── TerminalHost.swift       NSViewRepresentable that re-parents the pane's terminal
├── TerminalHostView.swift   ONLY file that imports SwiftTerm
├── NaturalTextEditing.swift iTerm2-style ⌘/⌥ editing keys
├── CloseConfirmation.swift  "program still running" prompts
├── SettingsView.swift       Settings window (⌘,)
├── TerminalPreferences.swift Scrollback size and other terminal prefs
├── SessionStore.swift       Window-wide state: tabs, active tab
├── LayoutStore.swift        Saved layouts (JSON in Application Support)
└── ColorScheme / FontSizeStore / WindowStore / AccentColor
```

## Next

- Persist/restore layouts
- Per-profile colour/font
- Plugins (Terminator's `~/.config/terminator/plugins` equivalent)