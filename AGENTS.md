# swiftroom

Use GPT-6.1 Sol; Fast is authorized. No additional threads without parent coordination.
Standalone public repository cgasgarth/swiftroom; never use GitHub Fork. Parent owns PR review and merges.
Never edit original darktable/RapidRAW projects, installed apps, catalogs, or photo libraries.
Import copies into a separate catalog. Never write XMP beside source originals.
No private photos, RAW fixtures, catalogs, builds, screenshots or artifacts in GitHub.
No paid services, unrecognized installs, security changes or silent Xcode license acceptance.

## Ownership and interfaces

- Integration: App/, Core/, Scripts/, Tests/, root configuration.
- Engine: Engine/ and mandatory engine source provenance/license notices.
- Masks Engine owner: Engine/ and new Core/Masks/. Shared Core remains Integration owned.
- UI: UI/. NativePhotoRootView(store: EditorStore) and NativePhotoMetalView(imageURL:zoom:onError:).
- QA: QA/ integration/E2E evidence and tests; report defects to source owner.
- Do not change another owner's files. Coordinate shared API changes with integration lead.
- Core/EngineContract.swift is the typed engine authority. All app Swift files share NativePhoto module.
- NativePhotoEngineFactory.make(cacheDirectory:) supplies any PhotoEngine.
- Core/EditorStore.swift is @MainActor ObservableObject, supplying catalog state/actions to UI.
- Build: ./Scripts/build.sh produces build/swiftroom.app. Test: ./Scripts/test.sh.
- Native SwiftUI/AppKit shell with MetalKit color-managed display. No web UI or canned preview.
- Keep darktable C/C++ processing initially; Metal display is separate from Metal compute.
- Engine outputs real ICC-tagged images. Unsupported capabilities must be reported explicitly.
- Cancellation must stop helper work when feasible. Only current asset/generation can display.
- Slider gestures produce one history entry. Undo branching discards redo. Save retains full edits/history.
- Export freezes current state and never overwrites originals. Failures retain current document state.
- Opaque module state must retain operation/version/instance/enabled/order/parameters/blend data.
- Preserve full XMP and masks. No claim of full parity until verified against darktable coverage inventory.
- Initial window 1440x960; usable minimum 960x640. QA owns first GUI slot after launchable build.

## First-party constraints

- Build first. Only integration/E2E tests; no unit tests or unit scaffolding.
- No added comments or explanatory documents except this AGENTS.md, at most 100 lines.
- Mandatory upstream license notices, provenance and tool-required directives are exempt.
- First-party files at most 1000 lines; at most six direct files per folder, nest further as needed.
- Use Swift 6, complete strict concurrency, warnings as errors and compiler actor checks.
- Use strict available lint tools. Report any justified exception; do not install tools silently.
- No GitHub Actions setup. Reproduce builds and validation locally.

## Host and engine revision

macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4, macOS 27 SDK, Apple Silicon.
xcodebuild is blocked by an unaccepted license; use the direct installed compiler and explicit SDK.
Installed engine candidate: /Applications/darktable.app, version 5.6.0.
Official source: https://github.com/darktable-org/darktable
Release 5.6.0 commit: 3c17b2976793303c186a5f64e8c9635ecf8b15d3.
Engine specialist must retain GPL notices and exact provenance for copied code; copied GPL code is not original/proprietary.
