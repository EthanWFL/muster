import Foundation

/// Build a genuine pre-single-source manifest for compatibility and migration tests.
func markSkillSourcesAsLegacy(manifest: URL) throws {
    var state = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
    var skills = state["skills"] as! [[String: Any]]
    for index in skills.indices { skills[index].removeValue(forKey: "sourcePath") }
    state["schema"] = 1
    state["skills"] = skills
    state.removeValue(forKey: "migratedAgents")
    try JSONSerialization.data(withJSONObject: state).write(to: manifest)
    let sources = manifest.deletingLastPathComponent().appendingPathComponent("sources")
    if FileManager.default.fileExists(atPath: sources.path) { try FileManager.default.removeItem(at: sources) }
}
