import Foundation
import Testing
@testable import MusterCore

@Suite struct ConfigurationDocumentTests {
    @Test func JSONPreservesUnknownFieldsAndFormatting() throws {
        let input = """
        {
          "nested": {"defaultModel": "untouched", "number": 12345678901234567890},
          "defaultProvider" : "original",
          "defaultModel": "old", "escaped": "quote: \\\" }"
        }
        """
        let document = try ConfigurationDocument(data: Data(input.utf8), json: true, keys: ["defaultProvider", "defaultModel"])
        let output = try document.replacing(["defaultModel": "vendor/new"])
        #expect(String(decoding: output, as: UTF8.self) == input.replacingOccurrences(of: "\"old\"", with: "\"vendor/new\""))
    }

    @Test func JSONAddsAbsentKeysAndRejectsDuplicates() throws {
        for input in ["{}", "{\n  \"nested\": [1, {\"x\": \"a,b\"}]\n}"] {
            let document = try ConfigurationDocument(data: Data(input.utf8), json: true, keys: ["defaultModel"])
            let output = try document.replacing(["defaultModel": "test"])
            let object = try JSONSerialization.jsonObject(with: output) as? [String: Any]
            #expect(object?["defaultModel"] as? String == "test")
        }
        #expect(throws: ConfigurationError.self) {
            try ConfigurationDocument(data: Data(#"{"defaultModel":"a", "defaultModel":"b"}"#.utf8), json: true, keys: ["defaultModel"])
        }
        #expect(throws: ConfigurationError.self) {
            try ConfigurationDocument(data: Data(#"{"defaultModel": 42}"#.utf8), json: true, keys: ["defaultModel"])
        }
        #expect(throws: ConfigurationError.self) {
            try ConfigurationDocument(data: Data("{broken}".utf8), json: true, keys: ["defaultModel"])
        }
    }

    @Test func TOMLPreservesCommentsTablesAndCRLF() throws {
        let input = "# user config\r\nmodel = 'old' # keep\r\nmodel_provider = \"custom\"\r\n[profiles.work]\r\nmodel = \"profile-model\"\r\n[model_providers.custom]\r\napi_key = \"do-not-touch\"\r\n"
        let document = try ConfigurationDocument(data: Data(input.utf8), json: false, keys: ["model", "model_provider"])
        #expect(document.values["model"] == "old")
        let output = try document.replacing(["model": "vendor/new"])
        #expect(String(decoding: output, as: UTF8.self) == input.replacingOccurrences(of: "'old'", with: "\"vendor/new\""))
    }

    @Test func TOMLInsertsAtRootAndSupportsQuotedKeys() throws {
        let input = "\"model\" = \"old\"\n[model_providers.custom]\nname = \"custom\"\n"
        let document = try ConfigurationDocument(data: Data(input.utf8), json: false, keys: ["model", "model_provider"])
        let output = try document.replacing(["model_provider": "custom", "model": "new"])
        #expect(String(decoding: output, as: UTF8.self).hasPrefix("model_provider = \"custom\"\n\"model\" = \"new\"\n"))
    }

    @Test func TOMLRejectsAmbiguousMultilineAndDuplicateSettings() throws {
        for input in ["description = \"\"\"\nmodel = 'not a setting'\n\"\"\"\n", "array = [\n'model = fake'\n]\n", "model='a'\nmodel='b'", "model = 42"] {
            #expect(throws: ConfigurationError.self) {
                try ConfigurationDocument(data: Data(input.utf8), json: false, keys: ["model"])
            }
        }
    }
}

@Suite struct AgentConfigurationStoreTests {
    private func target(_ tree: TempTree, id: String = "pi") -> AgentConfiguration {
        AgentConfiguration(id: id, name: id, path: tree.path(id == "pi" ? "settings.json" : "config.toml"))
    }
    private func store(_ tree: TempTree) -> AgentConfigurationStore {
        AgentConfigurationStore(backupDirectory: URL(fileURLWithPath: tree.path("backups")))
    }

