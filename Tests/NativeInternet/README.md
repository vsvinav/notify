# Native internet transport checks and helper contract

Run `bash Tests/NativeInternet/check.sh` from the Notify repository. It builds
Notify but runs only a headless check executable, never the application entry
point. All fixtures, home/temp/cache overrides and output executables are under
`.build`; preferences are in-memory. Node inherits
`NODE_TLS_REJECT_UNAUTHORIZED=1`. No Keychain calls, real sessions, inference,
deployment, installed application changes, or dependency installation are needed.
Existing resolved Swift dependencies must be available.

Coverage: process-local default-off consent, strict HTTPS origins, missing-helper
errors, LAN/internet ticket separation, same external IDs on different transports,
forged cross-channel tickets, exact reply/control acknowledgments, uncertainty on
remote disconnect, preservation of pending LAN replies, no late-result replay,
fresh authority after wake, full-key pairing display data and stale-prompt
confirmation binding, and fail-closed status validation.

## Remembered-phone candidate checks

Included in beta 8 / build 18; these checks do not prove live device behavior. The default
headless runner additionally tests separate typed remembered consent, complete
canonical-base64 keys, captured ID/generation/expiry changes, correlated ACKs,
unknown delivery/no replay, exact committed G/E reconciliation after helper
restart, replacement denial and revoked status. The synthetic producer JSON is
copied from the frozen backend examples; no actual keys/accounts are used.

To also run native → helper → real synthetic P256 authority Allow/Deny commits:

```sh
NOTIFY_REMEMBERED_HELPER_ROOT=/path/to/notify-mobile/worktree bash Tests/NativeInternet/check.sh
```

The optional `--remembered-ui` argument to `.build/NotifyInternetChecks` renders
fictional light/dark 560×680 windows that are **never shown**, with no activation,
input posting or key interception. Keep the runner's isolated HOME/agent-home
environment when invoking it. Images go to `.build/remembered-consent-captures`.
Offline-unknown and offline-history captures use actual helper-stop state; OCR
asserts that uncertainty/reconnect guidance remains visible while stale remembered
proposals and device Revoke actions are absent.
This is not the older interactive `--recovery-ui` mode; do not use that mode for
offscreen-only validation.

### Remembered native/helper additions

`status.rememberPending` is absent/null or an exact typed proposal:
`{id,generation,deviceID,publicKey,name,account:{issuer,subject},macID,macPublicKey,expiresAt,authorizationExpiresAt}`.
Both native key fields use canonical **standard base64**, like pairing verification;
the server wire remains base64url. IDs/generation retain canonical base64url.
Times are integer Unix milliseconds. It is never a pairing ID or terminal request.
Device rows optionally add `publicKey` and
`remembered:{generation,authorizationExpiresAt,state:"active"|"revoked"|"expired"}`.
Missing metadata grants no authority.

Native sends
`{type:"remember-decision",requestID:<UUID>,proposal:<entire captured proposal>,allow:<boolean>}`.
The helper rechecks the exact local owner/device/Mac and current server proposal,
then sends only `{id,allow}` to `mac/remember/decision` with the enrollment bearer.
It never modifies the local paired-key allowlist for this operation.

The correlated event is
`{type:"remember-result",requestID,proposalID,generation,authorizationExpiresAt,outcome:"approved"|"denied"|"unknown"|"error",message?:string}`.
Writing stdin does not confirm a decision. Unknown results are retained, not
replayed. Exact committed active generation/expiry can reconcile Allow; mere
absence cannot confirm Deny. Pending proposals and old committed authorization
are independent. Earlier uncertain results survive a new explicit decision and
helper restart in a bounded in-memory history (at most eight unresolved results);
they are never inferred to be denied merely because a proposal disappeared.
Only this operation uses these result events; existing dispatcher
and terminal approval semantics are unchanged.

## Process boundary

Internet is a second `MobileConnection`, with `.internet` transport.
It never reads/writes `mobileEnabled`. Store remembers the separate explicit
Internet On/Off preference from build 14 onward and restores On using the saved
origin and existing trust. Shutdown stops the connection without erasing that
choice; a saved preference never approves a new phone.

Native launches bundled `mobile/src/remote-main.mjs` with Node. Its first
newline-delimited JSON command is:

```json
{"type":"start","directory":"<Notify data directory>/remote-mobile","origin":"https://example.com"}
```

The internet helper must create/use that **separate, private** directory, not
the LAN `mobile` directory or its pairing authority. Native rejects origins
with credentials, paths (including `/`), queries, fragments, whitespace,
non-ASCII/percent-encoded input, backslashes, empty host, or invalid ports.
Native never trims, repairs or substitutes the configured origin.

