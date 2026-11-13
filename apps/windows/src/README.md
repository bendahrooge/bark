# Windows interface

Reserved for Bark's Windows interface on the selected Chromium source foundation. There is no native Windows shell, source-build preset, or installer yet.

Keep real Chromium browser tabs, profiles, extension actions, permissions, and sandboxing. A native Windows shell will connect to Chromium's browser objects. The portable Swift state model remains in `packages/core`; SwiftUI/AppKit must not enter the Windows implementation.

Add Windows GN/build tooling, Bark-specific install/profile identities, signing, packaging, extension installation tests, and lifecycle tests before advertising a Windows build. See `engine/chromium/README.md` for the current migration status.
