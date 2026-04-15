import AVFAudio
import XCTest
@testable import DictKitSystemDictionary

final class SpeechAudioEncoderTests: XCTestCase {
    func testEncodeProducesWaveHeaderForInt16MonoPCM() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format!, frameCapacity: 3))
        buffer.frameLength = 3
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        samples[0] = 0
        samples[1] = 1024
        samples[2] = -1024

        let data = try SpeechAudioEncoder.encodeWave(from: [buffer])

        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self), "WAVE")
        XCTAssertGreaterThan(data.count, 44)
        XCTAssertEqual(Self.dataChunkSize(in: data), 6)
    }

    private static func dataChunkSize(in data: Data) -> UInt32? {
        let bytes = Array(data)
        var index = 12

        while index + 8 <= bytes.count {
            let chunkID = String(decoding: bytes[index..<(index + 4)], as: UTF8.self)
            let size = Data(bytes[(index + 4)..<(index + 8)]).withUnsafeBytes { $0.load(as: UInt32.self) }
            if chunkID == "data" {
                return size
            }
            index += 8 + Int(size)
        }

        return nil
    }
}
