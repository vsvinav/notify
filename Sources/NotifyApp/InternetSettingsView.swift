import SwiftUI
import CoreImage.CIFilterBuiltins

struct InternetSettingsView: View {
    @ObservedObject var internet: MobileConnection
    @State private var confirmingFreshSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Internet access").font(WorkspaceType.text(18, strong: true))
            TextField("Service HTTPS URL", text: Binding(
                get: { internet.internetOrigin }, set: { internet.setInternetOrigin($0) }))
                .textFieldStyle(.roundedBorder)
                .disabled(internet.enabled)
                .accessibilityLabel("Service HTTPS URL")
            Text("Use an exact origin, such as https://notify.example.com, without a trailing slash or path.")
                .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
            Toggle("Enable internet", isOn: Binding(get: { internet.enabled }, set: { internet.setEnabled($0) }))
            Text("Off until you enable it. Notify remembers your choice and reconnects on launch when enabled. Internet devices still require separate approval; Wi-Fi pairing does not grant internet access. Sending instructions can use model credits.")
                .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
            HStack(spacing: 8) {
                Image(systemName: "network").foregroundStyle(Palette.accent)
                Text(stateLabel).font(WorkspaceType.text(13, strong: true))
                if internet.starting { ProgressView().controlSize(.small) }
                Spacer()
                if internet.enabled {
                    Button("Disable internet") { internet.setEnabled(false) }
                }
            }
            if let error = internet.error {
                Text(error).font(WorkspaceType.text(12)).foregroundStyle(Palette.amber).textSelection(.enabled)
            }
            if let status = internet.internetStatus {
                if let message = status.message, status.state != .error {
                    Text(message).font(WorkspaceType.text(12)).foregroundStyle(Palette.muted).textSelection(.enabled)
                }
                if let proposal = status.rememberPending {
                    rememberedConsent(proposal)
                }
            }
            if let decision = internet.rememberedDecision {
                Text(decision.message ?? decisionLabel(decision))
                    .font(WorkspaceType.text(12))
                    .foregroundStyle(decision.outcome == .unknown || decision.outcome == .error ? Palette.amber : Palette.muted)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(internet.rememberedDecisions.filter {
                $0.outcome == .unknown && $0.requestID != internet.rememberedDecision?.requestID
            }, id: \.requestID) { decision in
                Text("Earlier decision for \(decision.proposal.name) remains unconfirmed. Request: \(decision.proposal.id). It will not be sent again.")
                    .font(WorkspaceType.text(12)).foregroundStyle(Palette.amber)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let status = internet.internetStatus {
                ForEach(status.devices) { device in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "iphone").font(.system(size: 22)).foregroundStyle(Palette.muted)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name).font(WorkspaceType.text(13, strong: true))
                            Text(device.online && status.state == .connected ? "Connected" : "Not connected")
                                .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                            Text(rememberedLabel(device.remembered))
                                .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if status.devices.contains(where: { $0.remembered != nil }) {
                            Text("Remembered access is separate from account sign-in. Revoke removes all internet access for this device; it does not sign out the account.")
                                .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button("Revoke") { internet.revoke(device.id) }
                            .help("Remove this device's internet access")
                    }
                }
                Button("Pair an internet device") { internet.invite() }
                if let setupURL = status.setupURL {
                    if let image = qrCode(setupURL) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 160, height: 160)
                            .padding(8).background(.white)
                            .accessibilityLabel("Scan this Mac's internet pairing invitation in person")
                    }
                    Text("Scan this invitation from your device in person. The QR pins this Mac's public key; then compare the device's complete public key below.")
                        .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                    Text(setupURL).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let pairing = internet.pairing {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect \(pairing.name)?").font(WorkspaceType.text(16, strong: true))
                        if let verification = pairing.verificationData {
                            Text("Compare this complete public key with the complete key shown on your device. Confirm only if every character matches:")
                                .font(WorkspaceType.text(12))
                            Text(verification).font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Waiting for the complete device public key. A short pairing code cannot verify an internet device.")
                                .font(WorkspaceType.text(12)).foregroundStyle(Palette.amber)
                        }
                        HStack {
                            Button("Confirm full public key matches") { internet.confirmPairing(true, expected: pairing) }
                                .disabled(!internet.canConfirmPairing)
                            Button("Reject") { internet.confirmPairing(false, expected: pairing) }
                        }
                    }.padding(12).background(Palette.raised, in: RoundedRectangle(cornerRadius: 9))
                }
            }
            Divider()
            Text("Pairing recovery").font(WorkspaceType.text(13, strong: true))
            Text("If your phone uses a different Notify account, sign in with the original passkey. If you cannot, start fresh and approve the phone again.")
                .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
            Button("Start fresh internet setup") { confirmingFreshSetup = true }
                .disabled(!internet.canStartFreshInternetSetup)
            if internet.enabled {
                Text("Turn off Enable internet before starting fresh.")
                    .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
            } else if !internet.canStartFreshInternetSetup {
                Text("Waiting for the internet helper to stop. Your saved setup has not changed.")
                    .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
            } else if internet.internetBackupURL != nil {
                Text("The previous setup is kept in a private backup on this Mac. Enable internet, then pair your phone and compare its full public key.")
                    .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
            }
            Text("Your Mac must stay awake. Disconnected commands are not replayed; check the session before retrying an uncertain action.")
                .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .alert("Start fresh internet setup?", isPresented: $confirmingFreshSetup) {
                Button("Cancel", role: .cancel) {}
                Button("Back up and start fresh", role: .destructive) { internet.startFreshInternetSetup() }
            } message: {
                Text("Keep the old internet identity and pairing in a private backup on this Mac, then start with a new identity the next time you enable internet. Previously paired phones must be paired and approved again.\n\nTerminal sessions, local notifications, Wi-Fi pairing and Google passkeys are unchanged. Internet stays off.")
            }
    }

    private func rememberedConsent(_ proposal: RememberedProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remember this phone?").font(WorkspaceType.text(16, strong: true))
            Text(proposal.name).font(WorkspaceType.text(13, strong: true))
            Text("Compare the complete public key with your phone. Pairing alone does not allow remembered access.")
                .font(WorkspaceType.text(12))
            Text(proposal.publicKey).font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("Allow this phone to connect without hourly account sign-in for up to 30 days, until the exact expiry below. This does not extend the account session.")
                .font(WorkspaceType.text(13)).fixedSize(horizontal: false, vertical: true)
            Text("Anyone who can use this phone’s private key can use its remembered Notify access. Only allow a phone you control.")
                .font(WorkspaceType.text(13)).fixedSize(horizontal: false, vertical: true)
            Text("Authorization ends: \(exactDate(proposal.authorizationExpiresAt))")
                .font(WorkspaceType.text(13, strong: true)).textSelection(.enabled)
            Text("Decide before: \(exactDate(proposal.expiresAt))")
                .font(WorkspaceType.text(12)).textSelection(.enabled)
            Text("Account: \(proposal.account.subject)\nService: \(proposal.account.issuer)")
                .font(WorkspaceType.text(12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("Phone: \(proposal.deviceID)\nRequest: \(proposal.id)\nGeneration: \(proposal.generation)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Allow") { internet.decideRemembered(true, expected: proposal) }
                Button("Deny") { internet.decideRemembered(false, expected: proposal) }
                if internet.rememberedDecision?.proposal.id == proposal.id,
                   internet.rememberedDecision?.outcome == .sending {
                    ProgressView().controlSize(.small).accessibilityLabel("Waiting for confirmation")
                }
            }
            .disabled(proposal.isExpired || internet.rememberedDecision?.outcome == .sending ||
                      (internet.rememberedDecision?.proposal.id == proposal.id && internet.rememberedDecision?.outcome != .error))
        }.padding(12).background(Palette.raised, in: RoundedRectangle(cornerRadius: 9))
    }

    private func exactDate(_ milliseconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    private func rememberedLabel(_ value: RememberedAuthorization?) -> String {
        guard let value else { return "No remembered authorization reported" }
        if value.isActive { return "Remembered until \(exactDate(value.authorizationExpiresAt))" }
        if value.state == .revoked { return "Remembered access off · revoked" }
        return "Remembered access expired · \(exactDate(value.authorizationExpiresAt))"
    }

    private func decisionLabel(_ decision: RememberedDecision) -> String {
        switch decision.outcome {
        case .sending: return "Waiting for the service to confirm your decision…"
        case .unknown: return "Decision not confirmed. Checking status; it will not be sent again."
        case .approved: return "Allow confirmed. Current remembered access is shown with the device."
        case .denied: return "Request denied. Any previous authorization is shown with the device."
        case .error: return "Decision failed. Check the current request before trying again."
        }
    }

    private var stateLabel: String {
        guard internet.enabled else { return "Paused · disabled on this Mac" }
        if internet.error != nil { return "Error" }
        guard let state = internet.internetStatus?.state else { return internet.starting ? "Connecting" : "Paused" }
        switch state {
        case .paused: return "Paused"
        case .connecting: return "Connecting"
        case .pairing: return "Pairing · approval required"
        case .connected: return "Connected"
        case .error: return "Error"
        }
    }

    private func qrCode(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: image, size: scaled.extent.size)
    }
}
