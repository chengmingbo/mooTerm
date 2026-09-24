# mTerm — macOS native port of Terminator

A native SwiftUI/AppKit macOS port of [gnome-terminator](https://gnome-terminator.readthedocs.io/).
Arranges terminals in a grid of resizable panes with broadcast-group support, like the original.

> Splits, tabs, broadcast groups, themes, saved layouts, and iTerm2-style
> navigation, plus a Settings window. Profiles, drag-drop rearrange, and a
> plugin host are not implemented yet — see `TODO.md`.

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
| Settings (scrollback lines, font, theme, dimming, Claude model) | ⌘, |
| Claude panel: open / focus / close | ⇧⌘A |

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

## Claude panel

The thin activity bar on the far left holds tool buttons (Claude first, and
Settings at the bottom). Click a button to open its panel; click it again to
close it. The Claude panel (⇧⌘A) turns plain language into shell commands for
the active pane:

1. Type what you want — "10 largest files under here", "which process is on
   port 3000", "why did the last command fail?" — and press Return.
2. Claude (through your installed [Claude Code](https://claude.com/claude-code)
   CLI) answers with one command line, usually a pipeline, plus a risk badge:
   **Read-only**, **Modifies**, or **Destructive**.
3. Edit it if you like, then **Run** (⌘↩) to type it at the prompt and press
   Return, **Insert** to put it on the prompt without running, or copy it.

Details:

- Claude sees the pane's directory, your shell, and the last 40 lines of
  output, so follow-ups ("only .swift files", "sort that by size") and
  questions about errors work. It gets no tools: it can't run anything itself.
- Risk is the higher of Claude's rating and a local pattern check (`rm -r`,
  `sudo`, `-delete`, `git push --force`, `curl | sh`, …). Destructive commands
  always ask for confirmation.
- ⚡ auto-run (off by default) runs read-only commands as soon as they arrive.
- `!command` runs a command exactly as typed, without asking Claude.
- If a program like `vim` is in the foreground, Run refuses instead of typing
  into it. With broadcast on, the command goes to every pane in the group.
- The model is set in Settings (default Haiku, fastest). Log in once with
  `claude auth login`.
- Proxy: command-line tools ignore the macOS system proxy, and a Dock-launched
  app has no `http_proxy` variables, so requests could fail with
  "403 Request not allowed". Settings → Network → Proxy **Automatic** (default)
  passes the system proxy (e.g. Clash's `127.0.0.1:7890`) to `claude` as
  `http_proxy`/`https_proxy`/`all_proxy`; **Custom** takes a URL; **None**
  removes them. "Also set in new terminal panes" exports the same variables in
  new shells (off by default). A `claude` alias in your shell still applies.

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
├── ActivityBar.swift        Thin left tool column; SidebarItem list
├── AssistantPanelView.swift Claude panel UI (left sidebar)
├── CommandAssistant.swift   Request → command proposals, risk checks, running
├── ProxySettings.swift      System/env/custom proxy → http_proxy variables
├── ClaudeCLI.swift          Runs `claude -p` with structured output via the login shell
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