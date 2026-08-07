import Foundation
import SiliconCore

/// Reads architecture metadata out of a GGUF file's header.
///
/// The catalog carries estimates, but once a file is on disk the header is authoritative — it
/// tells us the real layer count, expert count and expert FFN width, which is exactly what the
/// memory planner needs to size a KV cache or an expert slot pool. The file is memory-mapped,
/// so parsing a 40 GB model costs only the pages the header actually touches.
public struct GGUFReader: Sendable {

    public struct Metadata: Sendable {
        public var architecture: String
        public var name: String?
        public var tensorCount: UInt64
        public var values: [String: Value]
        /// Total parameters, summed from the tensor table. Authoritative, and the only source
        /// available for a file the catalog has never heard of.
        public var parameterCount: Int64

        public func integer(_ suffix: String) -> Int? {
            values["\(architecture).\(suffix)"]?.intValue
        }
    }

    public enum Value: Sendable {
        case integer(Int64)
        case double(Double)
        case string(String)
        case boolean(Bool)
        /// Arrays are recorded by length only. The tokenizer vocabulary is an array of well
        /// over 100k strings and nothing in the planner needs its contents.
        case arrayOfCount(Int)

        public var intValue: Int? {
            switch self {
            case .integer(let value): Int(value)
            case .double(let value): Int(value)
            case .boolean(let value): value ? 1 : 0
            default: nil
            }
        }

        public var stringValue: String? {
            if case .string(let value) = self { return value }
            return nil
        }
    }

    public enum ReadError: Error, LocalizedError {
        case notGGUF
        case unsupportedVersion(UInt32)
        case truncated

        public var errorDescription: String? {
            switch self {
            case .notGGUF: "This file is not in GGUF format."
            case .unsupportedVersion(let version): "Unsupported GGUF version \(version)."
            case .truncated: "The GGUF header is incomplete — the download may not have finished."
            }
        }
    }

    public init() {}

