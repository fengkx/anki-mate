import Foundation
#if canImport(AVFAudio)
import AVFAudio

enum SpeechAudioEncoder {
    static func encodeWave(from buffers: [AVAudioPCMBuffer]) throws -> Data {
        guard let first = buffers.first else {
            throw SpeechError.audioEncodingFailed
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        var audioFile: AVAudioFile? = try AVAudioFile(
            forWriting: temporaryURL,
            settings: first.format.settings,
            commonFormat: first.format.commonFormat,
            interleaved: first.format.isInterleaved
        )

        for buffer in buffers {
            try audioFile?.write(from: buffer)
        }

        audioFile = nil

        guard let data = try? Data(contentsOf: temporaryURL), !data.isEmpty else {
            throw SpeechError.audioEncodingFailed
        }

        return data
    }
}
#endif
