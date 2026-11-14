# Notify guide

[Back to Notify](../README.md)

A native macOS app for answering Claude Code and Copilot requests without switching back to a terminal.

The sidebar puts **Needs you** first, then connected agents you're monitoring. **Not connected** stays separate, and saved chats have their own tab. Select a session, then use **Decision**, **Activity**, or **Session settings**. A session-colored floating panel brings permission requests, choices, multi-select questions, and text fields to your current desktop.

Notify appears in the Dock and Cmd-Tab. Agent launchers start it in the background without opening the control center or reactivating an already-running app. Closing the control center keeps monitoring active; click the Dock icon to reopen it. Floating requests remain visible when another app is active. Use **Options > Keep in Dock** on its Dock icon to pin it; Notify does not change Dock preferences.

## Session workspace and useful notifications

Notify follows macOS appearance automatically, including changes while it's running: muted beige and taupe in light mode, warm charcoal and sand in dark mode. Each chat has a stable color shared by its session row, activity header and floating notification. Change it using **Session color** in **Session settings**; **Reset** restores the automatic accent. Notifications use a subtle session tint with contrasting text in both modes. Colors are stored locally and follow the saved chat when it reconnects or resumes. Warning/error colors remain separate.

Floating cards show the chat title and project/agent above the full request. **Session > Open session** selects that exact chat. **Expand** enlarges the panel in place. Sending a reply keeps the card visible until acknowledgment; delivery failures appear inline, not in a blocking control-center popup. Replayed pending prompts do not repeatedly notify, and new arrivals preserve your selected question and draft.

The updated original-Copilot extension supplies an **Activity** timeline: user/assistant messages, tool commands/results and provider-published reasoning where available. Subagent events are labeled separately. Expand entries to read details; use **Follow live** or **Latest activity** to catch up. Idle does not mean the task or tests succeeded. Older connections retain their existing text preview until you explicitly reload extensions in that terminal.

Activity is a bounded in-memory preview (up to 300 entries and 512 KiB of retained native text per session); individual event previews are limited too. Earlier history remains with the original CLI. Notify does not invent reasoning, test results or progress, nor spend model credits to generate this timeline.

## Open and resume in iTerm2

**Saved chats** lists locally saved Copilot metadata. Select a stopped chat and choose **Resume in iTerm2**. Notify opens the original `copilot --resume <exact-id>` in a new iTerm2 window using the saved project folder. It does not send a model prompt.

**Saved Copilot mode and permission settings—including allow-all, if previously enabled—carry over.** The launch confirmation warns about this; Notify's broader per-session Auto-yes stays off. Extension setup and experimental-mode requirements remain explicit.

**Open in iTerm2** checks live ownership and matches the process's terminal to an exact iTerm2 session. A currently running chat is opened instead of resumed again. An absent/ambiguous terminal or denied Automation access produces an error rather than choosing a random tab. Launching is not the same as connecting: permissions remain unavailable until the extension connects.

iTerm2 must be installed at `/Applications/iTerm.app`; this local build launches Copilot at `/opt/homebrew/bin/copilot`. macOS may ask permission for Notify to control iTerm2. Missing project folders block resume. Existing Claude terminals and saved Claude launching are not supported in this release.

## Requirements

- macOS 14 or newer; Swift command-line tools to build.
- Node.js 22.18 or newer.
- Claude Code or Copilot CLI installed on `PATH` and already signed in.
- SDK versions are pinned; integration was checked against Claude Code 2.1.81 and Copilot CLI 1.0.112.

## Build and install

```sh
cd bridge
npm ci --ignore-scripts
cd ..
bash scripts/build.sh
bash scripts/install.sh
open ~/Applications/Notify.app
```

The installer creates `~/.local/bin/notify`, without replacing existing apps or launchers. If that directory is not on your PATH:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Add that line to your shell configuration to retain it in new terminals. Alternatively, invoke `~/.local/bin/notify` directly.

From a project directory:

```sh
notify claude
notify copilot
notify claude --model sonnet "Explain this project"
notify copilot --resume SESSION_ID
notify demo
```

**The launcher uses SDK-backed terminal chat, not the original full-screen CLI interface.** It uses the installed agent executables and their authentication. To keep an original Copilot terminal instead, use the extension below.

`notify demo` exercises permission and multi-field question replies without a model call or executing the example command. The native app opens when the launcher starts. Drag the floating panel to reposition it; use the menu-bar icon to reopen the control center.

## Existing Copilot terminals

Install the local extension from the installed app:

```sh
~/.local/bin/notify setup-copilot
```

This creates only `~/.copilot/extensions/notify/extension.mjs` (or under `COPILOT_HOME`). It does not change permission settings, restart agents, or overwrite another extension.

In a running Copilot terminal **where experimental mode is already enabled**:

