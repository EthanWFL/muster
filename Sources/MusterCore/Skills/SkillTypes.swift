import Foundation

public enum SkillError: String, LocalizedError {
    case localSkillShared = "This skill is visible through a shared or duplicate source. It cannot be disabled for this Agent alone."
    case localSkillOccupied = "The original skill path is occupied. Its saved entry was kept; move the conflicting entry before restoring."
    case outsideScope = "This deployment includes Agents outside the current scope. Select them in Settings before restoring it."
    case invalidDocument = "A skill needs valid YAML name and description fields in SKILL.md."
    case unsafeName = "Use a skill name containing only letters, numbers, hyphens or underscores (1–64 characters)."
    case unsafeTree = "This skill contains a symbolic link or special file. Import a self-contained folder instead."
    case tooLarge = "The skill exceeds the limit of 2,000 files or 32 MiB."
    case scanLimit = "The search exceeded its directory limit. Choose a smaller folder."
    case changed = "The skill or its destination changed. Refresh and preview again."
    case occupied = "This destination contains files not managed by Muster. They have been left unchanged."
    case deployed = "This skill is deployed to one or more Agents. Disable those deployments before removing it."
    case sourceIsDeployment = "This skill was imported from an Agent folder that Muster now deploys into, so that folder can no longer be its update source."
    case unsupportedFile = "This file is not UTF-8 text or is too large to open in the editor."
    case invalidFileName = "Use a relative path made of folder and file names without empty parts, “.” or “..”."
    case corrupt = "The skill library could not be read. Its files have been left unchanged."
    case missing = "This skill or revision is no longer available."
    case noSource = "This skill has no update source."
    case invalidRepository = "Enter an HTTPS Git repository or GitHub owner/repo, with a separate ref and subdirectory."
    case gitFailed = "Git could not fetch this repository. Check its URL, ref and access permissions."
    case gitTimedOut = "Repository download timed out or exceeded its size limit."
    case invalidPath = "Choose an absolute folder path within the skill."
    case recovery = "An interrupted skill operation needs recovery. Refresh the library before continuing."
    public var errorDescription: String? { rawValue }
}

public enum SkillInstallMode: String, Codable, CaseIterable, Sendable { case symlink, copy }

public struct SkillSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case local, git, created }
    public var kind: Kind
    public var location: String
    public var ref: String
    public var subdirectory: String
    public var commit: String?
    public init(kind: Kind, location: String = "", ref: String = "", subdirectory: String = "", commit: String? = nil) {
        self.kind = kind; self.location = location; self.ref = ref; self.subdirectory = subdirectory; self.commit = commit
    }
}

public struct SkillRevision: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let date: Date
    public let source: SkillSource
}

public struct SkillRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var summary: String
    public var license: String?
    public var revision: String
    public var revisions: [SkillRevision]
    public var source: SkillSource
}

public struct SkillCandidate: Identifiable, Sendable {
    public var id: String { directory.path }
    public var isValid: Bool { !digest.isEmpty }
    public let directory: URL
    public let name: String
    public let summary: String
    public let license: String?
    public let warning: String?
    public let digest: String
    public let files: [String]
    public let source: SkillSource
}

public struct SkillTarget: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let directory: String
    public let discoveryDirectories: [String]
    public let sharedReaders: [String]
    public init(id: String, name: String, directory: String, discoveryDirectories: [String] = [], sharedReaders: [String] = []) {
        self.id = id; self.name = name; self.directory = directory
        self.discoveryDirectories = discoveryDirectories; self.sharedReaders = sharedReaders
    }
}

public struct AgentSkillCapability: Sendable {
    public var directory: AgentLocation
    public var additionalDiscovery: [AgentLocation] = []
    public var sharedReaders: [String] = []
}

public struct SkillDeployment: Codable, Equatable, Identifiable, Sendable {
    public var id: String { targetID + ":" + skillID.uuidString }
    public let skillID: UUID
    public let targetID: String
    public let path: String
    public let mode: SkillInstallMode
    public let revision: String
    public let fingerprint: String
}

