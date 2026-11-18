# Phone and internet setup

[Back to Notify](../README.md) · [Mac installation and agent setup](guide.md)

Local Mac use needs **no Notify cloud service**. Same-Wi-Fi phone use has a separate [LAN setup](https://github.com/vsvinav/notify-mobile/tree/feature/remote-access#quickstart). This guide covers the optional internet connection and a personal Render/Firebase backend. It does not create resources, enable billing or grant permissions for you.

## 1. Decide whether you are a user or an operator

**Joining an existing service?** Get its HTTPS origin and compatible client release from an operator you trust. Skip to [pairing](#6-pair-your-mac-and-phone). You do **not** need your own Firebase project, Google service account or Render account. Never send an operator your agent login, private device keys or passkey.

**Running your own service?** Complete sections 2–5 first. You need:

- A personal Render account and access to the matching [notify-mobile branch](https://github.com/vsvinav/notify-mobile/tree/feature/remote-access).
- A **separate Notify-only Firebase Spark project**, its `(default)` Firestore database and a restricted backend service account. Do not reuse a work project, work credentials or an unrelated Firebase project.
- For native Android passkeys: the actual package name and SHA-256 signing-certificate fingerprint of the APK you distribute.
- For Android FCM: a client built for the **same Firebase project** as this backend. A stock APK configured for another project is not automatically compatible with your project's FCM sender.

Render hosts the HTTPS page, account service and encrypted relay. Firestore persists public trust records and minimal private push-routing metadata, **not chats or commands**. FCM delivers only generic notifications. Your Mac remains the authority for live state and actions. Internet browser push is not implemented.

## 2. Create the isolated Firebase project and database

1. In the [Firebase console](https://console.firebase.google.com/), choose **Add project** and create a new personal, Notify-only project. Leave Google Analytics off unless you separately want it. Keep the **Spark** plan: do not link a billing account or accept a Blaze upgrade for this guide.
2. Record the **project ID**, represented here as `YOUR_PROJECT_ID`. A project ID is not a service-account key.
3. Open **Firestore Database** (currently under **Databases & Storage > Firestore**), choose **Create database**, use **Standard edition**, the **`(default)`** database, and choose a suitable location. Location affects latency and cannot simply be changed later.
4. Select **Production mode**, not Test mode. Confirm that client rules deny all access:

   ```text
   rules_version = '2';
   service cloud.firestore {
     match /databases/{database}/documents {
       match /{document=**} {
         allow read, write: if false;
       }
     }
   }
   ```

5. In the same project's Google Cloud **APIs & Services**, confirm **Cloud Firestore API** (`firestore.googleapis.com`) is enabled. If enabling Android alerts, also enable **Firebase Cloud Messaging API** (`fcm.googleapis.com`, HTTP v1), not the legacy messaging API.

Only the backend uses Firestore. These deny-all rules do not block the server's IAM identity; they intentionally block direct browser/mobile access. Do not add a public rule to resolve a backend IAM error. Firebase Authentication, Cloud Functions, paid backups and a paid Render disk are not required.

Sources: [Firestore setup and production mode](https://firebase.google.com/docs/firestore/quickstart), [Firebase plans](https://firebase.google.com/docs/projects/billing/firebase-pricing-plans), [FCM HTTP v1 authorization](https://firebase.google.com/docs/cloud-messaging/auth-server).

## 3. Provision a restricted backend identity

Use the Google Cloud console with **only the new Notify project selected**. The human configuring IAM needs permission to create the account/key and grant its roles; those administrative permissions do not belong on the runtime service account.

1. Open **IAM & Admin > Service Accounts > Create service account**. Create a dedicated account, such as `notify-backend`.
2. Grant it **Cloud Datastore User** (`roles/datastore.user`) on this project for Firestore data access. This is a data role, not Owner, Editor or Firebase Admin. It is broader than individual Notify records, which is why the project must be dedicated.
3. For FCM, grant a project custom role containing only **`cloudmessaging.messages.create`**. Under **IAM & Admin > Roles > Create role**, add that permission, then grant the role to the service account in IAM. If you choose a predefined role instead, **Firebase Cloud Messaging API Admin** (`roles/firebasecloudmessaging.admin`) includes sending but is broader; it is not the least-privilege option. Do not grant unrelated administration or service-agent roles.
4. Open this service account's **Keys > Add key > Create new key > JSON**. Download the file to private storage outside any Git checkout, for example `/path/to/notify-firebase.json`. On macOS/Linux restrict it with `chmod 600 /path/to/notify-firebase.json`.
5. If organization policy blocks key creation, stop; do not disable organization policy or borrow another account's credentials. This Notify backend requires an explicit key file and does not implement workload federation.

The backend accepts only its explicit Notify project/key configuration. It does **not** use Application Default Credentials, `gcloud auth`, a work login, `GOOGLE_APPLICATION_CREDENTIALS`, or a fallback personal credential. Do not run generic Firebase examples that introduce those credentials into this setup.

Never put this JSON in Git, an environment-variable value, an APK/browser, logs, screenshots, an issue or chat. Firebase's Android client configuration is a different file; **a service-account private key never belongs in `google-services.json`**.

Sources: [Firestore IAM roles](https://docs.cloud.google.com/iam/docs/roles-permissions/firestore), [FCM role/permission names](https://docs.cloud.google.com/iam/docs/roles-permissions/firebasecloudmessaging), [custom roles](https://docs.cloud.google.com/iam/docs/creating-custom-roles), [service-account key creation](https://docs.cloud.google.com/iam/docs/keys-create-delete).

## 4. Create one Render Free web service

1. In the [Render dashboard](https://dashboard.render.com/), choose **New > Web Service** and connect your accessible copy of `notify-mobile`. Select the compatible `feature/remote-access` branch or the reviewed commit specified by your client release. Do not deploy the Mac repository.
2. Select **Node** and **Free**. Keep one instance (`numInstances: 1`); do not add workers, databases, disks or a custom domain. The checked-in `render.yaml` is a reference blueprint, not evidence that anything is deployed.
3. Set:

   | Setting | Value |
   | --- | --- |
   | Build command | `NODE_TLS_REJECT_UNAUTHORIZED=1 npm ci --ignore-scripts` |
   | Start command | `NODE_TLS_REJECT_UNAUTHORIZED=1 node src/hosted-main.mjs` |
   | Health-check path | `/healthz` |
   | Node version | `NODE_VERSION=22` |
   | Automatic deploys | Off (`autoDeploy: false`) |
   | Runtime TLS verification | `NODE_TLS_REJECT_UNAUTHORIZED=1` |

   **Do not use `npm start`: that starts the LAN companion, not hosted ingress.** Render supplies `PORT` and its own ingress variables; do not fabricate them.
4. Under **Environment > Secret Files > Add Secret File**, use filename **`notify-firebase.json`**. Transfer the downloaded key's contents directly into Render's managed secret-file field, never an ordinary environment variable. It is available at **`/etc/secrets/notify-firebase.json`**.
5. Set the following non-secret configuration before allowing enrollment:

   | Variable | Value |
   | --- | --- |
   | `NOTIFY_FIREBASE_PROJECT_ID` | `YOUR_PROJECT_ID` |
   | `NOTIFY_FIREBASE_CREDENTIALS_FILE` | `/etc/secrets/notify-firebase.json` |
   | `NOTIFY_ORIGIN` | `https://YOUR_SERVICE.onrender.com` |
   | `NOTIFY_FCM_ENABLED` | `true` only when Android FCM is configured; otherwise omit |
   | `NOTIFY_ANDROID_PACKAGE_NAME` | `app.notify.android` when enabling native Android |
   | `NOTIFY_ANDROID_SHA256_CERT_FINGERPRINTS` | Your approved release certificate fingerprint(s), as described below |

   Replace the example origin with the service's **exact assigned HTTPS origin**: no trailing slash, path, query or port. The hosted entrypoint currently requires its assigned Render hostname; custom domains are not supported. If the hostname is not available until the first deployment, omit `NOTIFY_ORIGIN` initially: it derives the same exact origin from Render. Set it explicitly once known.
6. Save configuration and deploy the reviewed commit manually. Render may redeploy when a secret file is saved. Wait for readiness before pairing; a deployment started before Firebase is configured is **not** a durable enrollment service.

Both Firebase variables are required together. On Render, projected secret symlinks are supported only within the managed `/etc/secrets` mount; arbitrary credential symlinks are rejected. Do not copy a secret to a public folder or weaken validation to fix an unreadable-file error.

Without these Firebase variables, development uses local/memory state that **does not survive Render Free restarts reliably**. Do not treat that mode as hosted production or as a way to repair a failed durable deployment. Invalid configured Firebase fails closed, not back to local storage.

Sources: [Render Node service creation](https://render.com/docs/deploy-node-express-app), [environment and secret files](https://render.com/docs/configure-environment-variables), [Notify ingress and storage details](https://github.com/vsvinav/notify-mobile/blob/feature/remote-access/docs/render-hosting.md).

## 5. Configure native Android and Digital Asset Links

Browser users can skip Android configuration. The current native Android package supports **Android 9+ (API 28), arm64**, with a compatible passkey provider. Obtain a versioned APK and its release notes from your service operator; Android distribution/source access is separate from the public Mac download.

**The stock Android app has a fixed service origin; there is no arbitrary server picker.** To operate a different backend, you need access to the Android source and its matching build instructions. Build your own client with your exact service origin in `controller/RelationshipStore.kt` and matching Firebase Android configuration. Build requirements include JDK 17, Rust 1.91.0 with the `aarch64-linux-android` target and Android NDK 28.2.13676358; build the native library before the release APK. Follow the supplied `README.md` and `crypto/README.md` for exact branch and signing steps. Preserve your signing key for future updates. If source access is unavailable, use the self-hosted browser client; do not assume the stock APK can connect.

1. Use the Android release/build instructions supplied with the client. The hosted backend currently accepts **`app.notify.android`**, not an arbitrary renamed package.
2. Obtain the **release APK's certificate SHA-256 fingerprint**, not the APK file checksum, upload-key fingerprint for a differently signed Play build, or an unrelated debug certificate. With Android SDK build tools:

   ```sh
   apksigner verify --print-certs /path/to/Notify-release.apk
   ```

   Format its SHA-256 digest as **32 uppercase hexadecimal pairs separated by colons**. Set `NOTIFY_ANDROID_SHA256_CERT_FINGERPRINTS` to one fingerprint, or **1–4 distinct fingerprints separated by commas without spaces** when intentionally supporting a signing transition. Do not authorize debug certificates on a shared service.
3. Set `NOTIFY_ANDROID_PACKAGE_NAME=app.notify.android` alongside the fingerprints. Deploy and fetch:

   ```sh
   curl --fail --show-error https://YOUR_SERVICE.onrender.com/.well-known/assetlinks.json
   ```

   Confirm the actual package and expected release fingerprints are present over valid public HTTPS. The backend generates the Digital Asset Links statement and permitted Android passkey origins from this configuration. Do not add arbitrary Android origins, use wildcard trust or bypass certificate checks to make sign-in work.
4. For FCM on your own backend, register the Android app with that same Firebase project in **Project settings > Your apps > Add app > Android** using the supported package name. Build the client using that project's Android Firebase configuration as directed by its build guide. Keep local configuration out of Git and release archives unless the build guide explicitly identifies the necessary public app resources. Never substitute the service-account JSON.
5. In the installed Android app, sign in and pair before enabling alerts. Open **Settings > Notifications > Enable notifications** and allow Android's permission prompt (`POST_NOTIFICATIONS` on Android 13+). The channel is **Mac attention**; use **Android sound, vibration & permission settings** to adjust it. Channel sound/vibration, Do Not Disturb, battery restrictions and OS settings can affect delivery. FCM/Google Play services must be available.

A matching package name alone is not enough for passkeys: the certificate must match too. FCM project alignment is separate from Digital Asset Links. A browser login working does not validate native Android login, and FCM API acceptance does not validate a physical notification.

Sources: [Digital Asset Links](https://developers.google.com/digital-asset-links/v1/getting-started), [APK signature inspection](https://developer.android.com/tools/apksigner), [Firebase Android setup](https://firebase.google.com/docs/android/setup), [Android notification permission](https://developer.android.com/develop/ui/views/notifications/notification-permission).

## 6. Pair your Mac and phone

1. Install a matching Mac release and connect your original agent terminal explicitly. Confirm local Notify works first.
2. Open Mac **Settings > Internet**, enter `https://YOUR_SERVICE.onrender.com` (your operator's real origin), then turn on **Enable internet**. It is off initially. From Mac build 14, Notify remembers your choice and reconnects on launch when enabled; explicitly turning it off keeps it off. Enable it once after upgrading from an older build. LAN phone approval does not grant internet access.
3. The updated Mac helper prepares a fresh QR when enabled. In Android 0.3.0, choose **Scan Mac QR**, allow camera access and scan it; **Paste pairing link instead** remains available. Older builds may require manual pairing-link entry. If preparation fails or the invitation expires, choose **Pair an internet device** on the Mac to retry without resetting saved trust. Finish or reject an existing pending pairing first. Invitations are short-lived and pin the Mac key; never put the QR, invitation URL or token in public troubleshooting.
4. Register or sign in with a passkey through the compatible phone client. Use the **same account/passkey** when returning to an existing pairing. An account login alone does not approve a new phone.
5. Compare the **complete phone public key** on the phone and Mac, character for character. Choose **Confirm full public key matches** only when it matches; otherwise reject. A friendly device name, truncated fingerprint or six-digit LAN comparison cannot replace this step.
6. Wait for connected state. Review live state using a harmless demo before relying on remote control. A sent message is not a completed action: wait for the exact native acknowledgment.

The Mac must remain awake, online and running Notify. After sleep or a network interruption, a fresh authenticated encrypted channel is required. If a reply is uncertain, check the original session before retrying; Notify never automatically replays it. Do not use a real destructive permission request as a connectivity test.

The relay carries encrypted session payloads. The service can still see account/public-key relationships, connection timing and minimal notification routing metadata. Firestore stores approved public account/device trust, a hash of the Mac credential and private push tokens when enabled—not chat history, commands, private endpoint keys or live encrypted-channel state.

## 7. Restarts, quotas and verification

**A normal restart with durable Firestore preserves approved pairing.** Account sessions, challenges and routing grants are short-lived/process-local; sign in again when asked. Reconnection does not silently reapprove a phone. Keep only one service instance; overlapping deployments can cause temporary errors as the old instance loses authority.

**Old memory-only records already lost cannot be reconstructed.** One explicit new enrollment may be necessary. Use the same intended account, retain local pinned identities and perform full-key approval again. A different saved owner or unreadable Mac hardware-backed identity is a stop condition—not permission to delete state, import caller-supplied trust or silently register a replacement.

Free-tier limits are real:

- Render Free normally sleeps after 15 minutes without inbound traffic; waking takes about a minute. It has 750 shared workspace instance-hours/month plus bandwidth/build limits. Local files disappear on restart/redeploy/sleep.
- Firestore's free quota currently includes **50,000 reads/day, 20,000 writes/day, 1 GiB storage and 10 GiB outbound/month**, with one free database. This is not an unlimited shared service. A continuously connected Mac/phone can use roughly **20,160 reads/day**, and two phones roughly **37,440**, before extra sign-ins/retries/deployments. See the [capacity calculation](https://github.com/vsvinav/notify-mobile/blob/feature/remote-access/docs/render-hosting.md#overlapping-deploys-limits-and-free-quotas).
- Monitor usage in the consoles. Quota errors intentionally interrupt authorization rather than bypass storage or enable billing. Do not add a billing account, upgrade Spark or buy a plan merely to complete this guide. A Render payment method can allow overage charges; inspect spending controls yourself.

Before calling your deployment ready:

1. Fetch `https://YOUR_SERVICE.onrender.com/healthz`; expect HTTP 200 and `{"status":"ok"}`. This checks readiness, **not** account security, pairing or delivery.
2. Verify public HTTPS, Android Digital Asset Links if used, and passkey login in the actual client.
3. Pair through full-key confirmation and inspect harmless live state. Test supported actions only with synthetic/demo requests.
4. Keep a test connection open through multiple renewals. Briefly disconnect/reconnect, then sleep/wake the Mac when safe. Confirm that old/uncertain actions are not replayed.
5. During a planned service restart, confirm the same approved pairing survives, while fresh sign-in is requested when needed. Do not test by deleting Firestore documents.
6. For alerts, opt in on a physical Android phone, put it in the background/lock it, and trigger a harmless demo attention event. Verify the notification is generic, sound/vibration behave as configured, and tapping fetches fresh encrypted state. A Google `validate_only` result validates API authorization/payload only—not delivery. Physical delivery, sound and vibration remain unverified until this test passes on your device.

Sources: [Render Free limitations](https://render.com/docs/free), [Firestore quotas](https://firebase.google.com/docs/firestore/quotas).

## 8. Revoke, rotate and recover safely

- **Lost/untrusted phone:** use **Revoke** for that device in Mac Internet settings. Revocation removes its durable approval and push routing. A notification already delivered cannot be recalled. Disable internet to stop this Mac's current remote access while investigating.
- **Stopping alerts:** choose **Turn notifications off** in Android Settings and, if desired, disable OS notifications too. If cleanup was interrupted, use **Finish removing notification routing** when connected. Revoking the pairing also removes its server push registration.
- **Routine backend key rotation:** create a new key for the same restricted service account, replace the managed Render secret, redeploy and verify readiness/reconnection. Then disable/delete the old key in Google Cloud. Do not rotate endpoint identities or erase Firestore as part of this operation.
- **Exposed backend key:** revoke the exposed key promptly, even if it causes downtime; provision a replacement, audit IAM and the deployment, and assess trust-record integrity before reopening access. Never paste the exposed key into a report.
- **Signing-key changes:** retain the supported Mac nested signer; arbitrary rebuild/re-sign operations can make saved hardware-backed keys inaccessible. For Android certificate rotation, approve only the intentional new release fingerprint and test passkeys before removing the old one.
- **Lost passkey or owner mismatch:** try signing in with the original Notify passkey first. Creating another account, even in the same Google password manager, does not restore the original account. If you deliberately want a new internet identity, use the confirmed local recovery steps below. No account or phone trust is transferred automatically.
- **Unreadable hardware key or corrupt service database:** stop and investigate with the operator. Recovery does not repair keys or service storage. Do not delete Firestore records or restore an old backend lacking durable-state protections against current records.

### Start fresh internet setup

This action requires Mac build 7 or newer; beta 4/build 6 does not include it.

1. In **Settings > Internet**, turn **Enable internet** off. Wait for the helper to stop; recovery is disabled while it could still write to the old setup.
2. Choose **Start fresh internet setup** under **Pairing recovery** and read the confirmation. **Cancel** changes nothing.
3. Choose **Back up and start fresh** only if you intend to retire this Mac's current internet identity. Notify moves the old private setup to a unique `remote-mobile-backup-<id>` directory inside `~/Library/Application Support/Notify`. It does not erase the old hardware-backed key, modify terminal sessions or LAN pairing, or delete Google passkeys. If the backup fails, no new setup starts.
4. Internet stays off. When you explicitly enable it again, Notify creates a new Mac identity. Obtain a fresh invitation, sign in on your phone, and compare and approve its complete public key again. A previously paired phone is not automatically trusted.

Backups contain private registration and pairing data: keep them private and out of Git or support attachments. This is a new local enrollment, not account recovery, automatic restoration, or deletion of old server records. For a lost or untrusted phone, use **Revoke** rather than treating a backup as server-side revocation.

## Safe troubleshooting

| Symptom | Check safely |
| --- | --- |
| Host is slow/unreachable | Wait for Render wake-up; check service status, Free quotas and public TLS. Never turn TLS verification off. |
| `/healthz` returns 503 | Check deployment status, project-ID/path configuration, Firestore API and IAM/quota status. Some transient faults recover automatically; corruption/ownership conflicts need intervention. Do not delete records. |
| Credential file rejected | Check the exact `/etc/secrets/notify-firebase.json` mount and same-project service account. Do not print the key, use env-var JSON, or follow arbitrary symlinks. |
| Native Android passkey fails | Verify the actual installed APK signer, supported package, DAL response, exact origin and passkey provider. Browser success is not native verification. |
| Sign-in works but pairing does not | Check whether this is the saved account, whether old memory-only enrollment was lost, and whether a fresh local invitation/full-key confirmation is required. Never transfer trust silently. |
| Account differs from the locally approved owner | Use the original Notify passkey, or deliberately confirm **Start fresh internet setup** on the Mac after disabling internet. Do not keep creating accounts or deleting credentials. |
| Pairing conflict or expired registration | Finish or reject an existing pending phone, or wait for its three-minute expiry, then choose **Pair an internet device** for a fresh invitation. Persistent enrollment conflicts can use the confirmed recovery flow above. |
| Mac unavailable after wake/update | Open Notify, explicitly enable internet if restarted, verify connectivity and saved identity availability. Do not restart agent terminals or replace keys automatically. |
| No alert | Check app opt-in, Android permission/channel, same-project FCM configuration, sender permission and phone connectivity. API acceptance is not delivery. |
| Action timeout | Inspect the actual agent/session before retrying; delivery can be uncertain. Do not increase permissions or auto-resend. |

Share only sanitized error text, app versions, deployment commit and a general description of the failed step. Do not attach account/device identifiers, private paths, runtime databases, cookie/header dumps, setup URLs, keys, push tokens or screenshots containing private state.
