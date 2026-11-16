# XcodeRunner

<img width="1377" height="924" alt="Screenshot 2026-11-16 at 6 04 19 PM" src="https://github.com/user-attachments/assets/6d35b482-3570-4bfc-9ee1-888e1b225ef6" />

**Review AI-generated changes. Test on your device. Keep Xcode closed.**

A lightweight native Mac companion for developers working with Codex, Cursor, VS Code, or another editor. Follow the code changes your AI tool makes, decide when to build, and validate the results on an iPhone, iPad, or simulator.

## Is it for you?

Try XcodeRunner if your project already builds in Xcode and you want to stay in control of AI-driven development without keeping the full IDE running. Keep more headroom for your editor and AI tools while reviewing changes and manually testing your app.

Xcode still handles project setup, signing configuration, debugger sessions, and distribution. XcodeRunner uses your installed Xcode toolchain and existing project settings.

## Why use XcodeRunner?

- **Reduce IDE overhead:** keep Xcode’s editor and debugger closed during routine development, avoiding their ongoing memory use and background work.
- **Review what the AI changed:** inspect live Git diffs, staged/unstaged changes, line counts, edit times, and the current branch.
- **Validate on your terms:** choose a device and press **⌘R** to build, install, and launch. File changes never trigger builds automatically.
- **Check the results:** follow build progress and live app logs, with clickable warnings and errors.
- **Manage multiple projects:** import a folder, queue runs, and use menu-bar controls for quick access.
- **Prepare a release:** update version/build numbers, archive, and continue in Xcode Organizer.

## Resource use

In one development-session snapshot on November 16, 2026:

| Running software | Physical memory footprint |
|---|---:|
| Xcode 27 and related helpers | **~3.4 GiB** |
| XcodeRunner  | **55 MiB** |

Measured with macOS `vmmap`; Xcode’s debugger alone accounted for ~2.8 GiB. This is an example, **not a matched-workload benchmark or guaranteed saving**. Build tools and simulators still need CPU and RAM. CPU savings have not yet been benchmarked. [Measurement details](docs/APP_DESIGN.md#memory-measurement).

## Requirements

- macOS 14 or later, with full Xcode installed and its first-launch setup completed.
- An iOS/iPadOS project with a runnable app scheme and working signing configuration.
- For physical devices: pairing/trust completed and Developer Mode enabled.

## Give it a try

1. Download the `.dmg` from [GitHub Releases](https://github.com/jtCodes/XcodeRunner/releases), open it, and copy **XcodeRunner** to **Applications**.
2. Open XcodeRunner and use **+** in the sidebar to add a project, workspace, or folder.
3. Select an app scheme and destination, then press **Run** or **⌘R**.

To build from source, open `XcodeRunner.xcodeproj` in Xcode, choose **My Mac** and your signing team, then run.

Build/install/launch jobs run one at a time; additional runs are queued. Git review is read-only; staging, committing, and pushing are outside the current feature set. Archiving opens Xcode for the Organizer handoff.

For detailed behavior, implementation notes, and contributor checks, see [App design and behavior](docs/APP_DESIGN.md).
