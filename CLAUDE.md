# Traces — notes for Claude

The app was called Traceworks: the bundle ID (`com.sammy.traceworks`), Keychain service, Rust crates, `TraceworksCore` and `.traceworks/` project settings keep that name on purpose. User-facing name, Xcode project, schemes (`Traces-iOS`, `Traces-Mac`) and product are Traces.

See README.md for layout. Build order matters: `make engine` → `make core` → `make project` → build.
- Rust API changes need `make core` (regenerates `app/Shared/Generated/traceworks_core.swift`); never edit the generated file.
- UniFFI generates `EngineHostImpl`; the Swift engine host is `AppEngineHost`.
- `manual-edits.json` placements are relative to the group centre and do not override literal `pcbX`/`pcbY`; `Project::place` edits literals when they exist.
- Engine smoke test: `cd engine && bun test-engine.ts ../templates/esp32-s3-devboard`.
- Test the open Mac project end to end through MCP: pipe JSON-RPC lines into `build/dd/Build/Products/Debug/Traces.app/Contents/MacOS/Traces --mcp` (enable MCP in Settings first).
- One studio layout everywhere (`Layouts/StudioWorkspace.swift`, ported from Nurby's StudioView; keep the two in step). Library parts: `PartsCatalog` → `DocumentModel.choose` arms the Place tool; the module is written on first placement.
- The studio's one bar is `StudioBar` (`Layouts/Common.swift`); all views live in `LiveView` and stay loaded. Pass the room the bar and panels cover as `fitInsets` (it includes the bottom safe area); views fit with `ViewTransform.fit(_:in:insets:padding:)`, refit until `userMoved`, then `recentre`.
- Colours follow the view mode (`Palette` in `Views/Theme.swift`): the studio sets `\.palette`, `.tint` and the colour scheme. Read accents from `@Environment(\.palette)` in studio views, not `Theme.accent` (home screen only).
- Deploys: `scripts/deploy.sh` (SelfStore builds iOS → `selfstore/Traces-iOS.ipa`, Mac → GitHub release + `docs/latest.json` for the Pages site). See ~/Developer/SelfStore/AGENTS.md. It does not re-sign extra executables in the bundle, so keep the Mac app to one binary.
