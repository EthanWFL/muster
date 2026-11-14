import Foundation

public enum SkillError: String, LocalizedError {
    case outsideScope = "This deployment includes Agents outside the current scope. Select them in Settings before restoring it."
    case invalidDocument = "A skill needs valid YAML name and description fields in SKILL.md."
    case unsafeName = "Use a skill name containing only letters, numbers, hyphens or underscores (1–64 characters)."
    case unsafeTree = "This skill contains a symbolic link or special file. Import a self-contained folder instead."
    case tooLarge = "The skill exceeds the limit of 2,000 files or 32 MiB."
    case scanLimit = "The search exceeded its directory limit. Choose a smaller folder."
    case changed = "The skill or its destination changed. Refresh and preview again."
    case occupied = "This destination contains files not managed by Muster. They have been left unchanged."
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
    public let targetName: String
    public let path: String
    public let before: SkillDeployment?
    public let after: SkillDeployment?
    public let expected: String
    public let resolvedParent: String
    public let conflict: String?
    public let sharedReaders: [String]
}

public struct SkillPlan: Identifiable, Sendable {
    public let id: UUID
    public let libraryRevision: UInt64
    public let items: [SkillPlanItem]
    public var canApply: Bool { !items.isEmpty && items.allSatisfy { $0.conflict == nil } }
}

public struct SkillDraft: Codable, Sendable {
    public let baseRevision: String
    public let text: String
}

public struct SkillContent: Sendable {
    public let text: String
    public let files: [String]
    public let directory: URL
    public let draft: SkillDraft?
}

public struct SkillDiscovery: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let summary: String
    public var readers: [String]
    public let isShared: Bool
    public let managed: Bool
    public let issue: String?
}

public struct SkillLibrarySnapshot: Sendable {
    public let revision: UInt64
    public let skills: [SkillRecord]
    public let deployments: [SkillDeployment]
    public let canUndo: Bool
    public static let empty = Self(revision: 0, skills: [], deployments: [], canUndo: false)
}
