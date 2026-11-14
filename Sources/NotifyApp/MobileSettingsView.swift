import SwiftUI
import CoreImage.CIFilterBuiltins

struct MobileSettingsView: View {
    @ObservedObject var mobile: MobileConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Phone connections").font(WorkspaceType.text(18, strong: true))
            Toggle("Allow phone connections", isOn: Binding(get: { mobile.enabled }, set: { mobile.setEnabled($0) }))
            Text("Review and reply on the same Wi-Fi. Lock-screen alerts use internet push services, without sending request details.")
                .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
            if mobile.starting { ProgressView("Starting local connection…").controlSize(.small) }
            if let error = mobile.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Palette.amber).textSelection(.enabled)
            }
            if let status = mobile.status {
                HStack(spacing: 8) {
                    Image(systemName: "wifi").foregroundStyle(Palette.accent)
                    Text("\(status.devices.filter(\.online).count) online · \(status.devices.count) paired")
                        .font(WorkspaceType.text(13, strong: true))
                }
                ForEach(status.devices) { device in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "iphone").font(.system(size: 22)).foregroundStyle(Palette.muted)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name).font(WorkspaceType.text(13, strong: true))
                            Text("\(device.online ? "Connected" : "Not connected") · \(device.pushEnabled ? "Push enabled" : "Push not enabled")")
                                .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button("Revoke") { mobile.revoke(device.id) }
                            .help("Remove this phone's access and notification subscription")
                    }
                }
                HStack {
                    Button("Pair a phone") { mobile.invite() }
                    Button("Send test alert") { mobile.testPush() }.disabled(!status.devices.contains(where: \.pushEnabled))
                }
                if let message = status.pushMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled)
                }
                if let pairing = mobile.pairing {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect \(pairing.name)?").font(WorkspaceType.text(16, strong: true))
                        Text("Confirm this code matches the phone:").font(WorkspaceType.text(12))
                        Text(pairing.code).font(.system(size: 24, weight: .medium, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            Button("Confirm phone") { mobile.confirmPairing(true) }
                            Button("Reject") { mobile.confirmPairing(false) }
                        }
                    }.padding(12).background(Palette.raised, in: RoundedRectangle(cornerRadius: 9))
                }
                if let code = status.pairingCode {
                    HStack(alignment: .top, spacing: 16) {
                        if let image = qrCode(status.setupURL) {
                            Image(nsImage: image).interpolation(.none).resizable().frame(width: 132, height: 132)
                                .padding(8).background(.white)
                                .accessibilityLabel("Scan to set up Notify on your phone")
                        } else {
                            Text("QR unavailable. Open the setup address below.")
                                .font(WorkspaceType.text(12)).foregroundStyle(Palette.amber)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Scan, install, then pair").font(WorkspaceType.text(14, strong: true))
                            Text("Trust the local certificate, add Notify to your Home Screen, then enter this code in the installed app.")
                                .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                            Text(code).font(.system(size: 22, weight: .medium, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    Text(status.setupURL).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Text("Before trusting, compare the certificate SHA-256 fingerprint with this Mac:")
                        .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                    Text(status.fingerprint).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Trust is manual. Revoking a phone removes app access; remove the certificate profile on the phone to remove its trust.")
                        .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                }
                DisclosureGroup("Connection address") {
                    Text(status.url).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Button("Copy address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(status.url, forType: .string)
                    }
                }.font(WorkspaceType.text(12))
                Text("Your Mac must stay awake. Connected means the phone app is open; Push enabled does not prove an alert was delivered.")
                    .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