    public func read(at url: URL) throws -> Metadata {
        try read(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Parses a header out of bytes already in hand.
    ///
    /// Split from `read(at:)` so the same parser can work on a range fetched over HTTP — which
    /// is how a model's real architecture is known before any of it is downloaded.
    public func read(data: Data) throws -> Metadata {
        var cursor = Cursor(data: data)

        guard try cursor.uint32() == 0x4655_4747 else { throw ReadError.notGGUF }  // "GGUF"
        let version = try cursor.uint32()
        guard (2...3).contains(version) else { throw ReadError.unsupportedVersion(version) }

        let tensorCount = try cursor.uint64()
        let kvCount = try cursor.uint64()

        var values: [String: Value] = [:]
        values.reserveCapacity(Int(kvCount))
        for _ in 0..<kvCount {
            let key = try cursor.string()
            values[key] = try cursor.value()
        }

        // The tensor table follows the metadata. Summing the element counts gives the exact
        // parameter total — worth the extra pass, because without it an imported model has no
        // parameter count at all and the planner sizes its weights at zero.
        let parameterCount = (try? cursor.tensorParameterCount(tensorCount)) ?? 0

        return Metadata(
            architecture: values["general.architecture"]?.stringValue ?? "unknown",
            name: values["general.name"]?.stringValue,
            tensorCount: tensorCount,
            values: values,
            parameterCount: parameterCount
        )
    }

    /// Converts parsed metadata into the shape the planner works with.
    public func shape(from metadata: Metadata, fallback: ModelShape? = nil) -> ModelShape? {
        guard let blockCount = metadata.integer("block_count"),
              let embeddingLength = metadata.integer("embedding_length"),
              let headCount = metadata.integer("attention.head_count")
        else { return fallback }

        var moe: MoEShape?
        if let expertCount = metadata.integer("expert_count"), expertCount > 0 {
            let expertFFN = metadata.integer("expert_feed_forward_length")
                ?? metadata.integer("feed_forward_length") ?? 0
            let used = metadata.integer("expert_used_count") ?? 8
            // Some architectures keep early blocks dense. When the header does not say, assume
            // every block is MoE, which is the conservative direction for memory planning.
            let denseLayers = metadata.integer("leading_dense_block_count") ?? 0
            moe = MoEShape(
                expertCount: expertCount,
                expertsUsedPerToken: used,
                expertFeedForwardLength: expertFFN,
                moeLayerCount: blockCount - denseLayers,
                activeParameters: fallback?.moe?.activeParameters ?? 0,
                hasSharedExpert: (metadata.integer("expert_shared_count") ?? 0) > 0
            )
        }

        return ModelShape(
            // The tensor table is authoritative; the catalog estimate is only a fallback for
            // headers that could not be walked.
            totalParameters: metadata.parameterCount > 0
                ? metadata.parameterCount
                : (fallback?.totalParameters ?? 0),
            blockCount: blockCount,
            embeddingLength: embeddingLength,
            feedForwardLength: metadata.integer("feed_forward_length") ?? 0,
            headCount: headCount,
            headCountKV: metadata.integer("attention.head_count_kv") ?? headCount,
            trainingContextLength: metadata.integer("context_length") ?? 8192,
            vocabSize: fallback?.vocabSize ?? 152_064,
            // `key_length` is authoritative where present; models that decouple head width from
            // the residual stream (Qwen3, gpt-oss) always publish it.
            headDimension: metadata.integer("attention.key_length")
                ?? fallback?.headDimensionOverride,
            moe: moe
        )
    }

    // MARK: - Binary cursor

    private struct Cursor {
        let data: Data
        var offset: Int = 0

        mutating func require(_ count: Int) throws -> Range<Int> {
            let start = data.startIndex + offset
            guard start + count <= data.endIndex else { throw ReadError.truncated }
            offset += count
            return start..<(start + count)
        }

        mutating func uint32() throws -> UInt32 {
            let range = try require(4)
            return data[range].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }

        mutating func uint64() throws -> UInt64 {
            let range = try require(8)
            return data[range].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        }

        mutating func string() throws -> String {
            let length = Int(try uint64())
            let range = try require(length)
            return String(decoding: data[range], as: UTF8.self)
        }

        /// Size in bytes of a fixed-width GGUF scalar type, or nil for variable-width types.
        static func scalarWidth(_ type: UInt32) -> Int? {
            switch type {
            case 0, 1, 7: 1        // uint8, int8, bool
            case 2, 3: 2           // uint16, int16
            case 4, 5, 6: 4        // uint32, int32, float32
            case 10, 11, 12: 8     // uint64, int64, float64
            default: nil
            }
        }

        mutating func value() throws -> Value {
            let type = try uint32()
            return try value(ofType: type)
        }

        mutating func value(ofType type: UInt32) throws -> Value {
            switch type {
            case 0: Value.integer(Int64(data[try require(1)].first ?? 0))
            case 1: Value.integer(Int64(Int8(bitPattern: data[try require(1)].first ?? 0)))
            case 2: Value.integer(Int64(data[try require(2)].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }))
            case 3: Value.integer(Int64(data[try require(2)].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }))
            case 4: Value.integer(Int64(try uint32()))
            case 5: Value.integer(Int64(Int32(bitPattern: try uint32())))
            case 6: Value.double(Double(Float(bitPattern: try uint32())))
            case 7: Value.boolean((data[try require(1)].first ?? 0) != 0)
            case 8: Value.string(try string())
            case 9: try array()
            case 10: Value.integer(Int64(bitPattern: try uint64()))
            case 11: Value.integer(Int64(bitPattern: try uint64()))
            case 12: Value.double(Double(bitPattern: try uint64()))
            default: throw ReadError.truncated
            }
        }

        /// Walks the tensor table, summing each tensor's element count.
        ///
        /// Each entry is: name, `n_dims` (u32), that many u64 dimensions, a ggml type (u32) and
        /// a u64 data offset. Only the dimensions matter here.
        mutating func tensorParameterCount(_ count: UInt64) throws -> Int64 {
            var total: Int64 = 0
            for _ in 0..<count {
                _ = try string()
                let dimensionCount = try uint32()
                // Guard against a corrupt header sending this into a huge loop.
                guard dimensionCount <= 8 else { throw ReadError.truncated }
                var elements: Int64 = 1
                for _ in 0..<dimensionCount {
                    elements *= Int64(try uint64())
                }
                _ = try uint32()      // ggml type
                _ = try uint64()      // offset
                total += elements
            }
            return total
        }

        /// Skips over an array's payload without materializing it.
        mutating func array() throws -> Value {
            let elementType = try uint32()
            let count = Int(try uint64())
            if let width = Self.scalarWidth(elementType) {
                _ = try require(width * count)      // one bounds-checked jump
            } else {
                // Strings and nested arrays are variable-width and must be walked.
                for _ in 0..<count { _ = try value(ofType: elementType) }
            }
            return .arrayOfCount(count)
        }
    }
}
