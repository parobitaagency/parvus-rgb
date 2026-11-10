import Foundation

/// A plain text log at ~/Library/Logs/Parvus/Parvus.log, for diagnosing the
/// keyboard protocol from the person's Mac.
enum Log {
    private static let url: URL = {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Parvus")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("Parvus.log")
    }()
    private static let queue = DispatchQueue(label: "com.parobita.parvus.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        NSLog("Parvus: %@", message)
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func hex(_ bytes: [UInt8], limit: Int = 24) -> String {
        bytes.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