public struct SkillPlanItem: Identifiable, Sendable {
    public var id: String { path }
    public let skillID: UUID
    public let skillName: String
    public let targetName: String
    public let path: String
    public let before: SkillDeployment?
    public let after: SkillDeployment?
    public let expected: String
    public let resolvedParent: String
    public let conflict: String?
    public let sharedReaders: [String]
    /// An unmanaged folder already occupies this destination, so the plan can only apply after
    /// the user lets Muster move that folder into the library as a backup.
    public let adoptable: Bool
    /// This plan replaces an unmanaged folder; the original is parked at `backup`.
    public let adopts: Bool
    /// Where a replaced folder is parked, or where undo finds the folder it has to move back.
    public let backup: String?
}

public struct SkillPlan: Identifiable, Sendable {
    public let id: UUID
    public let libraryRevision: UInt64
    public let items: [SkillPlanItem]
    public var canApply: Bool { !items.isEmpty && items.allSatisfy { $0.conflict == nil } }
    /// Paths that block the plan until they are allowed to be replaced.
    public var adoptablePaths: [String] { items.filter(\.adoptable).map(\.path) }
    public var adoptions: Int { items.filter(\.adopts).count }
    public var conflicts: Int { items.filter { $0.conflict != nil }.count }
    /// Skills the plan touches, in the order they first appear.
    public var skillIDs: [UUID] {
        var seen = Set<UUID>()
        return items.compactMap { seen.insert($0.skillID).inserted ? $0.skillID : nil }
    }
}

public struct SkillDraft: Codable, Sendable {
    public let baseRevision: String
    public let text: String
    /// Edited text files, relative to the skill folder. `SKILL.md` is always carried by `text`.
    public var files: [String: String]
    public var removed: [String]
    public init(baseRevision: String, text: String, files: [String: String] = [:], removed: [String] = []) {
        self.baseRevision = baseRevision; self.text = text; self.files = files; self.removed = removed
    }
    private enum CodingKeys: String, CodingKey { case baseRevision, text, files, removed }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseRevision = try container.decode(String.self, forKey: .baseRevision)
        text = try container.decode(String.self, forKey: .text)
        files = try container.decodeIfPresent([String: String].self, forKey: .files) ?? [:]
        removed = try container.decodeIfPresent([String].self, forKey: .removed) ?? []
    }
}

public struct SkillContent: Sendable {
    public let text: String
    public let files: [String]
    public let directory: URL
    public let draft: SkillDraft?
    /// Editable text files other than `SKILL.md`, keyed by their relative path.
    public let texts: [String: String]

    public init(text: String, files: [String], directory: URL, draft: SkillDraft?, texts: [String: String] = [:]) {
        self.text = text; self.files = files; self.directory = directory; self.draft = draft; self.texts = texts
    }
}

public struct SkillDiscovery: Identifiable, Sendable, Equatable {
    public var id: String { suspendedID.map { "suspended:" + $0.uuidString } ?? path }
    public let path: String
    public let name: String
    public let summary: String
    public var readers: [String]
    public let isShared: Bool
    public let managed: Bool
    public let issue: String?
    public var fingerprint: String? = nil
    public var digest: String? = nil
    public var resolvedPath: String? = nil
    public var suspendedID: UUID? = nil

    public func isSameSkill(as other: SkillDiscovery) -> Bool {
        name == other.name && digest != nil && digest == other.digest
    }
}

public struct SkillSuspension: Codable, Sendable, Identifiable {
    public let id: UUID
    public let path: String
    public let parent: String
    public let backup: String
    public let backupParent: String
    public let fingerprint: String
    public let targetID: String
    public let name: String
    public let summary: String
    public let digest: String
    public let resolvedSource: String
    public let deployment: SkillDeployment?
    public let restoreBackup: String?
}

public struct SkillDeploymentInspection: Identifiable, Sendable, Equatable {
    public enum Status: Sendable { case active, missing, changed, unreadable }
    public var id: String { deployment.id }
    public let deployment: SkillDeployment
    public let fingerprint: String
    public let resolvedParent: String
    public let status: Status
}

public struct SkillLibrarySnapshot: Sendable {
    public let revision: UInt64
    public let skills: [SkillRecord]
    public let deployments: [SkillDeployment]
    public let canUndo: Bool
    public var deploymentInspections: [String: SkillDeploymentInspection] = [:]
    public var suspendedSkillIDs: Set<UUID> = []
    public static let empty = Self(revision: 0, skills: [], deployments: [], canUndo: false)
}
