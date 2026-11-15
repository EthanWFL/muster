import Foundation

/// Serializes library edits and deployments. External paths are changed only by a reviewed plan.
public actor SkillLibrary {
    public nonisolated let root: URL
    private let fm = FileManager.default
    private var manifestBytes: Data?
    /// One file system change. `expected` is the fingerprint the destination must have before the
    /// change runs, so a plan can never overwrite something that arrived after it was reviewed.
    private struct Change: Codable {
        let path: String
        let parent: String
        let expected: String
        let before: SkillDeployment?
        let after: SkillDeployment?
        /// Forward adoption parks the replaced folder here; undo restores it from here.
        let backup: String?
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
        /// Deployment path → the folder an adoption moved aside, kept while that deployment lives.
        /// It outlives the deployment log, because the user's original folder must never be pruned
        /// just because 20 newer transactions pushed the adoption record out of `history`.
        var restores: [String: String]? = nil
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
            var texts = SkillFiles.texts(files)
            // A saved draft shows its own edits, so reopening the editor cannot lose them.
            for (path, text) in draft?.files ?? [:] { texts[path] = text }
            return SkillContent(text: try SkillFiles.document(files).0, files: files.map(\.path),
                directory: directory, draft: draft, texts: texts)
        }
    }

    public func saveDraft(_ id: UUID, baseRevision: String, text: String,
                          files: [String: String] = [:], removed: [String] = []) throws {
        try locked { state in
            guard state.skills.contains(where: { $0.id == id && $0.revision == baseRevision }) else { throw SkillError.changed }
            let draft = SkillDraft(baseRevision: baseRevision, text: text, files: files, removed: removed)
            guard try JSONEncoder().encode(draft).count <= 8 * 1024 * 1024 else { throw SkillError.tooLarge }
            try atomicWrite(JSONEncoder().encode(draft), to: draftURL(id))
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

    public func publish(_ id: UUID, expectedRevision: String, text: String,
                        files: [String: String] = [:], removed: [String] = []) throws -> SkillLibrarySnapshot {
        let document = try SkillDocument(text)
        return try locked { state in
            guard let index = state.skills.firstIndex(where: { $0.id == id }), state.skills[index].revision == expectedRevision else { throw SkillError.changed }
            guard document.name == state.skills[index].name else { throw SkillError.unsafeName }
            for path in removed { try SkillFiles.validateRelativePath(path) }
            for path in files.keys { try SkillFiles.validateRelativePath(path) }
            var next = try verifiedFiles(id, expectedRevision)
            // Overwritten, removed and edited paths all drop the published copy first; otherwise the
            // same relative path would appear twice and the revision digest could never match.
            next.removeAll { $0.path == "SKILL.md" || removed.contains($0.path) || files[$0.path] != nil }
            next.append(SkillFiles.File(path: "SKILL.md", data: Data(text.utf8), executable: false))
            let predecessors = try verifiedFiles(id, expectedRevision)
            for (path, body) in files where path != "SKILL.md" {
                let executable = predecessors.first { $0.path == path }?.executable ?? false
                next.append(SkillFiles.File(path: path, data: Data(body.utf8), executable: executable))
            }
            try revise(&state.skills[index], files: next, source: state.skills[index].source)
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

    /// Removing a library entry must not silently unbind Agents, so it stops at an active deployment.
    public func remove(_ id: UUID, expectedRevision: String) throws -> SkillLibrarySnapshot {
        try locked { state in
            guard let index = state.skills.firstIndex(where: { $0.id == id }), state.skills[index].revision == expectedRevision
            else { throw SkillError.changed }
            guard !state.deployments.contains(where: { $0.skillID == id }) else { throw SkillError.deployed }
            state.skills.remove(at: index)
            // Undo can only rebuild things that still exist, so history mentioning this skill in
            // either direction is dropped rather than left to fail on the next restore attempt.
            state.history.removeAll { transaction in
                transaction.changes.contains { $0.after?.skillID == id || $0.before?.skillID == id }
            }
            try save(&state)
            pruneBackups(state)
            let directory = root.appendingPathComponent("skills/\(id.uuidString)")
            if fm.fileExists(atPath: directory.path) { try? fm.removeItem(at: directory) }
            try? fm.removeItem(at: draftURL(id))
            return snapshot(state)
        }
    }

    /// Renaming rewrites only the frontmatter name and the folder Agents see, so it stops while a
    /// deployment still points at the old name.
    public func rename(_ id: UUID, expectedRevision: String, to name: String) throws -> SkillLibrarySnapshot {
        try SkillDocument.validateName(name)
        return try locked { state in
            guard let index = state.skills.firstIndex(where: { $0.id == id }), state.skills[index].revision == expectedRevision
            else { throw SkillError.changed }
            guard state.skills[index].name != name else { return snapshot(state) }
            guard !state.skills.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame })
            else { throw SkillError.occupied }
            guard !state.deployments.contains(where: { $0.skillID == id }) else { throw SkillError.deployed }
            guard !fm.fileExists(atPath: draftURL(id).path) else { throw SkillError.changed }
            var next = try verifiedFiles(id, expectedRevision)
            let (text, _) = try SkillFiles.document(next)
            let retitled = try SkillDocument.retitled(text, to: name)
            next.removeAll { $0.path == "SKILL.md" }
            next.append(SkillFiles.File(path: "SKILL.md", data: Data(retitled.utf8), executable: false))
            try revise(&state.skills[index], files: next, source: state.skills[index].source)
            state.skills[index].name = name
            try save(&state)
            return snapshot(state)
        }
    }

    /// The source a user can refresh from, or an explanation for why this skill cannot be refreshed.
    public func updateSource(_ id: UUID) throws -> SkillSource {
        try locked { state in
            guard let skill = state.skills.first(where: { $0.id == id }) else { throw SkillError.missing }
            guard skill.source.kind != .created else { throw SkillError.noSource }
            if skill.source.kind == .local {
                let location = URL(fileURLWithPath: skill.source.location).standardizedFileURL
                // After deployment the imported folder is replaced by Muster's own link or copy.
                // Rescanning it would read the library back to itself and always claim "up to date".
                if state.deployments.contains(where: { entryIdentity($0.path) == entryIdentity(location.path) })
                    || !fm.fileExists(atPath: location.path) {
                    throw SkillError.sourceIsDeployment
                }
                return skill.source
            }
            return skill.source
        }
    }

    public func plan(_ id: UUID, desired: [String: SkillInstallMode], targets: [SkillTarget],
                     targetIDs: Set<String>? = nil, adopting: Set<String> = []) throws -> SkillPlan {
        try locked { state in
            let planID = UUID()
            let items = try planItems(skillID: id, desired: desired, targets: targets, targetIDs: targetIDs,
                adopting: adopting, planID: planID, state: state)
            return finish(items: items, planID: planID, state: state)
        }
    }

    /// One reviewed plan can enable several skills for the same Agents, so a library-wide rollout
    /// is a single confirmation instead of one dialog per skill.
    public func planBatch(_ ids: [UUID], mode: [String: SkillInstallMode], targets: [SkillTarget],
                          targetIDs: Set<String>, adopting: Set<String> = []) throws -> SkillPlan {
        try locked { state in
            let planID = UUID()
            var items: [SkillPlanItem] = []
            for id in ids {
                items += try planItems(skillID: id, desired: mode, targets: targets, targetIDs: targetIDs,
                    adopting: adopting, planID: planID, state: state)
            }
            return finish(items: items, planID: planID, state: state)
        }
    }

    public func apply(_ plan: SkillPlan) throws -> SkillLibrarySnapshot {
        try locked { state in
            guard plan.canApply, plan.libraryRevision == state.revision else { throw SkillError.changed }
            let changes = plan.items.map { item in
                Change(path: item.path, parent: item.resolvedParent, expected: item.expected,
                    before: item.before, after: item.after, backup: item.backup)
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
                let expected = change.after?.fingerprint ?? "missing"
                return SkillPlanItem(skillID: change.after?.skillID ?? change.before?.skillID ?? UUID(),
                    skillName: change.after?.targetID ?? change.before?.targetID ?? "",
                    targetName: change.after?.targetID ?? change.before?.targetID ?? "", path: change.path,
                    before: change.after, after: change.before, expected: current, resolvedParent: change.parent,
                    conflict: current == expected ? nil : SkillError.changed.rawValue, sharedReaders: [],
                    adoptable: false, adopts: false, backup: change.backup)
            }
            return SkillPlan(id: transaction.id, libraryRevision: state.revision, items: items)
        }
    }

    public func undo(_ plan: SkillPlan) throws -> SkillLibrarySnapshot {
        try locked { state in
            guard plan.canApply, plan.libraryRevision == state.revision, state.history.last?.id == plan.id else { throw SkillError.changed }
            let changes = plan.items.map { Change(path: $0.path, parent: $0.resolvedParent, expected: $0.expected,
                before: $0.before, after: $0.after, backup: $0.backup) }
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

    private func planItems(skillID: UUID, desired: [String: SkillInstallMode], targets: [SkillTarget],
                           targetIDs: Set<String>?, adopting: Set<String>, planID: UUID,
                           state: State) throws -> [SkillPlanItem] {
        guard let skill = state.skills.first(where: { $0.id == skillID }) else { throw SkillError.missing }
        _ = try verifiedFiles(skillID, skill.revision)
        let publishedDirectory = try revisionDirectory(skillID, skill.revision)
        let old = state.deployments.filter { $0.skillID == skillID }
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
                SkillDeployment(skillID: skillID, targetID: targetID, path: path, mode: mode, revision: skill.revision,
                    fingerprint: mode == .symlink ? "link:" + publishedDirectory.path : "tree:" + skill.revision)
            }
            let occupied = before == nil && current != "missing"
            let replaces = occupied && adopting.contains(path) && Self.isSkillEntry(url)
            if before == after && current == after?.fingerprint { continue }
            var conflict: String?
            if let before, current != before.fingerprint { conflict = SkillError.changed.rawValue }
            if occupied && !replaces {
                conflict = Self.isSkillEntry(url)
                    ? SkillError.occupied.rawValue
                    : "This folder is not a skill folder. Move it away, then preview again."
            }
            if targetID == "claude" && ["synced", "anthropic-skills"].contains(skill.name.lowercased()) { conflict = SkillError.unsafeName.rawValue }
            // Switching a deployment off must put back whatever it displaced, so the user's own
            // folder reappears instead of a hole where Muster used to be.
            let restore = after == nil ? adoptedBackup(for: before, in: state) : nil
            items.append(SkillPlanItem(skillID: skillID, skillName: skill.name, targetName: target?.name ?? targetID,
                path: path, before: before, after: after, expected: current,
                resolvedParent: url.deletingLastPathComponent().resolvingSymlinksInPath().path,
                conflict: conflict, sharedReaders: target?.sharedReaders ?? [],
                adoptable: occupied && !replaces && Self.isSkillEntry(url),
                adopts: replaces,
                backup: replaces ? backupPath(planID: planID, targetID: targetID, name: skill.name) : restore))
        }
        return items
    }

    private func finish(items input: [SkillPlanItem], planID: UUID, state: State) -> SkillPlan {
        var items = input
        let aliases = Dictionary(grouping: items, by: { entryIdentity($0.path) })
        items = items.map { item in
            guard (aliases[entryIdentity(item.path)]?.count ?? 0) > 1 else { return item }
            return SkillPlanItem(skillID: item.skillID, skillName: item.skillName, targetName: item.targetName,
                path: item.path, before: item.before, after: item.after, expected: item.expected,
                resolvedParent: item.resolvedParent,
                conflict: "Multiple Agent targets resolve to the same folder. Select just one of these targets.",
                sharedReaders: item.sharedReaders, adoptable: item.adoptable, adopts: item.adopts, backup: item.backup)
        }
        return SkillPlan(id: planID, libraryRevision: state.revision, items: items)
    }

    /// The folder an earlier adoption moved aside for this exact deployment, if it is still on disk.
    private func adoptedBackup(for deployment: SkillDeployment?, in state: State) -> String? {
        guard let deployment else { return nil }
        if let direct = state.restores?[deployment.path], fm.fileExists(atPath: direct) { return direct }
        // Manifests written before `restores` existed only recorded the backup in the log.
        for transaction in state.history.reversed() {
            for change in transaction.changes where change.after?.path == deployment.path && change.after?.skillID == deployment.skillID {
                if let backup = change.backup, fm.fileExists(atPath: backup) { return backup }
            }
        }
        return nil
    }

    private func backupPath(planID: UUID, targetID: String, name: String) -> String {
        root.appendingPathComponent("backups/\(planID.uuidString)/\(targetID)-\(name)").path
    }

    private func execute(_ transaction: Transaction, state: inout State, undo: Bool) throws {
        for change in transaction.changes {
            try check(change)
            if let after = change.after { _ = try verifiedFiles(after.skillID, after.revision) }
            if let backup = change.backup, undo { guard fm.fileExists(atPath: backup) else { throw SkillError.changed } }
        }
        state.pending = transaction
        try persist(state) // Write-ahead record: a crash can only leave changes we can identify.
        do {
            for change in transaction.changes {
                try check(change)
                try perform(change)
            }
            for change in transaction.changes {
                state.deployments.removeAll { $0.path == change.path }
                if let after = change.after { state.deployments.append(after) }
                // A backup next to an install is an adoption; a backup next to a removal is the
                // reverse, and `perform` has already moved that folder back to the destination.
                if let backup = change.backup {
                    if change.after != nil, fm.fileExists(atPath: backup) {
                        state.restores = (state.restores ?? [:]).merging([change.path: backup]) { $1 }
                    } else { state.restores?[change.path] = nil }
                }
            }
            if undo { state.history.removeLast() }
            else { state.history.append(transaction); state.history = Array(state.history.suffix(20)) }
            state.pending = nil
            try save(&state)
            pruneBackups(state)
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
            let current = (try? SkillFiles.fingerprint(URL(fileURLWithPath: change.path))) ?? "unreadable"
            if current == change.expected { continue }
            // Only a destination that matches what this transaction wrote can be rolled back.
            guard current == (change.after?.fingerprint ?? "missing") else { throw SkillError.recovery }
            let inverse = Change(path: change.path, parent: change.parent, expected: current,
                before: change.after, after: change.before, backup: change.backup)
            try perform(inverse)
        }
        state.pending = nil
        try save(&state)
    }

    private func check(_ change: Change) throws {
        let url = URL(fileURLWithPath: change.path)
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == change.parent,
              try SkillFiles.fingerprint(url) == change.expected else { throw SkillError.changed }
    }

    private func perform(_ change: Change) throws {
        let destination = URL(fileURLWithPath: change.path)
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let current = try SkillFiles.fingerprint(destination)
        guard current == change.expected else { throw SkillError.changed }
        if let after = change.after {
            if let backup = change.backup, current != "missing" {
                // Adopting: park the foreign folder first so nothing a user wrote is ever destroyed.
                try SkillFiles.move(destination, to: URL(fileURLWithPath: backup))
                try place(after, at: destination, replacing: false)
            } else {
                try place(after, at: destination, replacing: current != "missing")
            }
        } else {
            if current != "missing" { try SkillFiles.discard(destination) }
            if let backup = change.backup {
                guard fm.fileExists(atPath: backup) else { throw SkillError.changed }
                try SkillFiles.move(URL(fileURLWithPath: backup), to: destination)
            }
        }
    }

    private func place(_ deployment: SkillDeployment, at destination: URL, replacing: Bool) throws {
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".muster-skill-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        let files = try verifiedFiles(deployment.skillID, deployment.revision)
        if deployment.mode == .symlink {
            try fm.createSymbolicLink(atPath: temporary.path, withDestinationPath: revisionDirectory(deployment.skillID, deployment.revision).path)
        } else { try SkillFiles.write(files, to: temporary) }
        // Atomically exchange entries when replacing. The previous one stays at `temporary`
        // until cleanup; the journal can rebuild it from the immutable revision or backup.
        if replacing {
            guard renamex_np(temporary.path, destination.path, UInt32(RENAME_SWAP)) == 0 else { throw POSIXError(.EIO) }
        } else {
            guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw SkillError.changed }
        }
    }

    private func entryIdentity(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }

    /// A folder or link that already contains SKILL.md is a skill; anything else is never replaced.
    private static func isSkillEntry(_ url: URL) -> Bool {
        let fm = FileManager.default
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        if info.st_mode & S_IFMT == S_IFLNK {
            guard let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else { return false }
            let resolved = URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent())
            return fm.fileExists(atPath: resolved.appendingPathComponent("SKILL.md").path)
        }
        return info.st_mode & S_IFMT == S_IFDIR && fm.fileExists(atPath: url.appendingPathComponent("SKILL.md").path)
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

    /// Backups live as long as the deployment that displaced them. Without counting `restores`,
    /// a long-lived adoption would be deleted once its transaction aged out of the log, and the
    /// user's original folder would be gone for good.
    /// Directories are matched by transaction id, because comparing absolute path prefixes breaks
    /// on systems where `/var` is a symlink to `/private/var`.
    private func pruneBackups(_ state: State) {
        let live = Set((state.history.flatMap { $0.changes.compactMap(\.backup) }
            + Array((state.restores ?? [:]).values)).compactMap(transactionID(ofBackup:)))
        let directory = root.appendingPathComponent("backups")
        guard let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for child in children {
            // A restore moves its folder back, leaving an empty transaction directory. Undo does not
            // need it: `perform` recreates the directory when it parks a folder there again.
            let empty = ((try? fm.contentsOfDirectory(atPath: child.path))?.isEmpty ?? false)
            guard !live.contains(child.lastPathComponent) || empty else { continue }
            try? fm.removeItem(at: child)
        }
    }

    /// `backups/<transaction id>/<target>-<name>` — the first component is the owning transaction.
    private func transactionID(ofBackup path: String) -> String? {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard let index = parts.lastIndex(of: "backups"), index + 1 < parts.count else { return nil }
        return parts[index + 1]
    }

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
