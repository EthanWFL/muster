import AppKit
import SwiftUI

enum WheelModule: String, CaseIterable, Identifiable {
    case projects, websites, clipboard, actions
    var id: Self { self }
    var symbol: String {
        switch self {
        case .projects: return "folder"
        case .websites: return "globe"
        case .clipboard: return "list.clipboard"
        case .actions: return "gearshape"
        }
    }
    var title: String {
        switch self {
        case .projects: return L10n.t("Projects")
        case .websites: return L10n.t("Websites")
        case .clipboard: return L10n.t("Clipboard")
        case .actions: return L10n.t("Quick settings")
        }
    }
}

@MainActor final class WheelPreferences: ObservableObject {
    struct AppChoice: Hashable {
        let id: String
        let name: String
    }

    static var projectOpeners: [AppChoice] {
        [
            AppChoice(id: "", name: L10n.t("System default")),
            AppChoice(id: "com.microsoft.VSCode", name: "Visual Studio Code"),
            AppChoice(id: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
            AppChoice(id: "com.apple.Terminal", name: "Terminal"),
            AppChoice(id: "com.googlecode.iterm2", name: "iTerm"),
            AppChoice(id: "com.apple.finder", name: "Finder"),
        ]
    }

    static var websiteOpeners: [AppChoice] {
        [
            AppChoice(id: "", name: L10n.t("System default")),
            AppChoice(id: "com.apple.Safari", name: "Safari"),
            AppChoice(id: "com.google.Chrome", name: "Google Chrome"),
            AppChoice(id: "company.thebrowser.Browser", name: "Arc"),
            AppChoice(id: "org.mozilla.firefox", name: "Firefox"),
        ]
    }

    private let defaults: UserDefaults
    private let board: NSPasteboard
    private var timer: Timer?
    private var lastChange = 0
    @Published private(set) var modules: [WheelModule]
    @Published private(set) var websites: [URL]
    @Published private(set) var projectOrder: [String]
    @Published private(set) var projectOpener: String
    @Published private(set) var websiteOpener: String
    @Published private(set) var clips: [String] = []
    @Published private(set) var recording: Bool

    init(defaults: UserDefaults, board: NSPasteboard = .general) {
        self.defaults = defaults
        self.board = board
        let saved = defaults.stringArray(forKey: "WheelModules")
        modules = WheelModule.allCases.filter { saved?.contains($0.rawValue) ?? true }
        websites = Array((defaults.stringArray(forKey: "WheelWebsites") ?? []).compactMap(Self.webURL).prefix(6))
        projectOrder = defaults.stringArray(forKey: "WheelProjectOrder") ?? []
        projectOpener = defaults.string(forKey: "WheelProjectOpener") ?? ""
        websiteOpener = defaults.string(forKey: "WheelWebsiteOpener") ?? ""
        recording = defaults.bool(forKey: "WheelClipboardEnabled")
        updateTimer()
    }

    deinit { timer?.invalidate() }

    func toggle(_ module: WheelModule) {
        if modules.contains(module) { modules.removeAll { $0 == module } }
        else { modules = WheelModule.allCases.filter { modules.contains($0) || $0 == module } }
        defaults.set(modules.map(\.rawValue), forKey: "WheelModules")
    }

    private static func webURL(_ value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace),
              let url = URL(string: text.contains("://") ? text : "https://" + text),
              ["https", "http"].contains(url.scheme?.lowercased()), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    func addWebsite(_ text: String) -> Bool {
        guard websites.count < 6, let url = Self.webURL(text), !websites.contains(url) else { return false }
        websites.append(url)
        saveSites()
        return true
    }

    func removeWebsite(_ url: URL) {
        websites.removeAll { $0 == url }
        saveSites()
    }

    /// Keep the persisted order aligned with the current wheel membership.
    func reconcileProjects(_ ids: [String]) {
        var order = projectOrder.filter { ids.contains($0) }
        for id in ids where !order.contains(id) { order.append(id) }
        guard order != projectOrder else { return }
        projectOrder = order
        defaults.set(order, forKey: "WheelProjectOrder")
    }

    func moveProject(_ id: String, by offset: Int) {
        guard let index = projectOrder.firstIndex(of: id) else { return }
        let target = index + offset
        guard projectOrder.indices.contains(target) else { return }
        var order = projectOrder
        order.swapAt(index, target)
        projectOrder = order
        defaults.set(order, forKey: "WheelProjectOrder")
    }

    func rank(of id: String) -> Int? { projectOrder.firstIndex(of: id) }

    func setProjectOpener(_ id: String) {
        projectOpener = id
        defaults.set(id, forKey: "WheelProjectOpener")
    }

    func setWebsiteOpener(_ id: String) {
        websiteOpener = id
        defaults.set(id, forKey: "WheelWebsiteOpener")
    }

    static func installed(_ choices: [AppChoice]) -> [AppChoice] {
        choices.filter { $0.id.isEmpty || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    private func saveSites() { defaults.set(websites.map(\.absoluteString), forKey: "WheelWebsites") }

    func setRecording(_ enabled: Bool) {
        recording = enabled
        defaults.set(enabled, forKey: "WheelClipboardEnabled")
        updateTimer()
        if !enabled { clear() }
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard recording else { return }
        lastChange = board.changeCount
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func sample() {
        guard recording, board.changeCount != lastChange else { return }
        lastChange = board.changeCount
        let excluded = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        guard !(board.types ?? []).contains(where: { excluded.contains($0.rawValue) }),
              let text = board.string(forType: .string), !text.isEmpty, board.changeCount == lastChange else { return }
        promote(text)
    }

    func restore(_ text: String) {
        guard recording, clips.contains(text) else { return }
        board.clearContents()
        if board.setString(text, forType: .string) { promote(text) }
        lastChange = board.changeCount
    }

    private func promote(_ text: String) {
        clips.removeAll { $0 == text }
        clips.insert(text, at: 0)
        clips = Array(clips.prefix(10))
    }

    func clear() {
        clips.removeAll()
        if recording { lastChange = board.changeCount }
    }
}

enum WheelSettingsSection: CaseIterable {
    case inner, projects, websites, clipboard

    var title: String {
        switch self {
        case .inner: L10n.t("Visible entries")
        case .projects: L10n.t("Quick projects")
        case .websites: L10n.t("Favorite websites")
        case .clipboard: L10n.t("Clipboard history")
        }
    }

    var symbol: String {
        switch self {
        case .inner: ProjectWheelToggle.symbol
        case .projects: WheelModule.projects.symbol
        case .websites: WheelModule.websites.symbol
        case .clipboard: WheelModule.clipboard.symbol
        }
    }
}

struct WheelConfigurationView: View {
    @ObservedObject var projects: ProjectsModel
    @ObservedObject var wheel: ProjectWheelController
    @ObservedObject private var preferences: WheelPreferences
    @Binding var section: WheelSettingsSection
    let scrollRequest: Int

    init(projects: ProjectsModel, wheel: ProjectWheelController,
         section: Binding<WheelSettingsSection>, scrollRequest: Int) {
        self.projects = projects
        self.wheel = wheel
        _preferences = ObservedObject(wrappedValue: wheel.preferences)
        _section = section
        self.scrollRequest = scrollRequest
    }
    @State private var address = ""
    @State private var invalidAddress = false
    @State private var jumpRequest = 0

    private var sectionJump: Binding<WheelSettingsSection> {
        Binding(get: { section }, set: { section = $0; jumpRequest += 1 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SegmentedControl(items: WheelSettingsSection.allCases, selection: sectionJump, label: \.title)
                Spacer(minLength: 0)
            }
            .padding(T.s3)
            Hairline()
            AnchoredSettingsScroll(sections: WheelSettingsSection.allCases, selection: $section,
                                   scrollRequest: scrollRequest + jumpRequest, content: sectionContent)
        }
        .onAppear { projects.load() }
    }

    @ViewBuilder private func sectionContent(_ section: WheelSettingsSection) -> some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: section.title + countSuffix(for: section))
            if section == .inner {
                Text(L10n.t("Choose which entries appear in the inner ring.")).font(T.small).foregroundStyle(T.muted)
            } else if section == .projects {
                Text(L10n.t("Choose up to six projects to open from the project menu.")).font(T.small).foregroundStyle(T.muted)
            }
            Card {
                switch section {
                case .inner:
                    ForEach(WheelModule.allCases) { module in
                        if module != WheelModule.allCases.first { Hairline() }
                        SettingsRow(label: module.title) {
                            MiniSwitch(isOn: Binding(get: { preferences.modules.contains(module) },
                                                     set: { _ in preferences.toggle(module) }), label: module.title)
                        }
                    }
                case .projects: projectRows
                case .websites: websiteRows
                case .clipboard:
                    let label = L10n.t("Keep the last 10 copied texts in memory")
                    SettingsRow(label: label) {
                        MiniSwitch(isOn: Binding(get: { preferences.recording }, set: preferences.setRecording), label: label)
                    }
                    Hairline()
                    Button(L10n.t("Clear clipboard history")) { preferences.clear() }
                        .buttonStyle(PillButtonStyle(kind: .secondary)).disabled(preferences.clips.isEmpty)
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(T.s2)
                }
            }
        }
    }

    private func countSuffix(for section: WheelSettingsSection) -> String {
        switch section {
        case .projects: "  \(projects.projects.filter { $0.record?.wheelMember == true }.count)/6"
        case .websites: "  \(preferences.websites.count)/6"
        default: ""
        }
    }

    @ViewBuilder private var projectRows: some View {
        SettingsRow(label: L10n.t("Open projects with")) {
            openerSelect(preferences.projectOpener, options: WheelPreferences.projectOpeners,
                         set: preferences.setProjectOpener)
        }
        Hairline()
        if let notice = wheel.notice { message(notice, color: T.red) }
        if projects.projects.isEmpty { message(L10n.t("Select projects in Projects")) }
        if projects.projects.filter({ $0.record?.wheelMember == true }).count > 6 {
            message(L10n.t("First six selected projects appear on the wheel."))
        }
        ForEach(projects.projects) { project in
            if project.id != projects.projects.first?.id { Hairline() }
            SettingsRow(label: project.name) {
                HStack(spacing: T.s1) {
                    if project.record?.wheelMember == true, let rank = preferences.rank(of: project.path) {
                        Text("#\(rank + 1)")
                            .font(T.micro).foregroundStyle(T.muted).monospacedDigit()
                        IconButton(symbol: "chevron.up", label: L10n.t("Move earlier"), tint: T.muted) {
                            preferences.moveProject(project.path, by: -1)
                        }
                        .disabled(rank == 0 || projects.isWorking)
                        IconButton(symbol: "chevron.down", label: L10n.t("Move later"), tint: T.muted) {
                            preferences.moveProject(project.path, by: 1)
                        }
                        .disabled(rank == preferences.projectOrder.count - 1 || projects.isWorking)
                    }
                    MiniSwitch(isOn: Binding(get: { project.record?.wheelMember == true },
                                             set: { projects.setWheelMember(project, $0) }), label: project.name)
                        .disabled(projects.isWorking)
                }
            }.help(project.path)
        }
        if let error = projects.errorMessage { message(error, color: T.red) }
    }

    @ViewBuilder private var websiteRows: some View {
        SettingsRow(label: L10n.t("Open websites with")) {
            openerSelect(preferences.websiteOpener, options: WheelPreferences.websiteOpeners,
                         set: preferences.setWebsiteOpener)
        }
        Hairline()
        ForEach(preferences.websites, id: \.self) { url in
            HStack {
                Text(url.absoluteString).lineLimit(1).truncationMode(.middle)
                Spacer()
                IconButton(symbol: "minus.circle", label: L10n.t("Remove website")) { preferences.removeWebsite(url) }
            }.font(T.body).padding(.horizontal, T.s3).frame(minHeight: T.rowSingle)
            Hairline()
        }
        HStack {
            MiniField(placeholder: "https://example.com", text: $address).onSubmit(addSite)
            Button(L10n.t("Add website"), action: addSite)
                .buttonStyle(PillButtonStyle(kind: .secondary)).disabled(address.isEmpty || preferences.websites.count >= 6)
        }.padding(T.s2)
        if invalidAddress { message(L10n.t("Enter a unique HTTP or HTTPS address (maximum six)."), color: T.red) }
    }

    private func openerSelect(_ current: String, options: [WheelPreferences.AppChoice],
                              set: @escaping (String) -> Void) -> some View {
        let installed = WheelPreferences.installed(options)
        return InlineSelect(items: installed, label: { $0.name }, header: L10n.t("Open with"),
                            selection: Binding(get: { installed.first { $0.id == current } ?? installed[0] },
                                               set: { set($0.id) }))
    }

    private func message(_ text: String, color: Color = T.muted) -> some View {
        Text(text).font(T.small).foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading).padding(T.s2)
    }

    private func addSite() {
        invalidAddress = !preferences.addWebsite(address)
        if !invalidAddress { address = "" }
    }
}