1. Run `/extensions manage` and enable **notify**.
2. **Press Esc to close the manager.** Otherwise its loading screen can hide the permission-access prompt.
3. Approve Notify's request to handle permissions. The session then connects to the existing Notify app.

If the extension is not listed, ask Copilot to reload extensions. The extension joins the same live session; it does not resume a saved copy, replace the terminal, or send a model prompt.

**Copilot 1.0.112 restarts its UI/session initialization when `/settings experimental on` is used. Do not toggle this during active work.** If experimental mode is off, wait for a safe stopping point before enabling it. Future terminals can start with `copilot --experimental`. Notify never toggles this setting itself.

The app discovers live and saved Copilot sessions every 30 seconds using same-user processes, session lock filenames and small local workspace metadata files, without scanning conversation history. Running chats show **Connect extension**, with controls disabled, until connected. Discovery uses the app's `COPILOT_HOME`, or `~/.copilot` by default.

Once connected, permissions, choices, forms, and plan decisions can be answered in Notify or the original terminal. The first accepted response wins. Pending permission prompts are recovered when attaching; a question already blocking initial setup may need one terminal reply first. Closing Notify leaves the original terminal usable, and reopening reconnects outstanding requests.

Original Claude Code windows are not attached by this extension; continue using `notify claude` for Claude floating replies.

## Session descriptions

The session list uses Copilot's existing chat title rather than a UUID, with project and connection status shown separately. Select a session to see its latest activity.

For a richer description, select a Copilot session and click **Summarize**. After confirmation, Notify sends at most 12,000 characters of saved user/assistant text to an available Haiku model through your Copilot account. It excludes tool arguments/results, does not read referenced files, and uses a separate tool-free session. This consumes account allowance; nothing runs automatically, and Notify never silently falls back to a different model family. Missing login, model availability and generation failures are shown explicitly.

Descriptions are cached locally with their model and generation time. **Refresh description** is another explicit request. The original chat title and terminal session are never changed. Only one summary runs at a time, with a 60-second generation timeout. This feature currently uses saved Copilot sessions, not Claude history.

## Replying

Use **Allow once**, **Deny**, or the actual question fields. Every response targets one pending request in one connected session. A response is removed only when the bridge acknowledges it; the live Copilot extension waits for runtime acceptance before acknowledging. Questions can be declined; they are never auto-answered.

Every supported remembered scope has its own button with its coverage written underneath. **Clicking an Always/Allow every time button submits immediately: no menu and no second confirmation.** While a connected request is visible in the floating panel, **Up/Down cycle the highlighted choice and Return or keypad Enter activates it**, even from another app. Permissions start on Allow once; deliberately highlighting an Always scope or Deny makes Return activate that choice. The keystroke is consumed, not also delivered to the underlying app. Holding Return cannot approve consecutive requests. No app switch or Accessibility permission is needed.

For questions, Return selects or toggles the highlighted option. A completed single-choice question moves the highlight to Send answer; press Return again to send. For multi-select, toggle the desired choices and navigate to Send answer. Choosing Other focuses its editable input.

The global bindings release when the card is hidden, snoozed, disconnected or sending, while editing text in Notify, and during steering. **Keys intended for another app will operate the visible notification instead**; hide or snooze the card to release them.

Built-in Copilot questions offer **Other** with an editable custom answer, including suggested-choice forms. Custom text is preserved for boolean/numeric-style questions too; external MCP forms retain their schema restrictions. Running Copilot extensions must be reloaded to advertise restored custom-answer support.

Copilot supports scoped command/read/write/tool session approvals, project-persisted tool approvals, site approvals, exact-path session approvals and runtime-offered read-only directories. A resumed session may ask again. Supported Copilot requests also have optional instructions sent with **Deny**. Claude launchers expose the complete supported permission-update suggestion supplied by Claude, without inventing rules or changing permission mode. **Remembered approvals can skip future questions; AI can make mistakes.** They are separate from Notify's Auto-yes and are not undone by disabling it. The scope is recorded in approval history before dispatch; SDK-launcher acknowledgments mean the reply was handed back, not proof that the runtime saved a rule.

Full terminal-choice parity is still incomplete: MCP sampling, extension-authority consent, broader managed/sandbox scopes and Claude permission-mode changes are not implemented here. These are explicit integration boundaries, not invented approvals or an “other choices” button. Existing Copilot extensions need an explicit reload to expose new options and denial instructions. Already-running SDK launchers keep their old behavior until restarted.

Long prompts, options and context scroll inside the card while reply buttons remain below. Structured permission context appears as labeled values; question schemas already represented by form controls are not dumped as JSON.

SDK launcher terminals also support this fallback when the app is closed (original Copilot terminals keep their normal controls):

```text
/reply 1234abcd allow
/reply 1234abcd deny
/reply 1234abcd {"0":["SQLite"],"1":["Unit","Integration"]}
/quit
```

