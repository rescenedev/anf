# anf — all new finder

A native macOS file manager that blends **Finder**, **Windows Explorer**, and the
classic orthodox **Mdir / Norton Commander** style into one fast, keyboard-driven,
**zero-config** app. Built with SwiftUI + AppKit, no Electron, no setup.

```
./build.sh run      # build + launch
./build.sh          # build anf.app only
```

Requires only the Swift toolchain (Command Line Tools is enough — no full Xcode).

---

## Highlights

- **Multi-pane** layouts: single · dual · **quad (2×2)**, each pane fully independent.
- **Tabs** in every pane (⌘T / ⌘W / ⌘1–9).
- **Four views**: Icons · List · Columns (Miller) · Gallery, switchable per tab.
- **Quick Look** preview (Space) + a live preview/metadata inspector.
- **Orthodox pane-to-pane transfer**: F5 copy · F6 move (Mdir style).
- **Favorites** you pin yourself, persisted automatically.
- **Quick-jump palette** (⌘P) — fuzzy-jump to any favorite or subfolder.
- **Zero-config persistence**: layout, panes, tabs, view modes and favorites are
  saved and restored across launches with no setup.
- Background directory I/O, cached icons & Quick Look thumbnails — stays smooth on
  folders with thousands of items.

---

## Keyboard map

### Navigation
| Key | Action |
|-----|--------|
| `↑` `↓` | Move selection (hold `⇧` to extend) |
| `→` / `⌘↓` | Open / enter |
| `←` | Back |
| `⌘[` / `⌘]` | Back / Forward |
| `⌘↑` | Enclosing folder |
| `Space` | Quick Look |
| `⌘L` / `⌘⇧G` | Go to Folder (type or paste a path) |
| `⌘P` | Quick-jump palette |
| `Tab` | Switch active pane (orthodox) |

### Tabs & panes
| Key | Action |
|-----|--------|
| `⌘T` / `⌘W` | New / close tab |
| `⌘1`…`⌘9` | Select tab |
| `⌘⌥1` / `⌘⌥2` / `⌘⌥4` | Single / dual / quad layout |
| `F5` / `F6` | Copy / move selection to the other pane |

### File actions
| Key | Action |
|-----|--------|
| `Return` | Rename (multi-select → batch find/replace) |
| `⌘C` / `⌘V` | Copy / paste files |
| `⌘⌫` | Move to Trash |
| `⌘D` / `⌘⇧D` | Duplicate / pin to favorites |
| `⌘⌥C` | Copy path |
| `⌘A` | Select all |
| `⌘⇧N` | New folder |
| `⌘ +` / `⌘ -` | Bigger / smaller (icon size or list text) |
| `⌘I` | Info inspector |
| `⌘R` | Reload |

Right-click a file/folder or empty space for the same actions, plus
**Open Terminal Here**, **Copy Path**, and folder size calculation (inspector).

---

## Architecture

```
Sources/anf/
  App/            main.swift (AppKit bootstrap), KeyboardController, MainMenu
  Models/         FileItem, ViewMode, SidebarItem
  ViewModels/     BrowserModel (one tab) · Workspace (Pane/Workspace/Favorites)
  Services/       FileSystemService (bg I/O), IconProvider, ThumbnailProvider,
                  FileOperations
  Views/          RootView, Toolbar, Sidebar, Pane (layout/tabs), Content
                  (icon/list/column/gallery), Detail (inspector), Palette, Common
```

Model layering: **`BrowserModel`** (one tab's state) → **`PaneModel`** (a stack of
tabs) → **`WorkspaceModel`** (layout + 4 panes + favorites). The active pane's
active tab is what the toolbar, sidebar and keyboard all act on.

### Why AppKit bootstrap instead of SwiftUI `App`/`WindowGroup`?
When built with Command Line Tools (no full Xcode), SwiftUI's scene lifecycle does
not launch reliably — `App.init` runs but `applicationDidFinishLaunching` never
fires, so no window appears. `anf` drives AppKit directly: it creates the `NSWindow`
and hosts the SwiftUI tree in an `NSHostingController`, which is robust everywhere.
