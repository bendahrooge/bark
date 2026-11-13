# Linux interface

Reserved for Bark's Linux interface. The selected foundation is now Chromium source, configured by `engine/chromium/args/linux-x64.gn` and `tools/chromium.py`. A remote x86-64 Linux VM can build this foundation; there is no finished native Linux shell or installer yet.

Keep real Chromium browser tabs, profiles, extension actions, permissions, and sandboxing. Implement the sidebar against those browser objects. Portable state models remain in `packages/core`; choose the Linux UI toolkit when implementing the interface. SwiftUI/AppKit remain macOS-only.

Packaging, X11/Wayland behavior, extension installation, sandbox checks, and native UI tests remain required before distribution. See `engine/chromium/README.md` for build-host requirements and commands.
