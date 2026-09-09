# MyTerm Remote

A companion iPadOS and iOS app that reaches this Mac's MyTerm workspaces, and drives its live
terminal sessions from an iPad or an iPhone.

Status: specification. No part of this is built.

## Purpose

MyTerm keeps long-lived terminal sessions alive across folders, workspaces, pane groups, and tabs.
Those sessions only exist on one Mac. When the user leaves the desk, the work stops being reachable,
even though the sessions keep running and the agents keep working.

MyTerm Remote makes the same workspaces reachable from an iPad or an iPhone, on the local network or
from anywhere. The user links a device once. After that, the device lists the same folders and
workspaces, marks the tabs whose agent needs attention, and opens any terminal tab as a live,
writable session.

The Mac stays the only place a process runs. The device is a window onto it.

## What this is not

- It is not a separate terminal. The device never spawns a shell and never holds a session of its own.
- It is not a sync service. There is no account, no cloud copy of the workspace tree, and no server
  that can read terminal content.
- It is not a copy of the Mac layout. Splits, dividers, and pane groups stay on the Mac.
- It is not an agent dashboard. The device shows the same attention dot the Mac shows, and nothing more.
- It is not a remote browser. Browser tabs appear in the list, but MyTerm does not mirror a WKWebView.
- It is not a second way to configure MyTerm. Settings stay on the Mac.

## The experience

### Linking a device

1. On the Mac, the user opens Settings, then Devices, and turns on **Allow my devices to reach this Mac**.
2. The user presses **Link a Device**. A sheet shows a QR code and a countdown.
3. On the iPad or iPhone, the user installs MyTerm Remote and scans the code.
4. The device names itself, the Mac lists it, and the sheet closes.

The code expires after 120 seconds and works once. Later connections need no code.

Linking happens on the local network. It is the one step that requires the two devices to be together,
and that is what makes the pairing trustworthy.

### Using a linked device

The device opens on the folder and workspace list, in the Mac's order, with the same colors and pins.
A workspace row carries a dot when any of its tabs needs attention, exactly as the Mac sidebar does.

Opening a workspace shows a tab strip along the top and one open tab filling the screen. Output
arrives as the Mac receives it. Typing sends keys to the same process. The Mac pane and the device
show one session, because there is only one session.

Leaving a tab detaches it. The session keeps running. Nothing about the Mac's layout changes.

### Coming back

The app reconnects when it returns to the foreground. It re-attaches to the tab the user was on and
redraws the current screen. A short absence should look like nothing happened.

## How a workspace looks on a device

The Mac's split layout exists because a large display can show four things at once. A phone shows one.
An iPad shows one comfortably. The device does not reproduce the split.

The projection flattens a workspace into one ordered list of tabs.

- The order follows `Workspace.orderedGroups`, then each group's own tab order. `Workspace.allTabs`
  already computes exactly this, so the flattening is one existing accessor.
- Pane groups, split orientations, and divider proportions never reach the device.
- The device shows the flat list as a tab strip along the top, and one open tab at a time, full screen.
- Two tabs can carry the same title. The device disambiguates with the working directory's last path
  component beneath the title.

Three consequences, all of which are acceptable:

- Splitting a pane on the Mac reorders the device's tab strip. That is correct, because the list
  follows the Mac's reading order.
- The device cannot express that two panes sit side by side. An iPad split view is a possible later
  addition, and it is not part of a first release.
- Closing a tab from the device closes it in its Mac pane group. If it was that group's last tab, the
  pane closes, exactly as it does on the Mac.

## Scope

### In scope for the first release

- One Mac, several linked devices, iPad first.
- The flattened workspace tree, read-only: folders, workspaces, tabs, titles, colors, pins.
- Live attach to any terminal tab, with output and input.
- The agent attention dot, mirrored from the Mac.
- Pairing on the local network, a paired-device list, and revocation.
- Reach from the local network, and reach through the relay from anywhere.

### Later

- The iPhone, with the smaller grid and the software keyboard work it forces.
- Creating, closing, renaming, and selecting tabs and workspaces from the device.
- Push notification when an agent needs attention while the app is closed.
- An iPad split view, if the flat list proves insufficient.