Use the request ID and field IDs printed by the launcher. `/quit` cancels pending decisions and ends the launcher. The agent's saved session ID is printed for resuming. The launcher retries its app connection when the app is restarted.

## Safe auto-yes

Enabled by default, with a global switch in Settings and a per-session switch in the Session tab. It only applies to structured file-read requests inside the canonical project directory, using a small source/document extension allowlist. Hidden paths, sensitive filenames, symlink escapes, directory reads, commands, writes, installs, browser actions, and preference questions are not eligible. Copilot managed approvals and sandbox bypasses stay manual.

The SDK's existing permission rules can resolve operations before Notify sees them. This setting does not override those rules or impose a new sandbox. It is not a blanket approval mode. An automatic decision is recorded before dispatch; if the history cannot be written, Notify does not approve it.

## Steer an attached Copilot session

Choose **Steer an Agent** from Notify's menu-bar menu, or **Send instruction** from session details. The floating panel stays available even when no permission is pending. Select the target chat, read its latest activity, and type a direction:

- **Queue** submits the direction for the next turn.
- **Interrupt** asks for confirmation, interrupts the main turn while preserving queued prompts/background work, then submits the new direction.
- **Stop** asks for confirmation and aborts current work, clearing queued prompts (including prompts queued in the terminal). It does not undo changes or close the terminal; external processes may continue.

Queue acceptance and a matching runtime **Received** event are separate receipts. Agent activity is shown separately rather than pretending an unrelated response answers your message. Drafts stay with their session. An unknown delivery is never retried automatically: check the terminal before resending.

These controls require the updated Notify extension in an original Copilot terminal. Existing loaded extensions must be reloaded in that terminal to acquire the new capabilities; ask Copilot to reload its extensions. Notify does not restart the terminal to do this. SDK launchers and Claude remote steering are not supported, and unavailable controls are disabled.

### Broader session Auto-yes

The floating composer also offers **Session Auto-yes (not recommended)**. It starts **OFF**, requires confirmation for the selected session, and keeps a warning visible while enabled:

**AI can make mistakes. Commands may modify or delete files or perform external actions.**

Only new, policy-eligible tool permissions qualify. Questions, browser consent, extension-access consent, managed approvals, sandbox bypasses and recovered pending requests stay manual. Runtime policy is rechecked immediately before every automatic reply. Mode changes and dispatches are audited without saving message text; a failed audit prevents approval.

This broader setting is separate from safe-read approval. It is never persisted, and turns off on disconnect/reconnect, app restart, Stop, approval errors, or failed/uncertain steering. Turning it off cannot recall approvals already dispatched or undo their effects. Use manual approval for sensitive projects.

## Local data and limits

- Native UI with no embedded browser, server polling, accessibility scraping, or synthesized keystrokes.
- Local IPC listens only on loopback and requires a random token from a user-private file.
- Settings use macOS preferences. Connection information, session color overrides, the last 200 approval records and up to 200 private cached descriptions live in `~/Library/Application Support/Notify/`.
- History records session labels and decisions, not answers, commands, or conversation contents. The app keeps only a bounded in-memory conversation preview. The agent CLIs retain their normal session histories.
- No separate cloud service is added by Notify. The agents and explicitly requested Haiku descriptions communicate with their normal model providers.
- Browser-auth requests require completing the shown URL yourself before confirming. Secret/password prompts are not a supported floating-input workflow; authenticate in the original CLI first.
- The panel is configured for other Spaces and full-screen apps, but secure desktops, locked screens, and individual full-screen app behavior are controlled by macOS.
- Library/skill/plugin management, existing Claude attachment, mobile delivery, and a full terminal emulator remain later work.

## Checks

```sh
swift run NotifyCoreChecks
swift run NotifyTerminalChecks
swift build --product NotifyTransportChecks
bash scripts/check-ui.sh
cd bridge
npm test
npm run check
npm run test:integration
npm run test:copilot
python3 test/tui_runtime.py
node dist/cli.js claude --doctor
node dist/cli.js copilot --doctor
```

The doctor commands initialize the installed runtimes without sending a model prompt. Transport checks exercise actual Swift-to-Node permission and question replies. The Copilot checks hot-load the extension into an existing SDK-owned session and an original terminal UI, including extension consent and a native reply to the same session ID. Steering checks use a loopback-only synthetic OpenAI provider to exercise joined-session queue, interrupt and stop without paid model calls. Summary checks verify a real tool-free runtime setup with a substituted response. UI checks measure native scrolling, composer state, audit failures and mode resets. They use disposable fixtures and never manipulate real running terminals. Live provider output and individual full-screen app behavior still need a manual check.

The app is ad-hoc signed for local use, not notarized for distribution. The build omits duplicate Copilot runtimes and development-only dependencies from the app bundle; the installed CLIs remain required.
