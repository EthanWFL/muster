import AppKit
import Combine
import MusterCore

@MainActor
final class ProjectsModel: ObservableObject {
    @Published private(set) var projects: [WorkspaceProject] = []
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published var search = ""
    @Published var recentOnly = true
    @Published var selectedPath: String? {
        didSet { defaults.set(selectedPath, forKey: "MusterSelectedProject") }
    }
    @Published private(set) var searchFocusRequest = 0
    private var snapshot = ProjectSnapshot.empty
    private let store: ProjectStore
    private let library: SessionLibraryModel
    private let defaults: UserDefaults
    private var observation: AnyCancellable?
    private(set) var operationTask: Task<Void, Never>?
    private var didLoad = false

    init(library: SessionLibraryModel, store: ProjectStore = ProjectStore(), defaults: UserDefaults = .standard) {
        self.library = library
        self.store = store
        self.defaults = defaults
        selectedPath = defaults.string(forKey: "MusterSelectedProject")
        observation = library.$snapshot.combineLatest(library.$live, library.$managedAgentIDs).sink { [weak self] catalog, live, ids in
            guard let self else { return }
            self.projects = ProjectWorkspace.projects(records: self.snapshot.records, snapshot: catalog, live: live, agentIDs: ids)
        }
    }

    var visibleProjects: [WorkspaceProject] {
        let words = search.split(whereSeparator: \.isWhitespace)
        return projects.filter { project in
            words.allSatisfy { (project.name + " " + project.path).localizedStandardContains(String($0)) }
        }
    }
    var selected: WorkspaceProject? { projects.first { $0.path == selectedPath } ?? projects.first }

    func focusSearch() { searchFocusRequest += 1 }

    func load(force: Bool = false) {
        guard force || !didLoad else { return }
        perform { [store] in try await store.load() } success: { self.didLoad = true }
    }

    func add(_ path: String) {
        perform { [store] in try await store.add(path) } success: {
            self.selectedPath = ProjectWorkspace.path(path)
            self.search = ""
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L10n.t("Add project")
        panel.prompt = L10n.t("Add project")
        panel.begin { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            Task { @MainActor in self?.add(path) }
        }
    }

    func pin(_ project: WorkspaceProject) {
        perform { [store] in try await store.pin(project.path, !project.isPinned) }
    }

    func rename(_ project: WorkspaceProject, _ name: String) {
        perform { [store] in try await store.rename(project.path, name) }
    }

    func remove(_ project: WorkspaceProject) {
        perform { [store] in try await store.hide(project.path) } success: {
            if self.selectedPath == project.path { self.selectedPath = self.projects.first?.path }
        }
    }

    private func perform(_ operation: @escaping () async throws -> ProjectSnapshot, success: @escaping () -> Void = {}) {
        guard !isWorking else { return }
        isWorking = true
        operationTask = Task {
            defer { isWorking = false; operationTask = nil }
            do {
                let value = try await operation()
                if value.revision >= snapshot.revision {
                    snapshot = value
                    projects = ProjectWorkspace.projects(records: value.records, snapshot: library.snapshot, live: library.live, agentIDs: library.managedAgentIDs)
                }
                errorMessage = nil
                success()
            } catch { errorMessage = L10n.t(error.localizedDescription) }
        }
    }
}