### Never

- Passkeys, browser cookies, or website data leaving the Mac.
- A relay that can read terminal bytes, tab titles, or workspace names.
- A second copy of the workspace state that the device can edit while offline.

## Architecture

### Package layout

MyTerm is a SwiftPM package that targets macOS only. Two changes open it to iOS.

- Add `.iOS(.v17)` to the package platforms. `MyTermCore` already imports only Foundation and
  CoreFoundation, so it compiles for iOS without change. `MyTermPlatform` and `MyTerm` import AppKit
  and stay on macOS, because the device app never links them.
- Add two targets:
  - `MyTermRemoteProtocol` — the wire format, the message types, the framing, and the end-to-end
    cryptography. It depends on `MyTermCore` and Foundation only. Both sides link it.
  - `MyTermRemoteHost` — the Mac listener, the relay client, the pairing store, and the attachment
    manager. It depends on `MyTermCore`, `MyTermPlatform`, and `MyTermRemoteProtocol`.

The device app is an Xcode application target, because SwiftPM cannot build an app bundle. Put it at
`apps/MyTermRemote/`, and generate the project from a checked-in `project.yml` with XcodeGen, so a
reviewer reads text rather than a project file.

The relay is a service, not part of this package. It gets its own repository. See below.

### Do not put the persisted model on the wire

`Workspace`, `Tab`, and `TerminalSession` are already `Codable`. It is tempting to send them directly.
Do not. The persisted format carries migrations, backups, and recovery rules that exist for disk, and
the wire format needs its own version number and its own compatibility window.

`MyTermRemoteProtocol` declares its own view types. A projection function in `MyTermRemoteHost` maps
the live model onto them, flattening the layout as described above. The projection drops what a device
must never receive, including `recentText`, browser data profile identifiers, and agent session
identifiers.

### The terminal engine contract

`TerminalProcessSession` is the only contract between the app and its terminal engine. Four additions
carry the whole feature. Each gets a default implementation in the existing extension, so test fakes
stay small.

```swift
/// Receives every byte the process writes, in arrival order, before the emulator consumes it.
func setOutputTap(_ tap: (@MainActor (ArraySlice<UInt8>) -> Void)?)

/// Sends bytes to the process as if the user typed them.
func sendInput(_ bytes: ArraySlice<UInt8>)

/// The current screen, as the escape sequences needed to reproduce it on an empty terminal.
func gridSnapshot() -> TerminalGridSnapshot

/// Holds the process grid at a fixed size, ignoring the Mac view. Needed only if fit mode ships.
func pinGrid(columns: Int, rows: Int)
func unpinGrid()
```

`SwiftTermTerminalSession` already overrides `dataReceived(slice:)`, so the output tap is one line in a
method that exists. `send(txt:)` already carries input. The grid snapshot is new work.

### Attaching, and what the device sees first

A device that attaches midway through a session needs the current screen, not the future stream.

Replay from a raw ring buffer is the obvious approach, and it is wrong for this product. The agents
this feature exists to watch draw with cursor movement, and Codex draws on the alternate screen.
Replaying old bytes reproduces a scrollback, not a screen.

The host answers an attach with a **grid snapshot**: the visible rows serialized as SGR runs, plus the
cursor position, the cursor visibility, the alternate-screen flag, and the active modes. The device
feeds the snapshot into an empty emulator and arrives at the same screen the Mac shows. Live bytes
follow.

The grid serializer is the one piece of genuinely new terminal work in this feature. It is testable in
isolation, as described under Testing.

A raw ring buffer is acceptable in the first milestone, to get the path working end to end. It must
not be what ships.

### Backpressure

An agent can write megabytes in a second. A device on a mobile network cannot always keep up, and a
queue that grows leaves the device minutes behind the Mac while consuming memory on both sides.

Each attachment holds a bounded send queue, 512 KB. When output overruns the queue, the host discards
the queue, sends `resync`, and follows it with a fresh grid snapshot. The device clears its emulator
and redraws.

This is correct behavior for a mirror rather than a compromise. A user watching a build scroll wants
the current screen, not every frame of it.

### Grid size

