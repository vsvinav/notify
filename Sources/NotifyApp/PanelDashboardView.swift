import SwiftUI
import AppKit

struct PanelDashboardView: View {
    @ObservedObject var panel: PanelConnection
    @FocusState private var editorFocused: Bool
    @State private var formExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(panel.feed?.title ?? "Dashboard").font(WorkspaceType.text(28, strong: true))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Your provider’s work, inside Notify.").font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 8) {
                    formShortcut
                    HStack(spacing: 6) {
                        Circle().fill(panel.isFresh ? Palette.diffAdded : Palette.amber).frame(width: 6, height: 6)
                        Text(panel.busy ? "Contacting provider…" : panel.isFresh ? "Local provider" : "Not current")
                            .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                        Button { panel.refresh() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).disabled(panel.busy || panel.confirmation != nil)
                            .accessibilityLabel("Refresh Dashboard")
                    }
                }.frame(maxWidth: 240, alignment: .trailing)
            }
            PanelReceiptView(panel: panel)
            if let error = panel.error {
                Text(error).font(WorkspaceType.text(12)).foregroundStyle(Palette.error).textSelection(.enabled)
            }
            if let reason = panel.reason {
                VStack(alignment: .leading, spacing: 5) {
                    Text(reason).font(WorkspaceType.text(14, strong: true))
                    Text(panel.feed == nil ? "Start your local provider, then refresh. Notify does not start it for you." :
                            "Cached content is read-only. Your drafts stay here; refresh when the provider is available.")
                        .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.sidebar)
            }
            if let feed = panel.feed, !feed.tabs.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(feed.tabs) { tab in
                            Button { panel.selectTab(tab.id) } label: {
                                HStack(spacing: 6) {
                                    Text(tab.label)
                                    if let badge = tab.badge { Text("\(badge)").monospacedDigit() }
                                }.font(WorkspaceType.text(13, strong: panel.selectedTab?.id == tab.id))
                                    .padding(.horizontal, 13).padding(.vertical, 10)
                                    .background(panel.selectedTab?.id == tab.id ? Palette.raised : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(panel.selectedTab?.id == tab.id ? .isSelected : [])
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
                Divider()
                if let tab = panel.selectedTab {
                    if let track = tab.validTrack {
                        HStack(alignment: .top, spacing: 20) {
                            ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 22) {
                                    HStack {
                                        Text(track.title).font(WorkspaceType.text(13, strong: true))
                                        Spacer()
                                        Text("\(tab.items.count) items").font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                                    }
                                    ForEach(track.stages) { stage in
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(spacing: 8) {
                                                Image(systemName: stage.kind == "decision" ? "diamond" : stage.kind == "gate" ? "pause.circle" : "circle")
                                                    .font(.system(size: 12)).foregroundStyle(Palette.accent)
                                                Text(stage.label).font(WorkspaceType.text(13, strong: true))
                                                Spacer()
                                                Text("\(tab.items(in: stage.id).count)").font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                                            }
                                            if let hint = stage.hint, !hint.isEmpty {
                                                Text(hint).font(WorkspaceType.text(11)).foregroundStyle(Palette.muted).padding(.leading, 21)
                                            }
                                            ForEach(tab.items(in: stage.id)) { row in itemRow(row).padding(.leading, 21) }
                                        }
                                        .background(alignment: .topLeading) {
                                            if stage.id != track.stages.last?.id {
                                                Rectangle().fill(Palette.line.opacity(0.3)).frame(width: 1)
                                                    .padding(.leading, 6).padding(.top, 18).padding(.bottom, -22)
                                                    .allowsHitTesting(false)
                                            }
                                        }
                                    }
                                    if !tab.unplacedItems.isEmpty {
                                        Text("Other items").font(WorkspaceType.text(13, strong: true))
                                        ForEach(tab.unplacedItems) { row in itemRow(row) }
                                    }
                                }.padding(.trailing, 3)
                            }
                            .onAppear {
                                if let key = panel.selectedItem?.key { proxy.scrollTo(key, anchor: .center) }
                            }
                            .onChange(of: panel.selectedItem?.key) {
                                if let key = panel.selectedItem?.key { proxy.scrollTo(key, anchor: .center) }
                            }
                            }.frame(minWidth: 200, idealWidth: 290, maxWidth: 320)
                            Divider()
                            ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 18) {
                                    if let form = tab.form {
                                        DisclosureGroup(form.title, isExpanded: $formExpanded) {
                                            formEditor(form, tab: tab).padding(.top, 12)
                                        }.id("panel-form")
                                        Divider()
                                    }
                                    if let selected = panel.selectedItem { itemDetail(selected) }
                                    else { Text("No items reported yet.").foregroundStyle(Palette.muted) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .onChange(of: formExpanded) {
                                if formExpanded { proxy.scrollTo("panel-form", anchor: .top) }
                            }.id(panel.selectedItem?.key).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else if let form = tab.form {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                formEditor(form, tab: tab)
                                genericSections(tab)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        ScrollView { genericSections(tab) }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(panel.busy ? "Loading your Dashboard…" : "No Dashboard to show yet.")
                        .font(WorkspaceType.text(23, strong: true))
                    Text("A local provider supplies the tabs, work stages and actions. Notify does not start a provider for you.")
                        .font(WorkspaceType.text(13)).foregroundStyle(Palette.muted)
                    Button("Refresh Dashboard") { panel.refresh() }.disabled(panel.busy)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .font(WorkspaceType.text(13))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: Binding(get: { panel.confirmation }, set: { if $0 == nil { panel.cancelPreview() } })) { confirmation in
            PanelConfirmationView(panel: panel, confirmation: confirmation)
        }
    }
    @ViewBuilder private var formShortcut: some View {
        let forms = (panel.feed?.tabs ?? []).filter { $0.form != nil }
        if forms.count == 1, let tab = forms.first, let form = tab.form {
            Button { focusForm(tab.id) } label: { Label(form.title, systemImage: "plus").fixedSize(horizontal: false, vertical: true) }
        } else if forms.count > 1 {
            Menu("New…") {
                ForEach(forms) { tab in
                    if let form = tab.form { Button("\(tab.label) / \(form.title)") { focusForm(tab.id) } }
                }
            }
        }
    }
    private func focusForm(_ tabID: String) {
        panel.selectTab(tabID)
        formExpanded = true
        DispatchQueue.main.async { editorFocused = true }
    }
    private func formEditor(_ form: PanelForm, tab: PanelTab) -> some View {
        let text = panel.draft(tabID: tab.id, actionID: form.actionId)
        return VStack(alignment: .leading, spacing: 14) {
            Text(form.title).font(WorkspaceType.text(23, strong: true))
            if let placeholder = form.placeholder { Text(placeholder).foregroundStyle(Palette.muted) }
            TextEditor(text: Binding(get: { panel.draft(tabID: tab.id, actionID: form.actionId) },
                                    set: { panel.setDraft($0, tabID: tab.id, actionID: form.actionId) }))
                .font(WorkspaceType.text(14)).scrollContentBackground(.hidden).padding(10)
                .frame(minHeight: 150, maxHeight: 220).background(Palette.background)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line.opacity(0.5)))
                .focused($editorFocused).accessibilityLabel(form.title)
            HStack {
                Text("\(text.utf16.count) / \(form.maxLength) UTF-16 characters · minimum \(form.minLength)")
                    .font(WorkspaceType.text(11)).foregroundStyle(form.accepts(text) || text.isEmpty ? Palette.muted : Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { panel.preview(actionID: form.actionId, text: text) } label: {
                    Text(form.submitLabel).foregroundStyle(Palette.highlightInk)
                }
                    .buttonStyle(.borderedProminent).disabled(!panel.actionsAllowed || !form.accepts(text))
            }
            Text("Preview first. Nothing is sent until you confirm. Your draft stays on this Mac, in memory.")
                .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
        }.padding(.bottom, 24).frame(maxWidth: 680, alignment: .leading)
    }
    private func itemRow(_ row: PanelLocatedItem) -> some View {
        Button { formExpanded = false; editorFocused = false; panel.selectedItemKey = row.key } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.item.id).font(WorkspaceType.text(10)).foregroundStyle(Palette.muted)
                Text(row.item.title).font(WorkspaceType.text(12, strong: true))
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(panel.selectedItem?.key == row.key ? Palette.raised : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(panel.selectedItem?.key == row.key ? Palette.line.opacity(0.45) : .clear))
        }.buttonStyle(.plain).accessibilityAddTraits(panel.selectedItem?.key == row.key ? .isSelected : [])
    }
    private func genericSections(_ tab: PanelTab) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(Array(tab.sections.enumerated()), id: \.offset) { index, section in
                VStack(alignment: .leading, spacing: 14) {
                    if !section.title.isEmpty {
                        Text(section.title).font(WorkspaceType.text(16, strong: true))
                            .foregroundStyle(section.emphasis == "attention" ? Palette.amber : Palette.ink)
                    }
                    ForEach(tab.items.filter { $0.key.hasPrefix("\(tab.id)/\(index)/") }) { row in
                        itemDetail(row)
                        Divider()
                    }
                }
            }
            if tab.items.isEmpty && tab.form == nil { Text("No items reported yet.").foregroundStyle(Palette.muted) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func itemDetail(_ row: PanelLocatedItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if !row.section.isEmpty {
                Text(row.section).font(WorkspaceType.text(11)).foregroundStyle(row.item.tone == "warn" ? Palette.amber : Palette.muted)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.line.opacity(0.4)))
            }
            Text(row.item.title).font(WorkspaceType.text(23, strong: true)).fixedSize(horizontal: false, vertical: true)
            if let subtitle = row.item.subtitle, !subtitle.isEmpty { Text(subtitle).foregroundStyle(Palette.muted).textSelection(.enabled) }
            Text(row.item.id).font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
            ViewThatFits(in: .horizontal) {
                HStack { actionButtons(row.item) }
                VStack(alignment: .leading) { actionButtons(row.item) }
            }
            if let log = row.item.log {
                Text("Recent activity").font(WorkspaceType.text(13, strong: true)).padding(.top, 8)
                ForEach(Array(log.entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 16) {
                        if let at = entry.at, !at.isEmpty { Text(at).font(WorkspaceType.text(11)).foregroundStyle(Palette.muted) }
                        Text(entry.text).font(WorkspaceType.text(12)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                }
                if log.truncated { Text("Showing a limited activity history.").font(WorkspaceType.text(11)).foregroundStyle(Palette.muted) }
            }
            if let raw = row.item.url, let url = URL(string: raw), url.scheme == "https", url.host != nil {
                Link(destination: url) { Label("Open item", systemImage: "arrow.up.right") }.padding(.top, 6)
            }
            Text("Progress and activity are reported by the provider. They do not prove that tests passed.")
                .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted).padding(.top, 8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func actionButtons(_ item: PanelItem) -> some View {
        ForEach(Array(item.actions.enumerated()), id: \.offset) { _, action in
            if action.style == "primary" {
                Button { panel.preview(actionID: action.id) } label: {
                    Text(action.label).foregroundStyle(Palette.highlightInk)
                }
                    .buttonStyle(.borderedProminent).disabled(!panel.actionsAllowed)
            } else {
                Button(action.label, role: action.style == "danger" ? .destructive : nil) { panel.preview(actionID: action.id) }
                    .disabled(!panel.actionsAllowed)
            }
        }
    }
}

struct PanelConfirmationView: View {
    @ObservedObject var panel: PanelConnection
    let confirmation: PanelConfirmation
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Review before sending").font(WorkspaceType.text(23, strong: true))
            Text(confirmation.label).font(WorkspaceType.text(14, strong: true))
            ScrollView { Text(confirmation.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 150)
            if let text = confirmation.text {
                ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .padding(12).frame(maxHeight: 150).background(Palette.sidebar)
            }
            Text("Send passes this action to your provider. Acceptance is not completion. If delivery is uncertain, check the destination before doing anything else.")
                .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
            HStack {
                Spacer()
                Button { panel.cancelPreview() } label: { Text("Cancel").foregroundStyle(Palette.highlightInk) }
                    .keyboardShortcut(.defaultAction)
                Button { panel.sendPreview() } label: { Text("Send").foregroundStyle(Palette.highlightInk) }
                    .buttonStyle(.borderedProminent).disabled(!panel.canSend)
            }
        }.font(WorkspaceType.text(13)).padding(26).frame(width: 470)
            .background(Palette.surface).foregroundStyle(Palette.ink).tint(Palette.accent)
            .onExitCommand { panel.cancelPreview() }
    }
}

