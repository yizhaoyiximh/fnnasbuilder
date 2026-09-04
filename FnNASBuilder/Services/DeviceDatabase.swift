import Foundation

/// Loads the 15-column colon-delimited database shipped with FnNAS.
final class DeviceDatabase {
    static let shared = DeviceDatabase()
    private(set) var devices: [Device] = []
    private init() { devices = Self.load() }

    static func parse(_ text: String, onlyBuildable: Bool = true) -> [Device] {
        var result: [Device] = []
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let raw = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, !raw.hasPrefix("#") else { continue }
            let c = raw.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            // ID + 14 columns; index 13 is BOARD and 14 is BUILD.
            guard c.count >= 15, let board = c[safe: 13], !board.isEmpty, board != "NA" else { continue }
            guard !onlyBuildable || c[safe: 14]?.lowercased() == "yes" else { continue }
            result.append(Device(id: board, model: c[safe: 1] ?? "", soc: c[safe: 2] ?? "",
                                 platform: c[safe: 9] ?? "", family: c[safe: 10] ?? "",
                                 description: c[safe: 7] ?? ""))
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func load() -> [Device] {
        let fm = FileManager.default
        let urls = [Bundle.main.url(forResource: "model_database", withExtension: "conf"),
                    Bundle.main.url(forResource: "model_database", withExtension: "conf", subdirectory: "fnnas/make-fnnas/fnnas-files/common-files/etc"),
                    URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("fnnas/make-fnnas/fnnas-files/common-files/etc/model_database.conf")].compactMap { $0 }
        guard let u = urls.first(where: { fm.fileExists(atPath: $0.path) }), let text = try? String(contentsOf: u, encoding: .utf8) else { return [] }
        return parse(text)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
