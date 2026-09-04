# Vendored dependencies

## KeyboardShortcuts 3.0.1

Copied from https://github.com/sindresorhus/KeyboardShortcuts (MIT, © Sindre Sorhus; license in `KeyboardShortcuts/license`).

Why vendored: Undertone builds with the Command Line Tools alone, and that toolchain ships no SwiftUI macro plugins,
so the package's `@Entry` environment key and `#Preview` blocks do not compile there.

Patch (kept deliberately tiny so upstream updates are easy to re-apply):

- `Sources/KeyboardShortcuts/ConflictPolicy.swift`: `@Entry` replaced with an explicit `EnvironmentKey`.
- `Sources/KeyboardShortcuts/Recorder.swift`: the three `#Preview` blocks removed.
- `Package.swift`: test target dropped; docs, examples and tests not copied.
