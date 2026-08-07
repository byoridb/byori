# Byori workspace asset manifest

Authority: Composition C (`byori-workspace-c-sourcetree-first.png`) for layout and Composition A (`byori-workspace-a-balanced.png`) only for the expanded Context treatment.

| Visible region | Chosen medium | Required production asset |
|---|---|---|
| macOS window chrome and centered “Byori” title | System window/title-bar rendering | None |
| Three-column shell, pane backgrounds, and separators | Semantic SwiftUI split views, system materials/colors, and `Divider` | None |
| Project → source tree/worktree → task → session outline | SwiftUI `List`/`DisclosureGroup`, text, shapes, and SF Symbols for folders, branches, tasks, terminal sessions, and disclosure chevrons | None |
| Selection, branch/dirty metadata, and running indicators | SwiftUI text capsules/circles with semantic teal, amber, and status colors | None |
| New Session and Settings actions | Native `Button`/retained Settings window with SF Symbols (`plus`, `gearshape`) | None |
| Breadcrumb, recorded launch provider/model identity, provider-controlled hint, Running, and Stop header | SwiftUI toolbar/text, native button styling, simple shapes, and SF Symbols | None |
| Interactive terminal canvas | Existing SwiftTerm 1.15.0 AppKit host with PTY output and system monospaced text; never a screenshot | None |
| Files / Git / Context tabs | Native SwiftUI segmented/tab navigation and text | None |
| Files inspector tree | SwiftUI outline/list populated from runtime data, with SF Symbols for folders and documents | None |
| Git inspector content | Semantic SwiftUI lists, labels, status colors, and SF Symbols populated from repository state | None |
| Collapsed ByoriDB context disclosure | SwiftUI `DisclosureGroup` plus an SF Symbol database glyph | None |
| Expanded Decision / Module / Task checkpoint records | Restrained SwiftUI grouped rows with SF Symbols (document, cube, bookmark/checkpoint), semantic fills/separators, and runtime provenance text | None |
| Bottom operational status | Compact SwiftUI status row with semantic dots, dividers, progress, Cancel, and verified runtime text | None |

## Production bucket

**Empty.** No build-critical raster, illustration, texture, logo, avatar, or custom icon is required for this surface. Every visible element is native chrome, semantic SwiftUI/AppKit rendering, an SF Symbol, or live SwiftTerm content. The two PNG comps are implementation references only and must not be bundled as UI assets. App-icon/marketing artwork is outside this surface and does not affect workspace fidelity.