    @Test func saveBackupRestoreAndPermissions() throws {
        let tree = try TempTree()
        let original = #"{"defaultProvider":"custom", "defaultModel":"old", "other":true}"#
        try tree.write("settings.json", original)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: tree.path("settings.json"))
        let service = store(tree)
        let snapshot = try service.load(target(tree))
        try service.save(snapshot, provider: "custom", model: "new")
        let saved = try service.load(target(tree))
        #expect(saved.model == "new")
        #expect(service.canRestore(saved))
        let permissions = try FileManager.default.attributesOfItem(atPath: tree.path("settings.json"))[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o640)
        let backupPermissions = try FileManager.default.attributesOfItem(atPath: tree.path("backups/pi.json"))[.posixPermissions] as? NSNumber
        #expect(backupPermissions?.intValue == 0o600)
        try service.restore(saved)
        #expect(try Data(contentsOf: URL(fileURLWithPath: tree.path("settings.json"))) == snapshot.data)
        #expect(!service.canRestore(try service.load(target(tree))))
    }

    @Test func externalChangesBlockSaveAndRestore() throws {
        let tree = try TempTree()
        try tree.write("settings.json", #"{"defaultModel":"old"}"#)
        let service = store(tree)
        let snapshot = try service.load(target(tree))
        try tree.write("settings.json", #"{"defaultModel":"external"}"#)
        #expect(throws: ConfigurationError.changed) { try service.save(snapshot, provider: "custom", model: "new") }
        let current = try service.load(target(tree))
        try service.save(current, provider: "custom", model: "new")
        let saved = try service.load(target(tree))
        try tree.write("settings.json", #"{"defaultModel":"external-again"}"#)
        #expect(throws: ConfigurationError.changed) { try service.restore(saved) }
    }

    @Test func preservesSymlinkAndRejectsRetargeting() throws {
        let tree = try TempTree()
        try tree.write("actual.json", #"{"defaultModel":"old"}"#)
        let link = tree.path("settings.json")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tree.path("actual.json"))
        let service = store(tree)
        let snapshot = try service.load(target(tree))
        try service.save(snapshot, provider: "custom", model: "new")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == tree.path("actual.json"))
        let saved = try service.load(target(tree))
        try tree.write("other.json", String(decoding: saved.data, as: UTF8.self))
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tree.path("other.json"))
        #expect(throws: ConfigurationError.changed) { try service.save(saved, provider: "custom", model: "next") }
    }

    @Test func rejectsInvalidInputsAndLeavesAbsentDefaultsAlone() throws {
        let tree = try TempTree()
        try tree.write("settings.json", "{}")
        let service = store(tree)
        let snapshot = try service.load(target(tree))
        let proposed = try service.proposed(snapshot, provider: "", model: "new")
        #expect(!String(decoding: proposed, as: UTF8.self).contains("defaultProvider"))
        #expect(throws: ConfigurationError.invalidValue) { try service.proposed(snapshot, provider: "x\ny", model: "new") }
        #expect(throws: ConfigurationError.invalidValue) { try service.proposed(snapshot, provider: "x", model: " new ") }
    }

    @Test func usesEnvironmentAndOnlyExistingFiles() {
        let targets = AgentConfiguration.detect(home: "/home/test", environment: ["CODEX_HOME": "/custom/codex"],
                                                 exists: { $0 == "/custom/codex/config.toml" })
        #expect(targets.count == 1)
        #expect(targets.first?.path == "/custom/codex/config.toml")
    }

    @Test func readsLocalPiModelsWithoutChangingProviderConfiguration() throws {
        let tree = try TempTree()
        try tree.write("settings.json", #"{"defaultProvider":"p", "defaultModel":"old"}"#)
        try tree.write("models.json", #"{"providers":{"p":{"apiKey":"secret", "models":[{"id":"new"}]},"q":{"models":[{"id":"other"}]}}}"#)
        let service = store(tree)
        let snapshot = try service.load(target(tree))
        #expect(service.choices(snapshot).map(\.label) == ["p / new", "p / old", "q / other"])
    }
}
