import Foundation
import SiliconCore

/// Reads architecture metadata out of a GGUF file's header.
///
/// The catalog carries estimates, but once a file is on disk the header is authoritative — it
/// tells us the real layer count, expert count and expert FFN width, which is exactly what the
/// memory planner needs to size a KV cache or an expert slot pool. The file is memory-mapped,
/// so parsing a 40 GB model costs only the pages the header actually touches.
public struct GGUFReader: Sendable {

    private enum Limits {
        static let headerBytes = 64 * 1_048_576
        static let metadataEntries = 65_536
        static let stringBytes = 16 * 1_048_576
        static let arrayElements = 16 * 1_048_576
        static let variableValues = 1_000_000
        static let arrayNestingDepth = 16
        static let tensors = 262_144
        static let tensorDimensions = 8
    }

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
            case .integer(let value): return Int(exactly: value)
            case .double(let value):
                guard value.isFinite, value.rounded(.towardZero) == value else { return nil }
                return Int(exactly: value)
            default: return nil
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
        case invalidData(String)

        public var errorDescription: String? {
            switch self {
            case .notGGUF: "This file is not in GGUF format."
            case .unsupportedVersion(let version): "Unsupported GGUF version \(version)."
            case .truncated: "The GGUF header is incomplete — the download may not have finished."
            case .invalidData(let reason): "The GGUF header is invalid: \(reason)"
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

        guard tensorCount <= UInt64(Limits.tensors) else {
            throw ReadError.invalidData("tensor count exceeds the parser limit")
        }
        guard kvCount <= UInt64(Limits.metadataEntries), let entryCount = Int(exactly: kvCount)
        else {
            throw ReadError.invalidData("metadata entry count exceeds the parser limit")
        }

        var values: [String: Value] = [:]
        values.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            let key = try cursor.string()
            values[key] = try cursor.value()
        }

        // The tensor table follows the metadata. Summing the element counts gives the exact
        // parameter total — worth the extra pass, because without it an imported model has no
        // parameter count at all and the planner sizes its weights at zero.
        let parameterCount = try cursor.tensorParameterCount(Int(tensorCount))

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
        let safeFallback = fallback.flatMap { $0.isValidForPlanning ? $0 : nil }
        guard let blockCount = metadata.integer("block_count"),
              let embeddingLength = metadata.integer("embedding_length"),
              let headCount = metadata.integer("attention.head_count")
        else { return safeFallback }

        var moe: MoEShape?
        if metadata.values["\(metadata.architecture).expert_count"] != nil {
            guard let expertCount = metadata.integer("expert_count"), expertCount > 0 else {
                return safeFallback
            }
            let expertFFN = metadata.integer("expert_feed_forward_length")
                ?? metadata.integer("feed_forward_length") ?? 0
            let used = metadata.integer("expert_used_count") ?? 8
            // Some architectures keep early blocks dense. When the header does not say, assume
            // every block is MoE, which is the conservative direction for memory planning.
            let denseLayers = metadata.integer("leading_dense_block_count") ?? 0
            let (moeLayers, layerOverflow) = blockCount.subtractingReportingOverflow(denseLayers)
            guard !layerOverflow else { return safeFallback }
            moe = MoEShape(
                expertCount: expertCount,
                expertsUsedPerToken: used,
                expertFeedForwardLength: expertFFN,
                moeLayerCount: moeLayers,
                activeParameters: fallback?.moe?.activeParameters ?? 0,
                hasSharedExpert: (metadata.integer("expert_shared_count") ?? 0) > 0
            )
        }

        let shape = ModelShape(
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
        return shape.isValidForPlanning ? shape : safeFallback
    }

    // MARK: - Binary cursor

    private struct Cursor {
        let data: Data
        var offset: Int = 0
        var remainingVariableValues = Limits.variableValues

        mutating func require(_ count: Int) throws -> Range<Int> {
            guard count >= 0, offset >= 0, offset <= data.count else {
                throw ReadError.invalidData("negative or invalid byte range")
            }
            guard count <= data.count - offset else { throw ReadError.truncated }
            guard offset <= Limits.headerBytes, count <= Limits.headerBytes - offset else {
                throw ReadError.invalidData("header exceeds the parser byte limit")
            }
            let start = data.index(data.startIndex, offsetBy: offset)
            let end = data.index(start, offsetBy: count)
            offset += count
            return start..<end
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
            let rawLength = try uint64()
            guard rawLength <= UInt64(Limits.stringBytes), let length = Int(exactly: rawLength)
            else { throw ReadError.invalidData("string exceeds the parser limit") }
            let range = try require(length)
            guard let value = String(data: data[range], encoding: .utf8) else {
                throw ReadError.invalidData("string is not valid UTF-8")
            }
            return value
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
            return try value(ofType: type, depth: 0)
        }

        mutating func value(ofType type: UInt32, depth: Int) throws -> Value {
            switch type {
            case 0: return Value.integer(Int64(data[try require(1)].first ?? 0))
            case 1: return Value.integer(Int64(Int8(bitPattern: data[try require(1)].first ?? 0)))
            case 2:
                return Value.integer(Int64(data[try require(2)].withUnsafeBytes {
                    $0.loadUnaligned(as: UInt16.self)
                }))
            case 3:
                return Value.integer(Int64(data[try require(2)].withUnsafeBytes {
                    $0.loadUnaligned(as: Int16.self)
                }))
            case 4: return Value.integer(Int64(try uint32()))
            case 5: return Value.integer(Int64(Int32(bitPattern: try uint32())))
            case 6: return Value.double(Double(Float(bitPattern: try uint32())))
            case 7: return Value.boolean((data[try require(1)].first ?? 0) != 0)
            case 8: return Value.string(try string())
            case 9: return try array(depth: depth)
            case 10:
                let value = try uint64()
                guard let integer = Int64(exactly: value) else {
                    throw ReadError.invalidData("unsigned integer is not representable")
                }
                return .integer(integer)
            case 11: return Value.integer(Int64(bitPattern: try uint64()))
            case 12: return Value.double(Double(bitPattern: try uint64()))
            default: throw ReadError.invalidData("unsupported metadata value type \(type)")
            }
        }

        /// Walks the tensor table, summing each tensor's element count.
        ///
        /// Each entry is: name, `n_dims` (u32), that many u64 dimensions, a ggml type (u32) and
        /// a u64 data offset. Only the dimensions matter here.
        mutating func tensorParameterCount(_ count: Int) throws -> Int64 {
            var total: Int64 = 0
            for _ in 0..<count {
                _ = try string()
                let dimensionCount = try uint32()
                guard dimensionCount <= Limits.tensorDimensions else {
                    throw ReadError.invalidData("tensor dimension count exceeds the parser limit")
                }
                var elements: Int64 = 1
                for _ in 0..<dimensionCount {
                    let rawDimension = try uint64()
                    guard let dimension = Int64(exactly: rawDimension) else {
                        throw ReadError.invalidData("tensor dimension is not representable")
                    }
                    let (product, overflow) = elements.multipliedReportingOverflow(by: dimension)
                    guard !overflow, product <= ModelShape.maximumParameterCount else {
                        throw ReadError.invalidData("tensor element count exceeds the parser limit")
                    }
                    elements = product
                }
                _ = try uint32()      // ggml type
                _ = try uint64()      // offset
                let (newTotal, overflow) = total.addingReportingOverflow(elements)
                guard !overflow, newTotal <= ModelShape.maximumParameterCount else {
                    throw ReadError.invalidData("total parameter count exceeds the parser limit")
                }
                total = newTotal
            }
            return total
        }

        /// Skips over an array's payload without materializing it.
        mutating func array(depth: Int) throws -> Value {
            guard depth < Limits.arrayNestingDepth else {
                throw ReadError.invalidData("array nesting exceeds the parser limit")
            }
            let elementType = try uint32()
            let rawCount = try uint64()
            guard rawCount <= UInt64(Limits.arrayElements), let count = Int(exactly: rawCount)
            else { throw ReadError.invalidData("array element count exceeds the parser limit") }
            if let width = Self.scalarWidth(elementType) {
                guard count <= Int.max / width else {
                    throw ReadError.invalidData("array byte count is not representable")
                }
                _ = try require(width * count)      // one bounds-checked jump
            } else {
                guard elementType == 8 || elementType == 9 else {
                    throw ReadError.invalidData("unsupported array element type \(elementType)")
                }
                guard count <= remainingVariableValues else {
                    throw ReadError.invalidData("aggregate array work exceeds the parser limit")
                }
                remainingVariableValues -= count
                // Strings and nested arrays are variable-width and must be walked.
                for _ in 0..<count { _ = try value(ofType: elementType, depth: depth + 1) }
            }
            return .arrayOfCount(count)
        }
    }
}
