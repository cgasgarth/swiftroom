import Foundation
import zlib

enum EmbeddedICC {
    static func read(_ url: URL, expectedLength: Int) throws -> Data? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let reader = ICCReader(data: data)
        guard expectedLength > 0, expectedLength <= 2_097_152 else { return nil }
        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) {
            return png(reader, expectedLength: expectedLength)
        }
        if data.starts(with: [255, 216]) { return jpeg(reader) }
        if data.starts(with: [73, 73, 42, 0]) { return tiff(reader, littleEndian: true) }
        if data.starts(with: [77, 77, 0, 42]) { return tiff(reader, littleEndian: false) }
        return nil
    }

    private static func png(_ reader: ICCReader, expectedLength: Int) -> Data? {
        var offset = 8
        while let length = reader.integer(at: offset, bytes: 4),
              let type = reader.slice(at: offset + 4, length: 4),
              let payload = reader.slice(at: offset + 8, length: length) {
            guard length <= reader.data.count - offset - 12 else { return nil }
            if type == Data("iCCP".utf8) {
                guard let separator = payload.firstIndex(of: 0), separator < payload.count - 2,
                      payload[separator + 1] == 0 else { return nil }
                let compressed = payload.subdata(in: (separator + 2)..<payload.count)
                var decoded = Data(count: expectedLength)
                var decodedLength = uLongf(expectedLength)
                let status = decoded.withUnsafeMutableBytes { output in
                    compressed.withUnsafeBytes { input in
                        uncompress(output.bindMemory(to: Bytef.self).baseAddress, &decodedLength,
                                   input.bindMemory(to: Bytef.self).baseAddress, uLong(compressed.count))
                    }
                }
                guard status == Z_OK, decodedLength <= expectedLength else { return nil }
                return Data(decoded.prefix(Int(decodedLength)))
            }
            offset += length + 12
        }
        return nil
    }

    private static func jpeg(_ reader: ICCReader) -> Data? {
        var offset = 2
        var chunks = ICCChunks()
        while offset < reader.data.count {
            guard reader.integer(at: offset, bytes: 1) == 255 else { return nil }
            offset += 1
            while reader.integer(at: offset, bytes: 1) == 255 { offset += 1 }
            guard let marker = reader.integer(at: offset, bytes: 1) else { return nil }
            offset += 1
            if marker == 218 || marker == 217 { break }
            if marker == 1 || (208...215).contains(marker) { continue }
            guard let length = reader.integer(at: offset, bytes: 2), length >= 2,
                  let payload = reader.slice(at: offset + 2, length: length - 2) else { return nil }
            if marker == 226, payload.starts(with: Data("ICC_PROFILE\0".utf8)) {
                guard chunks.append(payload) else { return nil }
            }
            offset += length
        }
        return chunks.profile
    }

    private static func tiff(_ reader: ICCReader, littleEndian: Bool) -> Data? {
        guard let directory = reader.integer(at: 4, bytes: 4, littleEndian: littleEndian),
              let count = reader.integer(at: directory, bytes: 2, littleEndian: littleEndian),
              count <= (reader.data.count - directory - 2) / 12 else { return nil }
        for index in 0..<count {
            let entry = directory + 2 + index * 12
            guard reader.integer(at: entry, bytes: 2, littleEndian: littleEndian) == 34675 else { continue }
            guard let type = reader.integer(at: entry + 2, bytes: 2, littleEndian: littleEndian),
                  type == 7 || type == 1,
                  let length = reader.integer(at: entry + 4, bytes: 4, littleEndian: littleEndian),
                  length > 4, length <= 2_097_152,
                  let offset = reader.integer(at: entry + 8, bytes: 4, littleEndian: littleEndian) else { return nil }
            return reader.slice(at: offset, length: length)
        }
        return nil
    }
}

private struct ICCChunks {
    private var chunks: [Int: Data] = [:]
    private var total = 0

    mutating func append(_ payload: Data) -> Bool {
        guard payload.count >= 14 else { return false }
        let sequence = Int(payload[12])
        let count = Int(payload[13])
        guard sequence > 0, sequence <= count, count > 0,
              total == 0 || total == count, chunks[sequence] == nil else { return false }
        total = count
        chunks[sequence] = payload.subdata(in: 14..<payload.count)
        return true
    }

    var profile: Data? {
        guard total > 0, chunks.count == total else { return nil }
        var profile = Data()
        for sequence in 1...total {
            guard let chunk = chunks[sequence], profile.count + chunk.count <= 2_097_152 else { return nil }
            profile.append(chunk)
        }
        return profile
    }
}

private struct ICCReader {
    let data: Data

    func slice(at offset: Int, length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset <= data.count, length <= data.count - offset else { return nil }
        return data.subdata(in: offset..<(offset + length))
    }

    func integer(at offset: Int, bytes: Int, littleEndian: Bool = false) -> Int? {
        guard let value = slice(at: offset, length: bytes) else { return nil }
        return (littleEndian ? Array(value.reversed()) : Array(value)).reduce(0) { $0 * 256 + Int($1) }
    }
}
