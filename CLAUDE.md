# Traceworks — notes for Claude

See README.md for layout. Build order matters: `make engine` → `make core` → `make project` → build.
- Rust API changes need `make core` (regenerates `app/Shared/Generated/traceworks_core.swift`); never edit the generated file.
- UniFFI generates `EngineHostImpl`; the Swift engine host is `AppEngineHost`.
- `manual-edits.json` placements are relative to the group centre and do not override literal `pcbX`/`pcbY`; `Project::place` edits literals when they exist.
- Engine smoke test: `cd engine && bun test-engine.ts ../templates/esp32-s3-devboard`.
- Test the open Mac project end to end through MCP: pipe JSON-RPC lines into `build/dd/Build/Products/Debug/Traceworks.app/Contents/MacOS/Traceworks --mcp` (enable MCP in Settings first).
- One studio layout everywhere (`Layouts/StudioWorkspace.swift`, ported from Nurby's StudioView; keep the two in step). Library parts: `PartsCatalog` → `DocumentModel.choose` arms the Place tool; the module is written on first placement.
- The studio's one bar is `StudioBar` (`Layouts/Common.swift`); all views live in `LiveView` and stay loaded. Pass the room the bar and panels cover as `fitInsets` (it includes the bottom safe area); views fit with `ViewTransform.fit(_:in:insets:padding:)`, refit until `userMoved`, then `recentre`.
- Colours follow the view mode (`Palette` in `Views/Theme.swift`): the studio sets `\.palette`, `.tint` and the colour scheme. Read accents from `@Environment(\.palette)` in studio views, not `Theme.accent` (home screen only).
- Deploys go through SelfStore (see ~/Developer/SelfStore/AGENTS.md). It does not re-sign extra executables in the bundle, so keep the Mac app to one binary.