This is separate from the layout flattening above, and it is still open.

One process has one window size. The Mac pane has a grid, and the device has its own comfortable grid.
Two answers exist.

- **Mirror.** The device receives the Mac pane's grid and scales it to fit the width. Nothing about the
  Mac changes. On an iPad a 120-column grid stays readable, which is one more reason to start there.
  On an iPhone it does not, without zoom and panning.
- **Fit this device.** The process resizes to the device's grid while the attachment lasts, and the Mac
  pane reflows to match. Detaching returns the pane to its view-driven size.

Recommendation: mirror only in the first release, and add fit alongside the iPhone, where it earns its
cost. Fit must always be explicit and per attachment. A grid that resizes because a phone woke up in a
pocket is a bug the user cannot diagnose.

### Wire protocol

One connection carries every session, multiplexed by identifier. The same protocol runs over the local
network and inside the relay tunnel.

A frame is a 4-byte big-endian length, a 1-byte type, and a payload.

| Type | Name | Payload |
| --- | --- | --- |
| `0x01` | control | JSON, versioned |
| `0x02` | output | 16-byte session identifier, then raw bytes |
| `0x03` | input | 16-byte session identifier, then raw bytes |

Terminal bytes never pass through JSON. Base64 on a keystroke path costs latency and size for nothing.

Control messages:

| Message | Direction | Purpose |
| --- | --- | --- |
| `hello` | device to host | Protocol version, device name, device key |
| `welcome` | host to device | Protocol version, host name, capability list |
| `tree` | host to device | The flattened workspace tree, with a revision number |
| `treeDelta` | host to device | Changes since a revision |
| `attach` | device to host | Tab identifier, size mode, device grid |
| `attached` | host to device | Session identifier, grid size. A snapshot frame follows |
| `detach` | device to host | Stop streaming this session |
| `resize` | device to host | New device grid, honored only in fit mode |
| `resync` | host to device | Clear the emulator. A fresh snapshot follows |
| `agentActivity` | host to device | Tab identifier and the reported activity |
| `intent` | device to host | A requested change to the tree. Later milestone |
| `error` | either | A code and a message |

The host is authoritative. A device never mutates its own copy of the tree. It sends an intent, the
host applies it through the same `AppModel` command the Mac menu uses, and the host broadcasts the
resulting delta. One code path serves both surfaces.

## Pairing and security

This feature gives a device a writable shell on the user's laptop, reachable from the public internet.
It is the highest-risk thing MyTerm could ship. The design below is the minimum, not a starting point
for discussion.

### Defaults

- The feature is off. No key exists, no port is open, and no relay registration exists until the user
  turns it on.
- The local listener binds only while the feature is on and at least one device is paired, or while the
  pairing sheet is open.
- The listener advertises `_myterm-remote._tcp` through Bonjour.

### Keys

- Turning the feature on creates a long-term host key pair in the Keychain, protected by the login
  keychain and marked non-extractable where the hardware allows it.
- Each device creates its own key pair on first launch and keeps it in the device keychain, gated by
  the device passcode.
- **Forget All Devices** deletes the host key, every paired record, and the relay registration. Existing
  devices cannot reconnect, and re-pairing is the only route back.

### Pairing exchange

1. The Mac shows a QR code carrying the Bonjour service name, the host public key fingerprint, and a
   128-bit one-time secret.
2. The device connects on the local network, and both sides complete TLS 1.3 with a custom verification
   block that pins the fingerprint the QR code carried.
3. The device proves knowledge of the one-time secret and presents its own public key.
4. The Mac records the device, its name, its key, and the date. It also hands over the relay rendezvous
   identifier, inside this authenticated channel.

The secret expires after 120 seconds and is accepted once. A failed attempt invalidates it. Later
connections authenticate with the two long-term keys and need no code.

### While a device is attached

- The Mac shows one quiet indicator that a device is attached, with the device name behind it. This is
  a security affordance, not status decoration, and it is the one place the product's "no status layer"
  rule yields. The indicator states a live remote-input path, which the user has a right to see at all
  times.
- **Pause Input From Devices** is one command. Output keeps flowing and input is refused. This is what a
  user reaches for when handing the iPad to someone.
