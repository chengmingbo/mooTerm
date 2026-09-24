# mTerm MVP TODO

- [x] Draggable split dividers
- [x] Per-pane title with cwd (track OSC 7)
- [x] Keyboard pane navigation (Cmd+Alt+arrow to move focus)
- [x] Layout save/load (JSON on disk)
- [ ] Profiles (font, colour, shell)
- [ ] Drag-drop pane rearrange
- [ ] Settings window (SwiftUI .settings scene)
- [ ] Drag-reorder tabs
- [ ] Plugin host (Python? JS via bundled interpreter?)
- [ ] CI: build on tag → universal .app + DMG
- [ ] Code-signing + notarization
- [ ] Localisation

## From iTerm2 (next)

- [ ] Global hotkey window (reuse DropTerm's Carbon HotKey)
- [ ] Jump between prompts (⇧⌘↑/↓) using SwiftTerm's OSC 133 marks
- [ ] Notify when a long-running command finishes in a background tab
- [ ] ⌘-click to open URLs and file paths
- [ ] Copy on select, Option-as-Meta toggle, scrollback size (Settings window)
- [ ] Profiles and per-pane badges
- [ ] Session restore on relaunch (tabs, splits, directories)
