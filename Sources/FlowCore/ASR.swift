import FluidAudio
import Foundation

/// Parakeet (FluidAudio, CoreML on the Neural Engine). 16 kHz mono Float samples in, text out.
public final class Transcriber: @unchecked Sendable {
    let manager = AsrManager(config: .default)
    var layers = 2
    var vocab: VocabularyBoostingSession?
    public init() {}

    /// Bias recognition toward the user's dictionary (CTC word spotting, ~100 MB extra model).
    public func setVocabulary(_ words: [String]) async throws {
        guard !words.isEmpty else { vocab = nil; return }
        let terms = CustomVocabularyContext(terms: words.map { CustomVocabularyTerm(text: $0) })
        // Similarity floors on: the vocabulary is absent from most dictations, so favour no false insertions.
        vocab = try await VocabularyBoostingSession(
            vocabulary: terms, ctcModels: try await CtcModels.downloadAndLoad(),
            config: .init(spotterRescueMinSimilarity: 0.30, spotterRescueMultiWordMinSimilarity: 0.50))
    }

    public func load(_ version: AsrModelVersion = .ultra) async throws {
        try await manager.loadModels(try await AsrModels.downloadAndLoad(version: version))
        layers = await manager.decoderLayerCount
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        var state = TdtDecoderState.make(decoderLayers: layers)
        let r = try await manager.transcribe(samples, decoderState: &state)
        guard let vocab else { return r.text }
        return await vocab.rescore(text: r.text, tokenTimings: r.tokenTimings ?? [], audioSamples: samples)?.text ?? r.text
    }

    public static func loadFile(_ url: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(url)
    }
}