- The app requires Face ID, Optic ID, or the device passcode before it reveals the workspace list.

### Boundaries

- MyTerm logs no terminal bytes, and no message payload, at any log level.
- The projection never sends `recentText`, agent session identifiers, or browser profile identifiers.
- Only an attached session streams. Attaching to a tab is an explicit act.
- A revoked device is disconnected immediately, not at its next connection.

### Sleep and power

None of this works while the Mac sleeps. Say so in Settings rather than letting the user discover it
from a spinner.

While at least one device is attached, the host holds a `ProcessInfo` activity with
`.idleSystemSleepDisabled`, and releases it when the last device detaches. macOS may still sleep on
battery. A setting controls the assertion, and it is on by default.

## The relay

The relay lets a device reach the Mac with no network setup, from anywhere. It is a separate service
with its own repository, its own deployment, and its own on-call reality.

### The rules it must obey

1. The relay must never be able to read terminal bytes, tab titles, or workspace names.
2. The local network path stays preferred, because it is faster.
3. The Mac must never need an inbound port, a static address, or NAT traversal.

### How it works

- Turning on remote reach generates a random 128-bit **rendezvous identifier**, separate from the
  long-term host key, and registers it with the relay. The relay learns that identifier and nothing
  else. There is no account, no email, and no hostname.
- The Mac holds one outbound connection to the relay and keeps it alive. Every connection is outbound,
  so no port forwarding and no NAT traversal are required.
- A device receives the rendezvous identifier during pairing, on the local network, inside the
  authenticated channel. The relay never distributes it.
- A device connects to the relay naming the identifier. The relay joins the two connections and forwards
  bytes. It is a pipe and nothing more.
- Inside that pipe, both sides run a **Noise IK handshake** using the same long-term keys that pairing
  established. Every frame above it is encrypted and authenticated end to end.

### What the relay can still see

Ciphertext, frame sizes, and timing. It can infer that some Mac and some device are talking, when, and
how much. It cannot infer what about. State this plainly in Settings and in the privacy statement.
Claiming more than this is worse than claiming nothing.

### Choosing the path

The device tries Bonjour first with a short timeout, roughly 300 ms, and falls back to the relay. A
session that starts on the relay does not migrate to the local network in the middle of an attachment,
because a mid-attachment transport change is not worth the failure modes it adds.

The Settings section shows which path a device is using, so a user can tell a slow relay from a slow Mac.

### Hosting

One Durable Object per rendezvous identifier on Cloudflare Workers fits the shape well, because
WebSocket hibernation makes an idle Mac nearly free. A small Fly.io or Hetzner instance running a
forwarder is the alternative, and it costs more attention for the same result.

Real cost is bytes forwarded during use. Idle registrations are close to free.

### Operational burden to accept

Uptime, a status page, an abuse path, rate limits per rendezvous identifier, a privacy statement, and
certificate rotation. This is a service with users, and it needs an owner. That is the price of the
no-setup experience, and it was chosen knowingly.

### Also offer a manual address

A manual address field costs almost nothing and serves the user on a corporate network that blocks
Bonjour, the user already running Tailscale, and the user who does not want to trust a relay at all.
Ship it beside the relay, not instead of it.

## Telling the user an agent needs attention

The attention dot is the reason to carry this app. Its delivery has a hard platform limit that the plan
must state rather than discover.

- **Foreground, connected.** The `agentActivity` message drives the same dot the Mac shows, plus an app
  badge. This is free and works from the first milestone.
- **Recently backgrounded.** iOS keeps the socket for a short period, roughly 30 seconds. During it, the
  app raises a local notification when a message arrives. This is a useful window, and it is not a
  general solution.
- **Closed, or backgrounded longer.** Only Apple Push Notification service wakes an app, and APNs needs a
  provider that holds a signing key.

Push is not in this plan. It becomes cheap later rather than expensive, because the relay already holds
a connection to the host and a relationship with the device. Adding a contentless push is then a feature
of an existing service, not a new service. Should it ship, the payload carries no terminal content, no
tab title, and no workspace name. The app fetches the detail from the Mac after it wakes.

## The device app

