import Foundation

/// First-launch model downloads: the two cleanup models from this repo's GitHub release, the assistant from Hugging Face.
/// Files land in a hidden ".partial" folder that is renamed only when complete, so a cut-off download never gets loaded.
struct ModelDownload {
    let name: String
    let files: [(url: URL, name: String)]
    let bytes: Int64   // approximate total, for the progress bar

    static let release = "https://github.com/QuantummDuck/LocalFlow/releases/download/models-v1/"
    static let cleanupFiles = ["config.json", "model.safetensors", "model.safetensors.index.json", "tokenizer.json",
                               "tokenizer_config.json", "chat_template.jinja"]
    static func cleanup(_ name: String) -> ModelDownload {
        ModelDownload(name: name, files: cleanupFiles.map { (URL(string: release + "\(name).\($0)")!, $0) }, bytes: 980_000_000)
    }
    static let cleaner = cleanup("cleaner"), cleanerFix = cleanup("cleaner-fix")

    static let assistantRepo = "https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit/resolve/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b/"
    static let assistant = ModelDownload(name: "assistant", files: [
        "added_tokens.json", "chat_template.jinja", "config.json", "generation_config.json", "merges.txt", "model.safetensors",
        "model.safetensors.index.json", "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "vocab.json",
    ].map { (URL(string: assistantRepo + $0)!, $0) }, bytes: 2_280_000_000)

    func installed(in support: URL) -> Bool {
        FileManager.default.fileExists(atPath: support.appendingPathComponent("models/\(name)/config.json").path)
    }

    /// Downloads every file, reporting 0…1 progress (at most once per percent).
    func fetch(into support: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let dest = support.appendingPathComponent("models/\(name)"), tmp = support.appendingPathComponent("models/.\(name).partial")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        var done: Int64 = 0
        for f in files {
            let base = done, total = bytes
            let tracker = Tracker { written in progress(min(1, Double(base + written) / Double(total))) }
            let (file, response) = try await URLSession.shared.download(from: f.url, delegate: tracker)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            done += (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
            try fm.moveItem(at: file, to: tmp.appendingPathComponent(f.name))
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
    }
}

private final class Tracker: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onWrite: (Int64) -> Void
    var lastStep = -1
    init(_ onWrite: @escaping (Int64) -> Void) { self.onWrite = onWrite }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        let step = Int(totalBytesWritten / 10_000_000)   // ~every 10 MB
        if step != lastStep { lastStep = step; onWrite(totalBytesWritten) }
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
