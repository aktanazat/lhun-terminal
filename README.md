# Lhûn

Lhûn is an iPad-first SSH terminal for tmux sessions on a Mac and a Linux server. The same app runs on iPhone. It is written in Swift and SwiftUI. [SwiftTerm](https://github.com/aktanazat/SwiftTerm) provides the terminal emulator and renderer; [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh) provides SSH. Lhûn is not Rex, which is a separate product by Superlogical.

This repository contains source code only. No signed app, TestFlight build or installer is provided. No general license for Lhûn's original code has been selected; publishing source is not itself an open-source license grant. Bundled fonts retain their own terms, recorded in [artwork and font notices](Lhun/ProgramIcons-LICENSE.md).

## Build

Use a Mac with Xcode 26 or later, its command-line tools, an iOS 26 or later simulator/runtime, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Swift package requires Swift tools 6.2. This source was built with Xcode 27.1; older supported Xcode versions have not been checked for this snapshot.

From this checkout:

```sh
xcodegen generate
open Lhun.xcodeproj
```

Choose the `Lhun` scheme and an iPad or iPhone simulator, then Run. Xcode fetches the public packages declared in `Package.swift`. The generated project is not tracked. The pinned SwiftTerm fork adds Lhûn's rendering changes and includes a build-information plugin. Inspect and approve that plugin in Xcode when prompted. The library remains attributed to its upstream authors under its MIT license.

For a command-line build, choose a simulator from `xcrun simctl list devices available`. Use its actual identifier, not a device name copied from somebody else's Mac:

```sh
xcodebuild -project Lhun.xcodeproj -scheme Lhun \
  -configuration Debug -destination 'id=YOUR_SIMULATOR_UDID' \
  CODE_SIGNING_ALLOWED=NO build
```

Approve the package plugin in Xcode before using this command. Do not override the SDK globally with `-sdk iphonesimulator`: build-tool executables must run on the Mac, not the simulator. On a physical device, choose your own signing team and a unique app bundle identifier in Xcode. No team or physical-device identifier is supplied by this repository. Changing the bundle identifier also requires updating `LhunDefaults.lhunApp` so the standalone app keeps using its own settings store.

## First run and pairing

A fresh install has no hosts and makes no SSH connection until a host is paired. There are two named places, Mac and Server. Pairing a replacement in a place disconnects that place's open terminals; it does not terminate the old machine's tmux sessions.

On a device, Lhûn creates a P-256 identity in the Secure Enclave. A simulator has no Secure Enclave: its software identity is kept in that app installation's Application Support folder. Reinstalling after deleting the app loses the simulator identity. Neither build imports a developer's existing SSH identity or authorizes itself on any host.

The standard setup uses Tailscale for reachability:

1. Install and sign in to Tailscale on the device and the host. Enable SSH on the host. On macOS, enable Remote Login in System Settings → General → Sharing. Install tmux (`brew install tmux` on macOS, or your Linux package manager).
2. In Lhûn, open **Pair a Mac or Server** and choose **Copy Setup**. Paste the script into a terminal on the host you intend to pair. Read it first: it adds this app's public key to that account's `~/.ssh/authorized_keys`, sets its permissions, checks reachability prerequisites, and prints a pairing link containing the host's address, account name and public host keys. It does not copy a private key.
3. Paste the resulting link in Lhûn, scan its QR code with Camera if `qrencode` is installed, or open the link on the device. Check the displayed machine, account, address and port before choosing **Pair**. Only obtain this link from the host through a channel you trust. A link supplied by someone else could direct the app to their machine.
4. When the host is online, press **+** to start a tmux session, or select one that already exists. The command palette (**⌘K**) also opens, renames, splits, shares and closes sessions. Closing a terminal view detaches it; **Kill Session** ends the host session.

The setup script targets ordinary SSH on port 22 and uses Tailscale's IPv4 address. It does not install SSH, tmux or Tailscale, change firewall rules or grant Tailscale access. A failing prerequisite must be fixed on the host before pairing.

### Other SSH addresses and optional browser editor

LAN addresses and nonstandard SSH ports can use the same real pairing path. Add the app's public key to the intended account yourself, then construct a URL with percent-encoded values:

```text
lhun://pair?role=server&name=My%20server&address=192.0.2.10&user=developer&port=2222&key=ENCODED_PUBLIC_HOST_KEY
```

`192.0.2.10` is a documentation address, not a working host. Replace it with an address reachable from the device. `role` is `mac` or `server`; `port` is optional and defaults to 22. Each repeated `key` value is an entire public host-key line's first two fields, percent-encoded. Supported types are Ed25519 and ECDSA P-256/P-384/P-521. Obtain the public keys directly from your own host, not an unauthenticated network scan. Password authentication and trust-on-first-use are not implemented. A changed host key stops the connection until you deliberately pair the host again.

To retain the **Open VS Code** command, include an optional `code` query parameter in the Mac's pairing link. Its value is the percent-encoded HTTP or HTTPS URL of your own browser editor. No editor URL or editor service is bundled. URLs containing a username or password are rejected. Lhûn opens that URL; it does not install an editor or forward its port automatically.

## Sessions and tools

The host owns the tmux processes. Leaving the app or losing the network does not end them. Lhûn reconnects and reattaches to the selected sessions. Each tab keeps a workspace with one terminal, nested splits or floating cards. Switching tabs restores the layout, focus and zoom; the workspace also survives reopening the app.

**⌘D** opens a session to the right of the focused card, and **⌘⇧D** opens one below, in the same folder. Splitting a layout keeps its other cards. Drag a session onto a card's left, right, top or bottom half to place it there. Each split has its own draggable gap. **⌘[** and **⌘]** move focus; double-tapping a header zooms or restores its card. Header controls also float a card, move or resize it, and tile it back into its previous split when that layout remains available. The palette provides **Balance Cards**, **Grow Focused Card** and **Shrink Focused Card**, also available as **⌃⌥⌘0**, **⌃⌥⌘=** and **⌃⌥⌘-**.

**Keyboard Bindings…** in the palette saves one- or two-key shortcuts for actions and saved host commands. A shortcut starts with Command, Control or Option; built-in shortcuts cannot be reused. **One-Shot Keys** waits for a plain key or the first key in a sequence, then returns to normal typing. The pending strip shows the available next keys, and Escape cancels it. Bindings remain on the device after reopening the app.

**Find in History** reads all retained history before searching. **Previous Prompt** and **Next Prompt** navigate real host-supplied prompt marks; an unsupported host shows an error instead of guessing from text. The activity panel keeps each tmux pane's status records, including separate task states, reasons, progress and messages. Choosing a row targets that exact window and pane without discarding the other workspace cards. The optional status helper publishes the summary and records together; older helpers or oversized record collections still leave the summary available.

**Import Theme File…** in the theme picker reads a Ghostty theme file from the device. The picker previews it before saving a local copy, so a saved theme remains available after the original file is removed. Light and dark themes are kept separately.

Session windows, selection and copying, file upload/download, on-device dictation and loopback web previews are also part of the source. A preview forwards a selected remote loopback port through SSH; it does not expose the service publicly.

Session icons use Apple's system symbols rather than bundled program logos or model artwork. Command aliases and reported model families still select distinct glyphs; program and session names remain text. An omp session keeps the short line beneath its model-family glyph. Unknown programs use a terminal symbol, and an unknown omp model uses the system π symbol.

Host-side helpers are optional:

- [status installer](tools/status/install.sh) reports a program's state from tmux.
- [sessions](tools/sessions/README.md) lets a host agent open a neighboring session.
- [agents](tools/agents/SKILL.md) describes the host agent workflow.
- [alerts](tools/alerts/README.md) sends host notifications through a service you configure.

Inspect installation scripts before running them. Host helpers can change that host's tmux configuration and files. Development helpers require an explicitly selected simulator or device; none silently selects an owner's device, host or account. See each script's usage. They are not part of the app and do not distribute a signed build.

## Akyl handoff and embedding

`LhunKit` is the library target; `LhunApp` is its standalone shell. An app can embed the public `Lhun` / `TerminalSpace` interface while the library keeps its settings in a separate defaults suite.

The source also contains Lhûn's side of an Akyl document handoff. An `.akyltask` document supplies a frozen context snapshot and points at an existing terminal session. Lhûn can prepare an `.akylreply` document and show the native Open In menu for a receiving app. These files do not include Akyl's task store, PDF reader, task/draft authority or separate application. The originating app must be installed and support the document contract for the two-app round trip. No standalone simulator check proves that physical-device handoff; it remains an owner-only two-app check. Reconnect and returning to an Akyl task do not automatically send selected text.

In Files, use **Share → Lhûn** to open an `.akyltask` document. The tested simulator did not list Lhûn under **Open With**.

## Checks and limits

Generate the project, approve the pinned package plugin, and run the pure-logic test scheme on a chosen simulator:

```sh
xcodebuild -project Lhun.xcodeproj -scheme LhunTests \
  -configuration Debug -destination 'id=YOUR_SIMULATOR_UDID' \
  CODE_SIGNING_ALLOWED=NO test
```

`LhunShots` contains development UI probes and real-host terminal scenarios, including nested and floating cards, retained-history search, prompt navigation and saved keyboard bindings. These need a deliberately configured SSH/tmux fixture and may create or kill test-prefixed sessions. The split suite requires `SPLIT_PREFIX`; the retained-history suite uses `lhun-rex-history`, retained rows and real OSC 133 prompt marks. Do not point them at an account whose test sessions you want to keep. A successful build or unit suite alone does not verify SSH pairing, reconnection, hardware keyboard input, Secure Enclave behavior or physical two-app document delivery.

Lhûn is not a general saved-host manager: it currently has only the Mac and Server places. It supports public-key SSH, not passwords, SSH agents, arbitrary SSH config files or automatic host provisioning. On-device speech recognition depends on the device and language. Remote session content and selected files are held locally as required by the app's features; the privacy manifest is in `Lhun/PrivacyInfo.xcprivacy`.

The 20 bundled fonts are byte-identical to the corresponding files in [Monaspace 1.400](https://github.com/githubnext/monaspace/tree/v1.400/fonts), under the included [SIL OFL 1.1](Lhun/Fonts/OFL.txt). The wave app icon is generated geometrically by `tools/make-icon.swift`. Program and model glyphs are requested through Apple's system APIs; no third-party logo pack or copied character is bundled. See [artwork and font notices](Lhun/ProgramIcons-LICENSE.md). Dependencies are fetched from their upstream repositories rather than copied into this source snapshot.