### iPad first

The first release targets iPad. This is not a smaller scope for its own sake. It removes the software
keyboard, the small grid, and the pan-and-zoom work from the critical path, and it lets the architecture
be judged on a device where a 120-column grid is readable. The iPhone follows once the protocol,
snapshot, and reconnection behavior are proven.

### Structure

Both devices use the same shape, because the layout is already flat:

1. Folders and workspaces, with attention dots.
2. A workspace: a tab strip along the top, one open tab filling the rest.

On iPad this is a two-column split view, and it supports Stage Manager and an external keyboard. On
iPhone it is a navigation stack. There is no pane interface on either, and that is the point.

### The terminal surface

SwiftTerm supports iOS 14 and later, and ships `iOSTerminalView`, an accessory view, and a SwiftUI
wrapper. The app uses the plain `TerminalView`, never the local-process variant, and feeds it with
`Terminal.feed(byteArray:)`. Input arrives through the terminal delegate and goes onto the wire.

Coalesce feeds on a display link rather than feeding per packet. A device rendering a fast scroll is a
battery and heat load.

### The keyboard

An iPad with a hardware keyboard needs Control and Option chords mapped through the same input path,
and little else. That is the first release.

Software keyboards need an accessory bar carrying Escape, Control, Tab, the four arrows, and a paste
control at minimum. Evaluate SwiftTerm's own accessory view first, and replace it only if it falls
short. This work lands with the iPhone.

### Appearance and accessibility

The app follows the system appearance, uses Dynamic Type in its chrome, respects reduced motion, and
labels every row for VoiceOver. The terminal grid itself is not usefully readable by VoiceOver. State
that limit rather than implying parity.

The app inherits the Mac's terminal font size and theme through the projection, so a workspace looks the
same on both surfaces.

### Browser tabs

A browser tab appears in the flat list with its title and address. Selecting it offers **Open in Safari**
and an in-app web view with its own data store. The device does not receive the Mac's cookies, and it
does not share the profile. The interface says so in one line.

## The Mac side

The Mac app gains one Settings section and one indicator. It gains nothing else.

**Settings → Devices** contains:

- The **Allow my devices to reach this Mac** switch, off by default.
- **Link a Device**, which presents the QR sheet.
- The paired-device list: name, kind, path in use, last seen, and Revoke.
- **Reach my Mac from anywhere**, the relay switch, with the manual address field beneath it.
- **Forget All Devices**.
- **Keep this Mac awake while a device is attached**, on by default.
- One line stating that a sleeping Mac is unreachable, and one line stating exactly what the relay can
  and cannot see.

**Pause Input From Devices** lives in the application menu.

## Persistence

Paired devices and the rendezvous identifier persist beside the workspace state, in the same per-channel
directory, in a separate `remote-devices.json` file. Keeping it separate means a workspace recovery never
touches a security record, and revoking a device never rewrites the workspace file.

Keys live in the Keychain, never in JSON.

No part of the remote feature writes into `workspace-state.json`.

## Milestones

Each milestone ends in something that builds, tests, and can be judged.

**M1 — Shared foundations.** Add iOS to the package platforms. Add `MyTermRemoteProtocol` with the
message types, the framing, the flattening projection, and codec tests. No transport and no interface.

**M2 — Tap the terminal.** Extend `TerminalProcessSession` with the output tap and input injection.
Implement both in `SwiftTermTerminalSession`. Prove them against the existing fake engine in tests.
Nothing is visible to a user.

**M3 — Local transport and pairing.** Build `MyTermRemoteHost`: the Bonjour listener, the pinned-key TLS
handshake, the one-time pairing exchange, the device store, and the Settings section. Verify with a
command-line test client rather than an app.
*Usable at:* a terminal client on the same network can pair and echo bytes.

**M4 — The iPad app appears.** Add the Xcode project, the connection, the workspace list, the flat tab
strip, and the attention dots. No terminal yet.
*Usable at:* the iPad shows the real workspaces and their dots.

**M5 — Live terminals.** Attach, stream, input, detach, and hardware keyboard chords. Ring-buffer replay
is acceptable here.
*Usable at:* the feature does what it exists to do, on the local network.

