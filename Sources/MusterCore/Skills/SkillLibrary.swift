import Foundation

/// Serializes library edits and deployments. External paths are changed only by a reviewed plan.
public actor SkillLibrary {
    public nonisolated let root: URL
    private let fm = FileManager.default
    private var manifestBytes: Data?
    private struct Change: Codable {
        let path: String
        let parent: String
        let before: SkillDeployment?
        let after: SkillDeployment?
    }
    private struct Transaction: Codable {
        let id: UUID
        let changes: [Change]
    }
    private struct State: Codable {
        var schema = 1
        var revision: UInt64 = 0
        var skills: [SkillRecord] = []
        var deployments: [SkillDeployment] = []
        var history: [Transaction] = []
        var pending: Transaction?
    }

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Muster/library")) { self.root = root }

    public func load() throws -> SkillLibrarySnapshot { try locked { snapshot($0) } }

    public func content(_ id: UUID) throws -> SkillContent {
        try locked { state in
            guard let record = state.skills.first(where: { $0.id == id }) else { throw SkillError.missing }
            let directory = try revisionDirectory(record.id, record.revision)
            let files = try verifiedFiles(record.id, record.revision)
            let draft = try? JSONDecoder().decode(SkillDraft.self, from: Data(contentsOf: draftURL(id)))
            return SkillContent(text: try SkillFiles.document(files).0, files: files.map(\.path), directory: directory, draft: draft)
        }
    }

    public func saveDraft(_ id: UUID, baseRevision: String, text: String) throws {
        try locked { state in
            guard state.skills.contains(where: { $0.id == id && $0.revision == baseRevision }) else { throw SkillError.changed }
            guard text.utf8.count <= 1_048_576 else { throw SkillError.tooLarge }
            try atomicWrite(JSONEncoder().encode(SkillDraft(baseRevision: baseRevision, text: text)), to: draftURL(id))
        }
    }

    public func discardDraft(_ id: UUID) throws {
        try locked { _ in if fm.fileExists(atPath: draftURL(id).path) { try fm.removeItem(at: draftURL(id)) } }
    }

    public func importSkill(_ candidate: SkillCandidate) throws -> SkillLibrarySnapshot {
        let files = try SkillFiles.read(candidate.directory)
        guard SkillFiles.hash(files) == candidate.digest else { throw SkillError.changed }
        return try locked { state in
            if state.skills.contains(where: {
                $0.name == candidate.name && $0.revision == candidate.digest && $0.source.kind == candidate.source.kind
                    && $0.source.location == candidate.source.location && $0.source.ref == candidate.source.ref
                    && $0.source.subdirectory == candidate.source.subdirectory
            }) { return snapshot(state) }
            let (_, document) = try SkillFiles.document(files)
            let id = UUID()
            try storeRevision(id, files: files)
            state.skills.append(SkillRecord(id: id, name: document.name, summary: document.summary, license: document.license,
                revision: candidate.digest, revisions: [SkillRevision(id: candidate.digest, date: Date(), source: candidate.source)], source: candidate.source))
            try save(&state)
            return snapshot(state)
        }
    }

    public func create(name: String, description: String) throws -> SkillLibrarySnapshot {
        let text = try SkillDocument.template(name: name, description: description)
        return try locked { state in
            guard !state.skills.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw SkillError.occupied }
            let id = UUID(), source = SkillSource(kind: .created)
            let files = [SkillFiles.File(path: "SKILL.md", data: Data(text.utf8), executable: false)]
            let digest = try storeRevision(id, files: files)
            state.skills.append(SkillRecord(id: id, name: name, summary: description, revision: digest,
                revisions: [SkillRevision(id: digest, date: Date(), source: source)], source: source))
            try save(&state)
            return snapshot(state)
        }
    }

    public func publish(_ id: UUID, expectedRevision: String, text: String) throws -> SkillLibrarySnapshot {
        let document = try SkillDocument(text)
        return try locked { state in
            guard let index = state.skills.firstIndex(where: { $0.id == id }), state.skills[index].revision == expectedRevision else { throw SkillError.changed }
            guard document.name == state.skills[index].name else { throw SkillError.unsafeName }
            var files = try verifiedFiles(id, expectedRevision)
            files.removeAll { $0.path == "SKILL.md" }
            files.append(SkillFiles.File(path: "SKILL.md", data: Data(text.utf8), executable: false))
            try revise(&state.skills[index], files: files, source: state.skills[index].source)
            try save(&state)
            try? fm.removeItem(at: draftURL(id))
            return snapshot(state)
        }
    }

    public func update(_ id: UUID, expectedRevision: String, from candidate: SkillCandidate) throws -> SkillLibrarySnapshot {
        let files = try SkillFiles.read(candidate.directory)
        guard SkillFiles.hash(files) == candidate.digest else { throw SkillError.changed }
        return try locked { state in
            guard let index = state.skills.firstIndex(where: { $0.id == id }), state.skills[index].revision == expectedRevision else { throw SkillError.changed }
            guard candidate.name == state.skills[index].name else { throw SkillError.unsafeName }
            guard !fm.fileExists(atPath: draftURL(id).path) else { throw SkillError.changed }
            try revise(&state.skills[index], files: files, source: candidate.source)
            try save(&state)
            return snapshot(state)
        }
    }

    public func restoreRevision(_ id: UUID, expectedRevision: String, revision: String) throws -> SkillLibrarySnapshot {
        try locked { state in
            guard let index = state.skills.firstIndex(where: { $0.id == id }), state.skills[index].revision == expectedRevision,
                  let old = state.skills[index].revisions.first(where: { $0.id == revision }),
                  !fm.fileExists(atPath: draftURL(id).path) else { throw SkillError.changed }
            let (_, document) = try SkillFiles.document(verifiedFiles(id, revision))
            state.skills[index].revision = revision
            state.skills[index].summary = document.summary
            state.skills[index].license = document.license
            state.skills[index].source = old.source
            try save(&state)
            return snapshot(state)
        }
    }

    public func plan(_ id: UUID, desired: [String: SkillInstallMode], targets: [SkillTarget], targetIDs: Set<String>? = nil) throws -> SkillPlan {
        try locked { state in
            guard let skill = state.skills.first(where: { $0.id == id }) else { throw SkillError.missing }
            _ = try verifiedFiles(id, skill.revision)
            let publishedDirectory = try revisionDirectory(id, skill.revision)
            let old = state.deployments.filter { $0.skillID == id }
            var items: [SkillPlanItem] = []
            for targetID in Set(desired.keys).union(old.map(\.targetID)).sorted() {
                guard targetIDs?.contains(targetID) ?? true else { continue }
                let before = old.first { $0.targetID == targetID }
                let target = targets.first { $0.id == targetID }
                let mode = desired[targetID]
                if mode != nil, target?.directory.hasPrefix("/") != true { throw SkillError.invalidPath }
                guard let path = mode == nil ? before?.path : target.map({ URL(fileURLWithPath: $0.directory).appendingPathComponent(skill.name).path }), path.hasPrefix("/") else { throw SkillError.invalidPath }
                if let before, before.path != path { throw SkillError.changed }
                let url = URL(fileURLWithPath: path)
                let current = (try? SkillFiles.fingerprint(url)) ?? "unreadable"
                let after = mode.map { mode in
                    SkillDeployment(skillID: id, targetID: targetID, path: path, mode: mode, revision: skill.revision,
                        fingerprint: mode == .symlink ? "link:" + publishedDirectory.path : "tree:" + skill.revision)
                }
                if before == after && current == after?.fingerprint { continue }
                var conflict: String?
                if let before, current != before.fingerprint { conflict = SkillError.changed.rawValue }
                if before == nil && current != "missing" { conflict = SkillError.occupied.rawValue }
                if targetID == "claude" && ["synced", "anthropic-skills"].contains(skill.name.lowercased()) { conflict = SkillError.unsafeName.rawValue }
                items.append(SkillPlanItem(targetName: target?.name ?? targetID, path: path, before: before, after: after,
                    expected: current, resolvedParent: url.deletingLastPathComponent().resolvingSymlinksInPath().path,
                    conflict: conflict, sharedReaders: target?.sharedReaders ?? []))
            }
            let aliases = Dictionary(grouping: items, by: { entryIdentity($0.path) })
            items = items.map { item in
                guard (aliases[entryIdentity(item.path)]?.count ?? 0) > 1 else { return item }
                return SkillPlanItem(targetName: item.targetName, path: item.path, before: item.before, after: item.after,
                    expected: item.expected, resolvedParent: item.resolvedParent,
                    conflict: "Multiple Agent targets resolve to the same folder. Select just one of these targets.", sharedReaders: item.sharedReaders)
            }
            return SkillPlan(id: UUID(), libraryRevision: state.revision, items: items)
        }
    }

    public func apply(_ plan: SkillPlan) throws -> SkillLibrarySnapshot {
        try locked { state in
            guard plan.canApply, plan.libraryRevision == state.revision else { throw SkillError.changed }
            let changes = plan.items.map { Change(path: $0.path, parent: $0.resolvedParent, before: $0.before, after: $0.after) }
            for item in plan.items {
                guard try SkillFiles.fingerprint(URL(fileURLWithPath: item.path)) == item.expected else { throw SkillError.changed }
            }
            try execute(Transaction(id: plan.id, changes: changes), state: &state, undo: false)
            return snapshot(state)
        }
    }

    public func undoPreview() throws -> SkillPlan {
        try locked { state in
            guard let transaction = state.history.last else { throw SkillError.missing }
            let items = transaction.changes.reversed().map { change in
                let current = (try? SkillFiles.fingerprint(URL(fileURLWithPath: change.path))) ?? "unreadable"
                return SkillPlanItem(targetName: change.after?.targetID ?? change.before?.targetID ?? "", path: change.path,
                    before: change.after, after: change.before, expected: current, resolvedParent: change.parent,
                    conflict: current == (change.after?.fingerprint ?? "missing") ? nil : SkillError.changed.rawValue, sharedReaders: [])
            }
            return SkillPlan(id: transaction.id, libraryRevision: state.revision, items: items)
        }
    }

    public func undo(_ plan: SkillPlan) throws -> SkillLibrarySnapshot {
        try locked { state in
            guard plan.canApply, plan.libraryRevision == state.revision, state.history.last?.id == plan.id else { throw SkillError.changed }
            let changes = plan.items.map { Change(path: $0.path, parent: $0.resolvedParent, before: $0.before, after: $0.after) }
            try execute(Transaction(id: UUID(), changes: changes), state: &state, undo: true)
            return snapshot(state)
        }
    }

    public func discover(targets: [SkillTarget]) throws -> [SkillDiscovery] {
        try locked { state in
            var found: [String: SkillDiscovery] = [:]
            for target in targets {
                for directory in Set([target.directory] + target.discoveryDirectories) {
                    guard let entries = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil) else { continue }
                    for entry in entries.sorted(by: { $0.path < $1.path }).prefix(2_000) where !entry.lastPathComponent.hasPrefix(".") {
                        let file = entry.appendingPathComponent("SKILL.md")
                        guard fm.fileExists(atPath: file.path) else { continue }
                        if var existing = found[entry.path] {
                            existing.readers = Array(Set(existing.readers + [target.id])).sorted()
                            found[entry.path] = existing
                            continue
                        }
                        let attrs = try? fm.attributesOfItem(atPath: file.path)
                        let size = (attrs?[.size] as? NSNumber)?.intValue ?? Int.max
                        let document = size <= 1_048_576 && attrs?[.type] as? FileAttributeType == .typeRegular
                            ? (try? SkillDocument(String(contentsOf: file, encoding: .utf8))) : nil
                        found[entry.path] = SkillDiscovery(path: entry.path, name: document?.name ?? entry.lastPathComponent,
                            summary: document?.summary ?? "", readers: [target.id],
                            isShared: targets.contains { $0.directory == directory && !$0.sharedReaders.isEmpty },
                            managed: state.deployments.contains { entryIdentity($0.path) == entryIdentity(entry.path) },
                            issue: document == nil ? SkillError.invalidDocument.rawValue : document?.warning)
                    }
                }
            }
            return found.values.sorted { $0.path < $1.path }
        }
    }

    private func execute(_ transaction: Transaction, state: inout State, undo: Bool) throws {
        for change in transaction.changes {
            try check(change, expected: change.before?.fingerprint ?? "missing")
            if let after = change.after { _ = try verifiedFiles(after.skillID, after.revision) }
        }
        state.pending = transaction
        try persist(state) // Write-ahead record: a crash can only leave changes we can identify.
        do {
            for change in transaction.changes {
                try check(change, expected: change.before?.fingerprint ?? "missing")
                try install(change.after, at: change.path, replacing: change.before?.fingerprint ?? "missing")
            }
            for change in transaction.changes {
                state.deployments.removeAll { $0.path == change.path }
                if let after = change.after { state.deployments.append(after) }
            }
            if undo { state.history.removeLast() }
            else { state.history.append(transaction); state.history = Array(state.history.suffix(20)) }
            state.pending = nil
            try save(&state)
        } catch {
            // Reload the journal's pre-operation metadata if the final manifest write failed.
            var original = try JSONDecoder().decode(State.self, from: Data(contentsOf: root.appendingPathComponent("skills.json")))
            do { try recover(&original) }
            catch { throw SkillError.recovery }
            state = original
            throw error
        }
    }

    private func recover(_ state: inout State) throws {
        guard let pending = state.pending else { return }
        for change in pending.changes.reversed() {
            let current = try SkillFiles.fingerprint(URL(fileURLWithPath: change.path))
            if current == (change.before?.fingerprint ?? "missing") { continue }
            guard current == (change.after?.fingerprint ?? "missing") else { throw SkillError.recovery }
            try check(change, expected: current)
            try install(change.before, at: change.path, replacing: current)
        }
        state.pending = nil
        try save(&state)
    }

    private func check(_ change: Change, expected: String) throws {
        let url = URL(fileURLWithPath: change.path)
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == change.parent,
              try SkillFiles.fingerprint(url) == expected else { throw SkillError.changed }
    }

    private func entryIdentity(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }

    private func install(_ deployment: SkillDeployment?, at path: String, replacing expected: String) throws {
        let destination = URL(fileURLWithPath: path), parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".muster-skill-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        if let deployment {
            let files = try verifiedFiles(deployment.skillID, deployment.revision)
            if deployment.mode == .symlink {
                try fm.createSymbolicLink(atPath: temporary.path, withDestinationPath: revisionDirectory(deployment.skillID, deployment.revision).path)
            } else { try SkillFiles.write(files, to: temporary) }
        }
        guard try SkillFiles.fingerprint(destination) == expected else { throw SkillError.changed }
        // Atomically exchange entries when replacing a directory. The previous one remains at
        // temporary until cleanup; the journal can reconstruct it from an immutable revision.
        if deployment != nil && expected != "missing" {
            guard renamex_np(temporary.path, destination.path, UInt32(RENAME_SWAP)) == 0 else { throw POSIXError(.EIO) }
        } else if deployment != nil {
            guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw SkillError.changed }
        } else if expected != "missing" {
            guard renamex_np(destination.path, temporary.path, UInt32(RENAME_EXCL)) == 0 else { throw SkillError.changed }
        }
    }

    private func revise(_ skill: inout SkillRecord, files: [SkillFiles.File], source: SkillSource) throws {
        let (_, document) = try SkillFiles.document(files)
        let digest = try storeRevision(skill.id, files: files)
        if !skill.revisions.contains(where: { $0.id == digest }) { skill.revisions.append(SkillRevision(id: digest, date: Date(), source: source)) }
        skill.revision = digest; skill.summary = document.summary; skill.license = document.license; skill.source = source
    }

    @discardableResult private func storeRevision(_ id: UUID, files: [SkillFiles.File]) throws -> String {
        let digest = SkillFiles.hash(files)
        let (_, document) = try SkillFiles.document(files)
        let destination = root.appendingPathComponent("skills/\(id.uuidString)/revisions/\(digest)/\(document.name)")
        if fm.fileExists(atPath: destination.path) { _ = try verifiedFiles(id, digest); return digest }
        let temporary = root.appendingPathComponent("staging/" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        try SkillFiles.write(files, to: temporary)
        guard SkillFiles.hash(try SkillFiles.read(temporary)) == digest else { throw SkillError.changed }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: temporary, to: destination)
        return digest
    }

    private func verifiedFiles(_ id: UUID, _ revision: String) throws -> [SkillFiles.File] {
        guard revision.count == 64, revision.allSatisfy(\.isHexDigit) else { throw SkillError.corrupt }
        let files = try SkillFiles.read(revisionDirectory(id, revision))
        guard SkillFiles.hash(files) == revision else { throw SkillError.changed }
        return files
    }
    private func revisionDirectory(_ id: UUID, _ revision: String) throws -> URL {
        guard revision.count == 64, revision.allSatisfy(\.isHexDigit) else { throw SkillError.corrupt }
        let version = root.appendingPathComponent("skills/\(id.uuidString)/revisions/\(revision)")
        let children = try fm.contentsOfDirectory(at: version, includingPropertiesForKeys: nil)
        guard children.count == 1, let directory = children.first else { throw SkillError.corrupt }
        try SkillDocument.validateName(directory.lastPathComponent)
        return directory
    }
    private func draftURL(_ id: UUID) -> URL { root.appendingPathComponent("drafts/\(id.uuidString).json") }
    private func snapshot(_ state: State) -> SkillLibrarySnapshot {
        SkillLibrarySnapshot(revision: state.revision, skills: state.skills.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            deployments: state.deployments, canUndo: !state.history.isEmpty)
    }
    private func save(_ state: inout State) throws { state.revision += 1; try persist(state) }
    private func persist(_ state: State) throws {
        let url = root.appendingPathComponent("skills.json")
        let current = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == manifestBytes else { throw SkillError.changed }
        let data = try JSONEncoder().encode(state)
        try atomicWrite(data, to: url)
        manifestBytes = data
    }
    private func atomicWrite(_ data: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".muster-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
              Darwin.rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    private func locked<T>(_ operation: (inout State) throws -> T) throws -> T {
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(root.appendingPathComponent("library.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        let url = root.appendingPathComponent("skills.json")
        manifestBytes = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        defer { manifestBytes = nil }
        var state: State
        do {
            state = try manifestBytes.map { try JSONDecoder().decode(State.self, from: $0) } ?? State()
            guard state.schema == 1, state.revision < UInt64.max,
                  Set(state.skills.map(\.id)).count == state.skills.count,
                  Set(state.deployments.map(\.path)).count == state.deployments.count else { throw SkillError.corrupt }
            for record in state.skills { try SkillDocument.validateName(record.name) }
        } catch { throw SkillError.corrupt }
        try recover(&state)
        return try operation(&state)
    }
}
