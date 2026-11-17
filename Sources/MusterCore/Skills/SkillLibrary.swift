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
        var sourceID: UUID? = nil
        var sourceReference: String? = nil
    }
    private struct Transaction: Codable {
        let id: UUID
        let changes: [Change]
        var updatedSources: [SkillRecord]? = nil
    }
    private struct LocalTransition: Codable {
        let entry: SkillSuspension
        let restoring: Bool
    }
    private struct State: Codable {
        var schema = 2
        var revision: UInt64 = 0
        var skills: [SkillRecord] = []
        var deployments: [SkillDeployment] = []
        var history: [Transaction] = []
        var pending: Transaction?
        /// Deployment path → the folder an adoption moved aside, kept while that deployment lives.
        /// It outlives the deployment log, because the user's original folder must never be pruned
        /// just because 20 newer transactions pushed the adoption record out of `history`.
        var restores: [String: String]? = nil
        /// Original folders retained after ownership is relinquished; never auto-pruned.
        var retainedBackups: [String]? = nil
        var suspended: [SkillSuspension]? = nil
        var pendingLocal: LocalTransition? = nil
        var migratedAgents: Set<String>? = nil
    }

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Muster/library")) { self.root = root }

    public func load() throws -> SkillLibrarySnapshot {
        try locked { state in
            try refreshSources(&state)
            return snapshot(state)
        }
    }

    /// Only forget stale metadata after rechecking the exact entry shown to the user.
    /// Foreign files and displaced originals are never removed or restored by this operation.
    public func releaseDeployment(_ inspection: SkillDeploymentInspection) throws -> SkillLibrarySnapshot {
        try locked { state in
            guard inspection.status == .missing || inspection.status == .changed,
                  let deployment = state.deployments.first(where: { $0.id == inspection.id }),
                  deployment == inspection.deployment,
                  inspect(deployment) == inspection else { throw SkillError.changed }
            let invalidated = state.history.filter { $0.changes.contains { $0.path == deployment.path } }
            var retained = Set(state.retainedBackups ?? [])
            retained.formUnion(invalidated.flatMap { $0.changes.compactMap(\.backup) })
            if let backup = state.restores?[deployment.path] { retained.insert(backup) }
            state.retainedBackups = retained.sorted()
            state.restores?[deployment.path] = nil
            state.history.removeAll { transaction in invalidated.contains { $0.id == transaction.id } }
            state.deployments.removeAll { $0.id == deployment.id }
            try save(&state)
            return snapshot(state)
        }
    }

    public func content(_ id: UUID) throws -> SkillContent {
        try locked { state in
            guard let record = state.skills.first(where: { $0.id == id }) else { throw SkillError.missing }
            let directory = try activeDirectory(record)
            let files = try activeFiles(record)
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
            if candidate.source.kind == .local,
               let existing = state.skills.first(where: { $0.sourcePath == entryIdentity(candidate.source.location) }) {
                guard existing.name == candidate.name else { throw SkillError.occupied }
                try refreshSources(&state)
                return snapshot(state)
            }
            if candidate.source.kind == .git,
               let index = state.skills.firstIndex(where: {
                   $0.source.kind == .git && $0.source.location == candidate.source.location &&
                       $0.source.ref == candidate.source.ref && $0.source.subdirectory == candidate.source.subdirectory && $0.name == candidate.name
               }) {
                if state.skills[index].revision != candidate.digest {
                    guard !fm.fileExists(atPath: draftURL(state.skills[index].id).path) else { throw SkillError.changed }
                    var updated = state.skills[index]
                    try revise(&updated, files: files, source: candidate.source)
                    try writeSource(updated, replacing: state.skills[index], state: &state)
                }
                return snapshot(state)
            }
            if state.skills.contains(where: {
                $0.name == candidate.name && $0.revision == candidate.digest && $0.source.kind == candidate.source.kind
                    && $0.source.location == candidate.source.location && $0.source.ref == candidate.source.ref
                    && $0.source.subdirectory == candidate.source.subdirectory
            }) { return snapshot(state) }
            let (_, document) = try SkillFiles.document(files)
            let id = UUID()
            try storeRevision(id, files: files)
            var skill = SkillRecord(id: id, name: document.name, summary: document.summary, license: document.license,
                revision: candidate.digest, revisions: [SkillRevision(id: candidate.digest, date: Date(), source: candidate.source)], source: candidate.source)
            try initializeSource(&skill, files: files, state: state)
            guard skill.revision == candidate.digest else { throw SkillError.changed }
            state.skills.append(skill)
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
            var skill = SkillRecord(id: id, name: name, summary: description, revision: digest,
                revisions: [SkillRevision(id: digest, date: Date(), source: source)], source: source)
            try initializeSource(&skill, files: files, state: state)
            state.skills.append(skill)
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
            var next = try activeFiles(state.skills[index])
            // Overwritten, removed and edited paths all drop the published copy first; otherwise the
            // same relative path would appear twice and the revision digest could never match.
            next.removeAll { $0.path == "SKILL.md" || removed.contains($0.path) || files[$0.path] != nil }
            next.append(SkillFiles.File(path: "SKILL.md", data: Data(text.utf8), executable: false))
            let predecessors = try verifiedFiles(id, expectedRevision)
            for (path, body) in files where path != "SKILL.md" {
                let executable = predecessors.first { $0.path == path }?.executable ?? false
                next.append(SkillFiles.File(path: path, data: Data(body.utf8), executable: executable))
            }
            var updated = state.skills[index]
            try revise(&updated, files: next, source: updated.source)
            try writeSource(updated, replacing: state.skills[index], state: &state)
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
            var updated = state.skills[index]
            try revise(&updated, files: files, source: candidate.source)
            if updated.sourcePath.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == candidate.directory.resolvingSymlinksInPath().path {
                state.skills[index] = updated
                try save(&state)
            } else {
                try writeSource(updated, replacing: state.skills[index], state: &state)
            }
            return snapshot(state)
        }
    }

    public func restoreRevision(_ id: UUID, expectedRevision: String, revision: String) throws -> SkillLibrarySnapshot {
        try locked { state in
            guard let index = state.skills.firstIndex(where: { $0.id == id }), state.skills[index].revision == expectedRevision,
                  let old = state.skills[index].revisions.first(where: { $0.id == revision }),
                  !fm.fileExists(atPath: draftURL(id).path) else { throw SkillError.changed }
            let (_, document) = try SkillFiles.document(verifiedFiles(id, revision))
            var updated = state.skills[index]
            updated.revision = revision
            updated.summary = document.summary
            updated.license = document.license
            // Restore content, not the stable source address.
            updated.source.commit = old.source.commit
            try writeSource(updated, replacing: state.skills[index], state: &state)
            return snapshot(state)
        }
    }

    /// Removing a library entry must not silently unbind Agents, so it stops at an active deployment.
    public func remove(_ id: UUID, expectedRevision: String) throws -> SkillLibrarySnapshot {
        try locked { state in
            guard let index = state.skills.firstIndex(where: { $0.id == id }), state.skills[index].revision == expectedRevision
            else { throw SkillError.changed }
            guard !state.deployments.contains(where: { $0.skillID == id }),
                  state.suspended?.contains(where: { $0.deployment?.skillID == id }) != true else { throw SkillError.deployed }
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
            guard !state.deployments.contains(where: { $0.skillID == id }),
                  state.suspended?.contains(where: { $0.deployment?.skillID == id }) != true else { throw SkillError.deployed }
            guard !fm.fileExists(atPath: draftURL(id).path) else { throw SkillError.changed }
            var next = try activeFiles(state.skills[index])
            let (text, _) = try SkillFiles.document(next)
            let retitled = try SkillDocument.retitled(text, to: name)
            next.removeAll { $0.path == "SKILL.md" }
            next.append(SkillFiles.File(path: "SKILL.md", data: Data(retitled.utf8), executable: false))
            var updated = state.skills[index]
            try revise(&updated, files: next, source: updated.source)
            updated.name = name
            try writeSource(updated, replacing: state.skills[index], state: &state)
            return snapshot(state)
        }
    }

    /// The source a user can refresh from, or an explanation for why this skill cannot be refreshed.
    public func updateSource(_ id: UUID) throws -> SkillSource {
        try locked { state in
            guard let skill = state.skills.first(where: { $0.id == id }) else { throw SkillError.missing }
            guard skill.source.kind != .created else { throw SkillError.noSource }
            if skill.source.kind == .local {
                if let sourcePath = skill.sourcePath {
                    let managed = root.appendingPathComponent("sources").resolvingSymlinksInPath().path + "/"
                    guard !sourcePath.hasPrefix(managed) else { throw SkillError.sourceIsDeployment }
                    _ = try activeDirectory(skill)
                    return SkillSource(kind: .local, location: sourcePath)
                }
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
            try refreshSources(&state)
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
            try refreshSources(&state)
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
        try locked { state in try discoveries(targets: targets, state: state) }
    }

    private func discoveries(targets: [SkillTarget], state: State) throws -> [SkillDiscovery] {
        var found: [String: SkillDiscovery] = [:]
        var contents: [String: (SkillDocument, String)] = [:]
        for target in targets {
            for directory in Set([target.directory] + target.discoveryDirectories) {
                guard let entries = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil) else { continue }
                for entry in entries.sorted(by: { $0.path < $1.path }).prefix(2_000) where !entry.lastPathComponent.hasPrefix(".") {
                    guard fm.fileExists(atPath: entry.appendingPathComponent("SKILL.md").path) else { continue }
                    if var existing = found[entry.path] {
                        existing.readers = Array(Set(existing.readers + [target.id])).sorted()
                        found[entry.path] = existing
                        continue
                    }
                    let resolved = entry.resolvingSymlinksInPath()
                    let fingerprint = try? SkillFiles.fingerprint(entry)
                    var issue: String?
                    if contents[resolved.path] == nil {
                        do {
                            let files = try SkillFiles.read(resolved)
                            contents[resolved.path] = (try SkillFiles.document(files).1, SkillFiles.hash(files))
                        } catch { issue = error.localizedDescription }
                    }
                    let content = contents[resolved.path]
                    found[entry.path] = SkillDiscovery(path: entry.path, name: content?.0.name ?? entry.lastPathComponent,
                        summary: content?.0.summary ?? "", readers: [target.id],
                        isShared: targets.contains { $0.directory == directory && !$0.sharedReaders.isEmpty },
                        managed: state.deployments.contains {
                            entryIdentity($0.path) == entryIdentity(entry.path) && inspect($0).status == .active
                        }, issue: issue ?? content?.0.warning, fingerprint: fingerprint, digest: content?.1,
                        resolvedPath: resolved.path)
                }
            }
        }
        for entry in state.suspended ?? [] where targets.contains(where: { $0.id == entry.targetID }) {
            // Keep disabled originals visible, even if another tool now occupies their old path.
            let backup = URL(fileURLWithPath: entry.backup)
            let intact = (try? SkillFiles.fingerprint(backup)) == entry.fingerprint
            let item = SkillDiscovery(path: entry.path, name: entry.name, summary: entry.summary,
                readers: [entry.targetID], isShared: false, managed: false,
                issue: intact ? nil : SkillError.changed.rawValue, fingerprint: entry.fingerprint,
                digest: intact ? entry.digest : nil, resolvedPath: entry.resolvedSource, suspendedID: entry.id)
            found["suspended:" + entry.id.uuidString] = item
        }
        return found.values.sorted { $0.path < $1.path }
    }

    /// Snapshot the complete discovered bundle before deploying it anywhere else.
    public func importDiscovered(_ discovery: SkillDiscovery) throws -> SkillRecord {
        let candidate: SkillCandidate = try locked { state in
            let directory: URL
            if let id = discovery.suspendedID {
                guard let saved = state.suspended?.first(where: { $0.id == id }),
                      try SkillFiles.fingerprint(URL(fileURLWithPath: saved.backup)) == saved.fingerprint else { throw SkillError.changed }
                directory = saved.fingerprint.hasPrefix("link:")
                    ? URL(fileURLWithPath: saved.resolvedSource) : URL(fileURLWithPath: saved.backup)
            } else {
                let url = URL(fileURLWithPath: discovery.path)
                guard try SkillFiles.fingerprint(url) == discovery.fingerprint,
                      url.resolvingSymlinksInPath().path == discovery.resolvedPath else { throw SkillError.changed }
                directory = url.resolvingSymlinksInPath()
            }
            let files = try SkillFiles.read(directory)
            let (_, document) = try SkillFiles.document(files)
            let digest = SkillFiles.hash(files)
            guard discovery.digest == digest, discovery.name == document.name else { throw SkillError.changed }
            return SkillCandidate(directory: directory, name: document.name, summary: document.summary,
                license: document.license, warning: document.warning, digest: digest, files: files.map(\.path),
                source: SkillSource(kind: .local, location: discovery.path))
        }
        let existing = try locked { state -> SkillRecord? in
            try refreshSources(&state)
            if let deployment = state.deployments.first(where: { entryIdentity($0.path) == entryIdentity(discovery.path) }) {
                guard inspect(deployment).status == .active,
                      let skill = state.skills.first(where: { $0.id == deployment.skillID }),
                      skill.name == candidate.name, skill.revision == candidate.digest else { throw SkillError.changed }
                if let source = skill.sourcePath {
                    guard URL(fileURLWithPath: source).resolvingSymlinksInPath().path == candidate.directory.path else { throw SkillError.changed }
                }
                return skill
            }
            return state.skills.first {
                $0.sourcePath == entryIdentity(discovery.path) && $0.name == candidate.name
            }
        }
        if let existing { return existing }
        guard discovery.suspendedID == nil else { throw SkillError.sourceUnavailable }
        let snapshot = try importSkill(candidate)
        guard let record = snapshot.skills.first(where: {
            $0.name == candidate.name && $0.revision == candidate.digest &&
                ($0.sourcePath == entryIdentity(discovery.path) || $0.source.location == discovery.path)
        }) else { throw SkillError.missing }
        return record
    }

    public func suspendDiscovered(_ discovery: SkillDiscovery, targetID: String, targets: [SkillTarget]) throws -> SkillLibrarySnapshot {
        try locked { state in
            guard targets.contains(where: { $0.id == targetID }) else { throw SkillError.outsideScope }
            let entries = try discoveries(targets: targets, state: state)
            guard let reviewed = entries.first(where: { $0.id == discovery.id }),
                  reviewed.fingerprint == discovery.fingerprint, reviewed.digest == discovery.digest,
                  reviewed.resolvedPath == discovery.resolvedPath else { throw SkillError.changed }
            let matches = entries.filter { $0.suspendedID == nil && $0.isSameSkill(as: discovery) && $0.readers.contains(targetID) }
            guard matches.count == 1, let entry = matches.first, let fingerprint = entry.fingerprint,
                  let digest = entry.digest, let resolved = entry.resolvedPath else { throw SkillError.localSkillShared }
            guard !entry.isShared, entry.readers == [targetID], !entries.contains(where: {
                $0.suspendedID == nil && $0.readers.contains(where: { $0 != targetID }) &&
                    (entryIdentity($0.path) == entryIdentity(entry.path) ||
                     (fingerprint.hasPrefix("tree:") && $0.resolvedPath == resolved))
            }) else { throw SkillError.localSkillShared }
            guard !state.skills.contains(where: {
                $0.sourcePath == entryIdentity(entry.path) ||
                    (fingerprint.hasPrefix("tree:") && $0.sourcePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == resolved)
            }) else { throw SkillError.sourceCycle }
            guard state.suspended?.contains(where: { $0.path == entry.path }) != true else { throw SkillError.localSkillOccupied }
            let id = UUID()
            let backup = root.appendingPathComponent("disabled/\(id.uuidString)/\(URL(fileURLWithPath: entry.path).lastPathComponent)")
            try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let saved = SkillSuspension(id: id, path: entry.path,
                parent: URL(fileURLWithPath: entry.path).deletingLastPathComponent().resolvingSymlinksInPath().path,
                backup: backup.path, backupParent: backup.deletingLastPathComponent().resolvingSymlinksInPath().path,
                fingerprint: fingerprint, targetID: targetID, name: entry.name, summary: entry.summary,
                digest: digest, resolvedSource: resolved,
                deployment: state.deployments.first { $0.path == entry.path && inspect($0).status == .active }, restoreBackup: state.restores?[entry.path])
            guard SkillFiles.hash(try SkillFiles.read(URL(fileURLWithPath: resolved))) == digest else { throw SkillError.changed }
            try transitionLocal(LocalTransition(entry: saved, restoring: false), state: &state)
            return snapshot(state)
        }
    }

    public func restoreDiscovered(_ id: UUID, targetID: String, targets: [SkillTarget]) throws -> SkillLibrarySnapshot {
        try locked { state in
            guard let saved = state.suspended?.first(where: { $0.id == id }), saved.targetID == targetID,
                  let target = targets.first(where: { $0.id == targetID }),
                  ([target.directory] + target.discoveryDirectories).contains(where: {
                      URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == saved.parent
                  }) else { throw SkillError.outsideScope }
            guard !state.deployments.contains(where: { $0.path == saved.path }),
                  try SkillFiles.fingerprint(URL(fileURLWithPath: saved.path)) == "missing" else { throw SkillError.localSkillOccupied }
            try transitionLocal(LocalTransition(entry: saved, restoring: true), state: &state)
            if let before = saved.deployment,
               let skill = state.skills.first(where: { $0.id == before.skillID }),
               let source = skill.sourcePath, before.sourcePath != source || before.mode != .symlink {
                let after = SkillDeployment(skillID: skill.id, targetID: before.targetID, path: before.path, mode: .symlink,
                    revision: skill.revision, fingerprint: "link:" + source, sourcePath: source)
                let change = Change(path: before.path, parent: saved.parent, expected: before.fingerprint,
                    before: before, after: after, backup: nil)
                try execute(Transaction(id: UUID(), changes: [change], updatedSources: []), state: &state, undo: false)
            }
            return snapshot(state)
        }
    }

    private func checkLocalParents(_ entry: SkillSuspension) throws {
        guard URL(fileURLWithPath: entry.path).deletingLastPathComponent().resolvingSymlinksInPath().path == entry.parent,
              URL(fileURLWithPath: entry.backup).deletingLastPathComponent().resolvingSymlinksInPath().path == entry.backupParent,
              entry.backupParent.hasPrefix(root.appendingPathComponent("disabled").resolvingSymlinksInPath().path + "/") else { throw SkillError.changed }
    }

    private func transitionLocal(_ transition: LocalTransition, state: inout State) throws {
        let entry = transition.entry
        try checkLocalParents(entry)
        let from = transition.restoring ? entry.backup : entry.path
        let to = transition.restoring ? entry.path : entry.backup
        guard try SkillFiles.fingerprint(URL(fileURLWithPath: from)) == entry.fingerprint,
              try SkillFiles.fingerprint(URL(fileURLWithPath: to)) == "missing" else { throw SkillError.changed }
        state.pendingLocal = transition
        try persist(state)
        // Atomic no-overwrite rename preserves the exact folder/link. Cross-volume moves fail intact.
        do {
            try checkLocalParents(entry)
            guard try SkillFiles.fingerprint(URL(fileURLWithPath: from)) == entry.fingerprint else { throw SkillError.changed }
            guard renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try recoverLocal(&state)
        } catch {
            try recoverLocal(&state)
            throw error
        }
    }

    private func recoverLocal(_ state: inout State) throws {
        guard let pending = state.pendingLocal else { return }
        let entry = pending.entry
        try checkLocalParents(entry)
        let original = try SkillFiles.fingerprint(URL(fileURLWithPath: entry.path))
        let backup = try SkillFiles.fingerprint(URL(fileURLWithPath: entry.backup))
        let completed = pending.restoring ? (original == entry.fingerprint && backup == "missing")
                                         : (original == "missing" && backup == entry.fingerprint)
        let untouched = pending.restoring ? (original == "missing" && backup == entry.fingerprint)
                                         : (original == entry.fingerprint && backup == "missing")
        guard completed || untouched else { throw SkillError.recovery }
        if completed {
            if pending.restoring {
                state.suspended?.removeAll { $0.id == entry.id }
                if let deployment = entry.deployment { state.deployments.append(deployment) }
                if let restore = entry.restoreBackup { state.restores = (state.restores ?? [:]).merging([entry.path: restore]) { $1 } }
            } else {
                state.suspended = (state.suspended ?? []) + [entry]
                state.deployments.removeAll { $0.path == entry.path }
                let obsolete = state.history.filter { $0.changes.contains { $0.path == entry.path } }
                var retained = Set(state.retainedBackups ?? [])
                retained.formUnion(obsolete.flatMap { $0.changes.compactMap(\.backup) })
                if let restore = state.restores?[entry.path] { retained.insert(restore) }
                state.retainedBackups = retained.sorted()
                state.restores?[entry.path] = nil
                state.history.removeAll { transaction in obsolete.contains { $0.id == transaction.id } }
            }
        }
        state.pendingLocal = nil
        try save(&state)
    }

    private func planItems(skillID: UUID, desired: [String: SkillInstallMode], targets: [SkillTarget],
                           targetIDs: Set<String>?, adopting: Set<String>, planID: UUID,
                           state: State) throws -> [SkillPlanItem] {
        guard let skill = state.skills.first(where: { $0.id == skillID }) else { throw SkillError.missing }
        _ = try verifiedFiles(skillID, skill.revision)
        let publishedDirectory = try activeDirectory(skill)
        _ = try activeFiles(skill)
        let old = state.deployments.filter { $0.skillID == skillID }
        var items: [SkillPlanItem] = []
        for targetID in Set(desired.keys).union(old.map(\.targetID)).sorted() {
            guard targetIDs?.contains(targetID) ?? true else { continue }
            let before = old.first { $0.targetID == targetID }
            let target = targets.first { $0.id == targetID }
            // Copies remain decodable for old journals; every new single-source deployment is a link.
            let mode: SkillInstallMode? = desired[targetID].map { skill.sourcePath == nil ? $0 : .symlink }
            if mode != nil, target?.directory.hasPrefix("/") != true { throw SkillError.invalidPath }
            guard let path = mode == nil ? before?.path : target.map({ URL(fileURLWithPath: $0.directory).appendingPathComponent(skill.name).path }), path.hasPrefix("/") else { throw SkillError.invalidPath }
            if let before, before.path != path { throw SkillError.changed }
            let url = URL(fileURLWithPath: path)
            let current = (try? SkillFiles.fingerprint(url)) ?? "unreadable"
            if let source = skill.sourcePath {
                if entryIdentity(path) == source || entryIdentity(path) == publishedDirectory.path {
                    if mode != nil && before == nil { continue } // The real source already serves this Agent.
                    throw SkillError.sourceCycle
                }
                guard !source.hasPrefix(entryIdentity(path) + "/"),
                      !publishedDirectory.path.hasPrefix(entryIdentity(path) + "/") else { throw SkillError.sourceCycle }
            }
            let after = mode.map { mode in
                SkillDeployment(skillID: skillID, targetID: targetID, path: path, mode: mode, revision: skill.revision,
                    fingerprint: mode == .symlink ? "link:" + (skill.sourcePath ?? publishedDirectory.path) : "tree:" + skill.revision,
                    sourcePath: mode == .symlink ? skill.sourcePath : nil)
            }
            let occupied = before == nil && current != "missing"
            let replaces = occupied && adopting.contains(path) && Self.isSkillEntry(url)
            if before == after && current == after?.fingerprint { continue }
            if let before, let after, before.sourcePath != nil, before.sourcePath == after.sourcePath,
               before.mode == .symlink, after.mode == .symlink, current == after.fingerprint { continue }
            var conflict: String?
            if let before, current != before.fingerprint {
                conflict = current == "missing"
                    ? "This deployment is missing. Use its Agent icon to clear the stale record or redeploy."
                    : "This deployment was changed outside Muster. Use its Agent icon to release management or review redeployment."
            }
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
            for change in transaction.changes where change.sourceID == nil {
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
            for updated in transaction.updatedSources ?? [] {
                guard let index = state.skills.firstIndex(where: { $0.id == updated.id }) else { throw SkillError.missing }
                state.skills[index] = updated
            }
            if undo { state.history.removeLast() }
            else if transaction.updatedSources == nil { state.history.append(transaction); state.history = Array(state.history.suffix(20)) }
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
                before: change.after, after: change.before, backup: change.backup,
                sourceID: change.sourceID, sourceReference: change.sourceReference)
            try check(inverse)
            try perform(inverse)
        }
        state.pending = nil
        try save(&state)
    }

    private func check(_ change: Change) throws {
        let url = URL(fileURLWithPath: change.path)
        if let source = change.sourceReference {
            guard URL(fileURLWithPath: source).resolvingSymlinksInPath().path == change.path else { throw SkillError.changed }
        }
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
                try place(after, at: destination, replacing: current != "missing", preservingSource: change.sourceID != nil)
            }
        } else {
            if current != "missing" { try SkillFiles.discard(destination) }
            if let backup = change.backup {
                guard fm.fileExists(atPath: backup) else { throw SkillError.changed }
                try SkillFiles.move(URL(fileURLWithPath: backup), to: destination)
            }
        }
    }

    private func place(_ deployment: SkillDeployment, at destination: URL, replacing: Bool, preservingSource: Bool = false) throws {
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".muster-skill-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        let files = try verifiedFiles(deployment.skillID, deployment.revision)
        if deployment.mode == .symlink {
            let source = try deployment.sourcePath ?? revisionDirectory(deployment.skillID, deployment.revision).path
            if deployment.sourcePath != nil {
                let directory = URL(fileURLWithPath: source)
                guard entryIdentity(source) == source,
                      (try? SkillFiles.document(SkillFiles.read(directory.resolvingSymlinksInPath())).1.name) == (try SkillFiles.document(files).1.name) else { throw SkillError.sourceUnavailable }
            }
            let resolved = URL(fileURLWithPath: source).resolvingSymlinksInPath().path
            guard entryIdentity(destination.path) != source, entryIdentity(destination.path) != resolved,
                  !source.hasPrefix(entryIdentity(destination.path) + "/"),
                  !resolved.hasPrefix(entryIdentity(destination.path) + "/") else { throw SkillError.sourceCycle }
            try fm.createSymbolicLink(atPath: temporary.path, withDestinationPath: source)
        } else {
            try SkillFiles.write(files, to: temporary)
            if preservingSource, replacing {
                try SkillFiles.preserveExcludedEntries(from: destination, to: temporary)
            }
        }
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

    /// Upgrade recorded, unchanged deployments only. Foreign edits are never overwritten.
    public func migrateToSingleSource(targetIDs: Set<String>) throws -> SkillLibrarySnapshot {
        guard !targetIDs.isEmpty else { return try load() }
        return try locked { state in
            // Retry unresolved legacy records even if an older build marked the Agent complete.
            let unresolvedTargets = Set(state.deployments.filter { deployment in
                guard let skill = state.skills.first(where: { $0.id == deployment.skillID }) else { return false }
                return skill.sourcePath == nil || deployment.mode != .symlink || deployment.sourcePath != skill.sourcePath
            }.map(\.targetID)).intersection(targetIDs)
            let pendingTargets = targetIDs.subtracting(state.migratedAgents ?? []).union(unresolvedTargets)
            if pendingTargets.isEmpty && state.skills.allSatisfy({ $0.sourcePath != nil }) {
                try refreshSources(&state); return snapshot(state)
            }
            var updated: [SkillRecord] = []
            var warnings: [String] = []
            for record in state.skills where record.sourcePath == nil {
                do {
                    var next = record
                    try initializeSource(&next, files: verifiedFiles(record.id, record.revision), state: state)
                    updated.append(next)
                } catch { warnings.append(record.name + ": " + error.localizedDescription) }
            }
            let skills = Dictionary(uniqueKeysWithValues: (state.skills.filter { original in !updated.contains { $0.id == original.id } } + updated).map { ($0.id, $0) })
            var changes: [Change] = []
            for before in state.deployments where pendingTargets.contains(before.targetID) {
                guard let skill = skills[before.skillID], let source = skill.sourcePath else { continue }
                if before.mode == .symlink && before.sourcePath == source { continue }
                guard inspect(before).status == .active,
                      source != entryIdentity(before.path), !source.hasPrefix(entryIdentity(before.path) + "/") else {
                    warnings.append(skill.name + " / " + before.targetID + ": " + SkillError.changed.rawValue)
                    continue
                }
                let after = SkillDeployment(skillID: skill.id, targetID: before.targetID, path: before.path,
                    mode: .symlink, revision: skill.revision, fingerprint: "link:" + source, sourcePath: source)
                changes.append(Change(path: before.path,
                    parent: URL(fileURLWithPath: before.path).deletingLastPathComponent().resolvingSymlinksInPath().path,
                    expected: before.fingerprint, before: before, after: after, backup: nil))
            }
            if !changes.isEmpty || !updated.isEmpty {
                if let manifestBytes {
                    try atomicWrite(manifestBytes, to: root.appendingPathComponent("migration-backups/\(UUID().uuidString).json"))
                }
                let paths = Set(changes.map(\.path))
                let obsolete = state.history.filter { $0.changes.contains { paths.contains($0.path) } }
                state.retainedBackups = Array(Set((state.retainedBackups ?? []) + obsolete.flatMap { $0.changes.compactMap(\.backup) }))
                state.history.removeAll { transaction in obsolete.contains { $0.id == transaction.id } }
                try execute(Transaction(id: UUID(), changes: changes, updatedSources: updated), state: &state, undo: false)
            }
            let incompleteTargets = Set(state.deployments.filter { deployment in
                guard pendingTargets.contains(deployment.targetID), let skill = skills[deployment.skillID] else { return false }
                return skill.sourcePath == nil || deployment.mode != .symlink || deployment.sourcePath != skill.sourcePath
            }.map(\.targetID))
            state.migratedAgents = (state.migratedAgents ?? []).union(pendingTargets).subtracting(incompleteTargets)
            try save(&state)
            try refreshSources(&state)
            var result = snapshot(state)
            result.migrationIssues += warnings
            return result
        }
    }

    private func activeDirectory(_ skill: SkillRecord) throws -> URL {
        guard let path = skill.sourcePath else { return try revisionDirectory(skill.id, skill.revision) }
        let url = URL(fileURLWithPath: path)
        let resolved = url.resolvingSymlinksInPath()
        guard entryIdentity(path) == path,
              (try? fm.attributesOfItem(atPath: resolved.path)[.type] as? FileAttributeType) == .typeDirectory else {
            throw SkillError.sourceUnavailable
        }
        return resolved
    }

    private func activeFiles(_ skill: SkillRecord) throws -> [SkillFiles.File] {
        let files = try SkillFiles.read(activeDirectory(skill))
        guard SkillFiles.hash(files) == skill.revision,
              try SkillFiles.document(files).1.name == skill.name else { throw SkillError.changed }
        return files
    }

    private func managedSource(_ id: UUID, name: String) -> URL {
        root.appendingPathComponent("sources/\(id.uuidString)/\(name)").standardizedFileURL
    }

    private func initializeSource(_ skill: inout SkillRecord, files: [SkillFiles.File], state: State) throws {
        if skill.source.kind == .local {
            let original = URL(fileURLWithPath: skill.source.location)
            let resolved = original.resolvingSymlinksInPath()
            let insideLibrary = resolved.path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
            let owned = state.deployments.contains { entryIdentity($0.path) == entryIdentity(original.path) }
            if !insideLibrary, !owned, fm.fileExists(atPath: resolved.path) {
                let sourceFiles = try SkillFiles.read(resolved)
                guard try SkillFiles.document(sourceFiles).1.name == skill.name else { throw SkillError.changed }
                skill.sourcePath = entryIdentity(original.path)
                try revise(&skill, files: sourceFiles, source: skill.source)
                return
            }
        }
        let directory = managedSource(skill.id, name: skill.name)
        if fm.fileExists(atPath: directory.path) {
            guard SkillFiles.hash(try SkillFiles.read(directory)) == SkillFiles.hash(files) else { throw SkillError.changed }
        } else { try SkillFiles.write(files, to: directory) }
        skill.sourcePath = directory.resolvingSymlinksInPath().path
    }

    /// Observe external edits without changing any source or Agent file.
    private func refreshSources(_ state: inout State) throws {
        var changed = false
        for index in state.skills.indices where state.skills[index].sourcePath != nil {
            guard let directory = try? activeDirectory(state.skills[index]),
                  let files = try? SkillFiles.read(directory),
                  let document = try? SkillFiles.document(files).1,
                  document.name == state.skills[index].name else { continue }
            if SkillFiles.hash(files) != state.skills[index].revision {
                try revise(&state.skills[index], files: files, source: state.skills[index].source)
                changed = true
            }
        }
        if changed { try save(&state) }
    }

    /// Reuse the deployment journal for atomic directory replacement and crash rollback.
    private func writeSource(_ updated: SkillRecord, replacing previous: SkillRecord, state: inout State) throws {
        _ = try activeFiles(previous)
        guard previous.sourcePath != nil else {
            guard let index = state.skills.firstIndex(where: { $0.id == updated.id }) else { throw SkillError.missing }
            state.skills[index] = updated
            try save(&state)
            return
        }
        let path = try activeDirectory(previous).path
        let before = SkillDeployment(skillID: previous.id, targetID: "source", path: path, mode: .copy,
            revision: previous.revision, fingerprint: "tree:" + previous.revision)
        let after = SkillDeployment(skillID: updated.id, targetID: "source", path: path, mode: .copy,
            revision: updated.revision, fingerprint: "tree:" + updated.revision)
        let change = Change(path: path, parent: URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path,
            expected: before.fingerprint, before: before, after: after, backup: nil, sourceID: updated.id,
            sourceReference: previous.sourcePath)
        try execute(Transaction(id: UUID(), changes: [change], updatedSources: [updated]), state: &state, undo: false)
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
            + Array((state.restores ?? [:]).values) + (state.retainedBackups ?? [])).compactMap(transactionID(ofBackup:)))
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

    private func inspect(_ deployment: SkillDeployment) -> SkillDeploymentInspection {
        let url = URL(fileURLWithPath: deployment.path)
        let fingerprint = (try? SkillFiles.fingerprint(url)) ?? "unreadable"
        let status: SkillDeploymentInspection.Status
        if fingerprint == "unreadable" { status = .unreadable }
        else if fingerprint == "missing" { status = .missing }
        else if fingerprint == deployment.fingerprint && fm.fileExists(atPath: deployment.path) { status = .active }
        else { status = .changed }
        return SkillDeploymentInspection(deployment: deployment, fingerprint: fingerprint,
            resolvedParent: url.deletingLastPathComponent().resolvingSymlinksInPath().path, status: status)
    }

    private func snapshot(_ state: State) -> SkillLibrarySnapshot {
        var issues: [UUID: String] = [:]
        for skill in state.skills where skill.sourcePath != nil {
            do { _ = try activeFiles(skill) } catch { issues[skill.id] = error.localizedDescription }
        }
        let legacy = state.deployments.filter { $0.sourcePath == nil || $0.mode == .copy }
            .map { $0.targetID + ": " + $0.path }
        return SkillLibrarySnapshot(revision: state.revision, skills: state.skills.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            deployments: state.deployments, canUndo: !state.history.isEmpty,
            deploymentInspections: Dictionary(uniqueKeysWithValues: state.deployments.map { ($0.id, inspect($0)) }),
            suspendedSkillIDs: Set((state.suspended ?? []).compactMap { $0.deployment?.skillID }),
            sourceIssues: issues, migrationIssues: legacy)
    }
    private func save(_ state: inout State) throws { state.revision += 1; try persist(state) }
    private func persist(_ state: State) throws {
        let url = root.appendingPathComponent("skills.json")
        let current = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == manifestBytes else { throw SkillError.changed }
        var persisted = state
        persisted.schema = 2 // Older apps must fail closed instead of treating live sources as immutable versions.
        let data = try JSONEncoder().encode(persisted)
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
            guard [1, 2].contains(state.schema), state.revision < UInt64.max,
                  Set(state.skills.map(\.id)).count == state.skills.count,
                  Set(state.deployments.map(\.path)).count == state.deployments.count else { throw SkillError.corrupt }
            for record in state.skills { try SkillDocument.validateName(record.name) }
        } catch { throw SkillError.corrupt }
        try recover(&state)
        try recoverLocal(&state)
        return try operation(&state)
    }
}
