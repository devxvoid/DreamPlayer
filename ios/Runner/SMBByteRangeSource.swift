import Foundation
import AetherEngineSMB
import SMBClient

/// A seekable byte source backed by a kishikawakatsumi/SMBClient `FileReader`.
/// Conforms to AetherEngineSMB's `ByteRangeSource` protocol so it can be
/// wrapped by `BufferedSMBReader` and fed to AetherEngine's custom source path.
///
/// Each `read(at:length:)` call delegates to the SMBClient `FileReader` which
/// handles the underlying SMB2 READ messages over the connection's TCP socket.
/// A short-lived lock guards only the one-time lazy file-handle open; the
/// actual network read runs without holding any lock so cooperative threads
/// are never blocked during I/O.
final class SMBByteRangeSource: ByteRangeSource, @unchecked Sendable {

    private let reader: FileReader

    let byteSize: Int64

    /// Wraps a `FileReader` from the kishikawakatsumi/SMBClient library.
    /// `fileSize` is the total file size in bytes.
    init(reader: FileReader, fileSize: Int64) {
        self.reader = reader
        self.byteSize = fileSize
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        try await reader.read(offset: UInt64(bitPattern: offset), length: UInt32(truncatingIfNeeded: length))
    }

    func close() {
        // The SMBClient connection is managed by SMBChannel; we don't close
        // the reader here — it's bound to the connection's share handle.
    }
}