Native emits `{type:"heartbeat"}` every five seconds while not authenticated,
including after wake. The helper must respond with its real status; after
`{type:"offline"}` on sleep, a heartbeat permits reconnecting under the existing
process-local opt-in. Native does not publish snapshots until authenticated.
When connected, ordinary snapshot/workspace publication is the heartbeat.
No received event for 25 seconds terminates the helper and clears authority.
Disable terminates the process; no automatic process restart occurs.

## Helper events

```ts
type InternetStatusEvent = {
  type: "status";
  status: {
    state: "paused" | "connecting" | "pairing" | "connected" | "error";
    url: string; // byte-for-byte configured origin
    devices: Array<{ id: string; name: string; online: boolean; pushEnabled: boolean }>;
    pendingPairingIDs: string[];
    setupURL?: string;
    pairingCode?: string; // not used for internet approval or displayed as proof
    message?: string;
  };
};
type InternetPairingEvent = {
  type: "pairing";
  id: string;
  name: string;
  verificationData?: string;
};
```

- Devices: at most 64; unique, nonempty IDs up to 128 characters and nonempty
  names up to 100. `connected` requires at least one online device.
- `online` and `connected` must mean a genuinely authenticated encrypted device
  channel, never relay connectivity, successful login, invitation, or approval
  alone. This semantic guarantee belongs to the bundled helper.
- Pending IDs: at most eight unique, nonempty values up to 128 characters.
- Pairing ID must appear in the preceding status's pending list. Pairing name is
  nonempty, up to 100 characters. Internet pairing needs no `code` field.
- `verificationData` is optional while handshake data is pending; when present,
  it is nonempty printable ASCII, at most 512 bytes, never truncated. Preview
  approval specifically requires the complete canonical base64 P256 uncompressed
  public key: 88 ASCII characters encoding 65 bytes beginning with `0x04`.
  Native validates this representation, not key possession or curve membership;
  the helper must validate the real key and handshake before requesting approval.
- `setupURL`, when present, is at most 4096 bytes and must use the configured
  HTTPS scheme, host and explicit port with no credentials. Path/query/fragment
  are allowed here. The approved preview puts the **complete Mac public key** in
  the fragment as public binding data, never a login token. The phone scans this
  Mac's QR in person and pins that key.
- The native pane renders the device's complete `verificationData` selectable,
  wrapping and monospaced. “Confirm full public key matches” binds approval to
  the exact currently displayed pairing object. No short code/hash is proof.
- Any non-connected status invalidates internet tickets/workspace generations
  and forgets pending internet result routing. LAN authority remains separate.

Native emits existing pairing commands, with the full displayed key attached
to positive internet approval (LAN remains unchanged):

```ts
{ type: "invite" }
{ type: "pair", id: string, allow: boolean, verificationData?: string }
{ type: "revoke", id: string }
```

On positive internet approval, the helper must require `verificationData` to
exactly equal the public key bound to that immutable pending pairing ID, not
just trust `allow`. The helper must require handshake/key possession and native approval, scope
request IDs across its individual device channels, revoke its allowlist entry,
update status, and drop pending device commands/results when that device's
authenticated channel ends. Never replay across reconnect.

`{type:"error",message:string}` fails closed and stops the internet helper.
Diagnostics on stderr are surfaced as errors, not proof of connection.
Malformed events fail closed.

## Existing action schemas are unchanged

Helper to native:

```ts
{ type: "reply", id: string, sessionID: string, requestID: string, ticket: string,
  decision: string, answers?: Record<string,string[]>, permissionOptionID?: string, feedback?: string }
{ type: "control", id: string, sessionID: string, ticket: string,
  action: "queue"|"interrupt"|"stop", text: string, agentID?: string }
{ type: "workspace_watch", sessionIDs: string[] }
```

Reply IDs are nonempty, at most 128 characters. Controls use UUID IDs,
nonempty session IDs up to 128, tickets up to 256, optional nonempty agent IDs
up to 128, text up to 16,000 UTF-16 units; stop text must be empty and other
control text nonblank. Watches contain at most eight unique nonempty IDs up
to 128 characters. All existing native registry validation, generation/ticket
checks, pre-dispatch audit, exact target checks and ACK semantics still apply.

Native to helper retains `snapshot`, `workspace`, `workspace_detail`,
`result` and `control_result` schemas. Results are routed only to the originating
transport; a socket write alone is never success. Tickets and workspace
generations are distinct for each transport and refreshed after disconnect.
Disconnected in-flight work remains visibly uncertain, never automatically
resent. Helper device-level ownership must apply the same rule.

## Parent integration

- Bundle/implement `remote-main.mjs` against the above contract, including
  `heartbeat`, P256 key possession, QR origin binding and device-level result
  ownership.
- Add `InternetSettingsView(internet: store.internet)` to native settings and
  its source file to `scripts/check-ui.sh`'s explicit compiler inputs.
- Review the full integrated protocol before any deployment or real pairing.
  Passing these fixture checks is not security clearance.
