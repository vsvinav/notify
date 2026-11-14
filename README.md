# Notify

**Your agents are working. Stay with what you're doing.**

Answer Copilot and Claude Code requests from a small floating panel, without switching back to the terminal.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/sessions-dark.png">
  <img src="docs/images/sessions.png" alt="Notify's session overview and inline approval controls">
</picture>

## A little less switching

- **Know what you're approving.** See the agent, project, and prominent URL, path, or command. Expand technical details when needed.
- **Answer right there.** Approve, deny, pick an option, or write your own answer.
- **Keep your hands on the keyboard.** Up/Down choose; Return activates the highlighted choice.
- **Keep sessions straight.** Drag to reorder, clear connection groups, and 20 shared colors—from soft pastels to richer earth and jewel tones.
- **Watch and steer.** Live activity beside your controls, with a little agent that works, waits, and rests.
- **Keep your terminal.** Attach to an existing Copilot session without replacing it.
- **Connect without guesswork.** Guided setup finds installed agents and shows when a session actually connects.
- **Easy on the eyes.** Muted beige or warm charcoal. Follow your Mac, or choose Light/Dark in Settings.
- **Connect your phone.** Optional same-network iPhone/Android web companion, with Mac-confirmed pairing and generic background alerts. [Setup and current limits](docs/guide.md#phone-connections).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/notification-dark.png">
    <img src="docs/images/notification.png" alt="A session-colored notification with a prominent resource URI, expandable details, and reply controls" width="360">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/session-colors-dark.png">
    <img src="docs/images/session-colors.png" alt="Twenty session colors mixing soft pastels with deeper earth and jewel tones" width="240">
  </picture>
</p>

<p align="center"><sub>Real app captures with fictional sessions.</sub></p>

**Keyboard priority:** while a request is visible, Up/Down and Return go to Notify—even from another app. Return activates the highlighted option, including a remembered approval or Deny. Snooze or hide the notification to give those keys back.

## Try it

Currently a local build, not a notarized download. Requires **macOS 14+**, **Node.js 22.18+**, Swift command-line tools, and an installed, signed-in agent CLI.

```sh
git clone https://github.com/vsvinav/notify.git
git clone https://github.com/vsvinav/notify-mobile.git
cd notify
(cd bridge && NODE_TLS_REJECT_UNAUTHORIZED=1 npm ci --ignore-scripts)
NOTIFY_MOBILE_SOURCE=../notify-mobile bash scripts/build.sh
bash scripts/install.sh
open ~/Applications/Notify.app
```

The companion repository is currently private. Building the complete app requires access to it; the source path is explicit and its production dependencies are bundled into Notify.

Preview a request without running an agent or spending model credits:

```sh
~/.local/bin/notify demo
```

### Connect your agent

Open **Connect agents** in Notify. Setup checks your tools, installs the Copilot extension with your permission, or gives you a launch command to run from your project folder.

Copilot can keep its original terminal. Claude currently uses a new SDK-backed chat; existing Claude terminals cannot attach yet. Accounts and model settings stay in your agent.

[Connection details and terminal commands →](docs/guide.md#connect-agents)

---

Native SwiftUI/AppKit. No embedded browser or separate Notify cloud service. Your agents still use their usual model providers.

[Full guide](docs/guide.md) · [Permissions & safety](docs/guide.md#replying) · [Current limitations](docs/guide.md#local-data-and-limits) · [Development checks](docs/guide.md#checks)
