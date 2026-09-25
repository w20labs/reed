import Foundation

enum WAVWriter {
    static func wrap(pcm: Data, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) -> Data {
        var data = Data()
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)
        let chunkSize = 36 + dataSize

        data.append(Data("RIFF".utf8))
        data.append(le32(chunkSize))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        data.append(le32(16))
        data.append(le16(1))
        data.append(le16(channels))
        data.append(le32(sampleRate))
        data.append(le32(byteRate))
        data.append(le16(blockAlign))
        data.append(le16(bitsPerSample))
        data.append(Data("data".utf8))
        data.append(le32(dataSize))
        data.append(pcm)
        return data
    }

    private static func le16(_ v: UInt16) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 2)
    }

    private static func le32(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
    }
}