**M6 — Correct screens.** Replace replay with the grid serializer. Handle the alternate screen, the
cursor, and the active modes. Add backpressure and resync.
*Usable at:* Codex and vim look right, and a fast build does not fall behind.

**M7 — Reconnection and sleep.** Fast foreground reconnect, re-attach, the sleep assertion, and the
manual address field.
*Usable at:* the app survives a lift, a lock screen, and a network change.

**M8 — The relay.** The service, the rendezvous registration, the Noise IK tunnel, the path selection,
and the privacy statement. The service can be built in parallel from M3 onward, because it depends only
on the framing, not on the app.
*Usable at:* the iPad works from anywhere.

**M9 — The iPhone.** The accessory bar, the small-grid decision from above, and the navigation stack.

**M10 — Acting from the device.** Intents for new tab, close tab, select tab, rename, and new workspace,
each routed through the existing `AppModel` command.

M1 through M8 are the feature. M9 and M10 extend it.

## Testing

The pieces that are hard to test are the pieces most likely to be wrong.

- **Codec.** Round-trip every control message and every frame type. Reject truncated frames, oversized
  lengths, and unknown types without crashing.
- **Flattening.** Assert that a nested split layout projects to the Mac's reading order, that a
  re-split reorders predictably, and that duplicate titles carry a disambiguating directory.
- **Grid serializer.** Feed known bytes into a headless SwiftTerm `Terminal`, serialize the grid, feed the
  serialized bytes into a second empty `Terminal`, and compare the two grids cell by cell. This is a
  property test, it is cheap, and it catches almost everything that matters.
- **Backpressure.** Drive a deliberately slow client and assert that memory stays bounded and that a
  `resync` is sent.
- **Pairing.** Cover an expired code, a reused code, a wrong fingerprint, an unknown device key, and a
  revoked device that is currently connected.
- **Relay tunnel.** Assert that a relay that records every byte it forwards learns no plaintext. Run the
  Noise handshake against a hostile relay that replays, reorders, and truncates.
- **Projection.** Assert that `recentText`, agent session identifiers, and browser profile identifiers
  never appear in a projected tree. Make this a test, not a review habit.
- **Host tap.** Use the existing fake engine to confirm that attaching, detaching, and revoking leave no
  retained closure on a session.

## Risks

- **Scope.** This roughly doubles the product surface of an app whose stated virtue is narrowness, and the
  relay adds a service to a product that had none. It is defensible only because it adds a surface rather
  than adding chrome to the Mac. Keep the Mac app unchanged apart from one Settings section and one
  indicator.
- **Security.** A remote writable shell reachable from the public internet deserves an external review
  before any build reaches a device the developer does not own. This is not optional.
- **Running a service.** The relay is the largest ongoing commitment in this plan. It has uptime, abuse,
  and privacy obligations that do not pause. Budget for it as a product, not as a deployment step.
- **The grid serializer.** It is the only part with no reference implementation to lean on. Schedule it as
  real work, and do not let M5's ring buffer become permanent.
- **iOS input maturity.** SwiftTerm's iOS text input has seen less use than its Mac path. Budget time for
  chords, composition, and paste. Starting on iPad limits the exposure.
- **Sleep.** The most common support question will be a Mac that slept. Answer it in the interface.

## Settled decisions

- Reach is the local network plus a hosted relay, with a manual address field beside them.
- The first release targets iPad. The iPhone follows in M9.
- The device flattens each workspace into one ordered tab list. No pane interface ships on either device.
- Push notification to a closed app is out of scope, and the relay makes it cheap to add later.

## Open decisions

1. **Grid size.** Mirror the Mac's grid and scale it, or resize the process to fit the device? The
   recommendation above is mirror-only for the first release, with fit arriving alongside the iPhone.
2. **Relay hosting.** Cloudflare Workers with Durable Objects, or a small instance running a forwarder?
3. **Distribution.** TestFlight for the developer's own devices, or the App Store? The App Store adds
   review, a privacy label, and a support surface, and the relay makes a privacy label mandatory reading.
4. **Relay ownership.** Does the relay live in this repository's organization, and who is on call for it?