struct PanelReceiptView: View {
    @ObservedObject var panel: PanelConnection
    var body: some View {
        if let receipt = panel.receipt {
            VStack(alignment: .leading, spacing: 8) {
                Text(receipt.delivery == .accepted ? "Accepted by the provider — not completed." :
                        receipt.delivery == .sending ? "Sending — awaiting the provider’s response." : "Delivery unknown. Check the destination before continuing.")
                    .font(WorkspaceType.text(12, strong: true))
                if receipt.delivery == .unknown {
                    Button("I checked the destination") { panel.acknowledgeUnknown() }.disabled(!panel.canAcknowledgeUnknown)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.sidebar).foregroundStyle(Palette.amber)
        }
    }
}

struct PanelSettingsView: View {
    @ObservedObject var panel: PanelConnection
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Custom dashboard", isOn: Binding(get: { panel.enabled }, set: { panel.setEnabled($0) }))
                .font(WorkspaceType.text(14, strong: true))
            Text("Optional. Shows a local provider’s work in Notify. Independent of phone and Internet access; turning this on does not enable either.")
                .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
            Text(panel.enabled ? "Reads only while the Dashboard is visible. Every action needs a fresh preview and confirmation." :
                    "Off. No provider is read. Pending or uncertain actions remain visible here.")
                .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
            PanelReceiptView(panel: panel)
            if let error = panel.error { Text(error).font(WorkspaceType.text(12)).foregroundStyle(Palette.error) }
        }
    }
}
