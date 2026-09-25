import Foundation

/// A complete safetensors file of a few bytes: one float32 tensor per name, the header padded
/// to 8 bytes as the format's writers do. Enough for any check that a file is whole, and no
/// weights of anyone's.
func tinySafetensors(tensors: [String] = ["w"]) -> Data {
    var header: [String: Any] = [:]
    for (index, name) in tensors.enumerated() {
        header[name] = ["dtype": "F32", "shape": [1], "data_offsets": [index * 4, index * 4 + 4]]
    }
    var json = try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    json.append(contentsOf: [UInt8](repeating: 0x20, count: (8 - json.count % 8) % 8))
    var data = Data()
    withUnsafeBytes(of: UInt64(json.count).littleEndian) { data.append(contentsOf: $0) }
    data.append(json)
    data.append(Data(count: tensors.count * 4))
    return data
}

/// What `hf download` leaves in one component directory of a sharded repository: an index
/// naming `shards`, and each shard, whole.
func placeShardedComponent(at directory: URL, shards: [String]) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var map: [String: String] = [:]
    for (index, shard) in shards.enumerated() {
        let name = "t\(index)"
        map[name] = shard
        try tinySafetensors(tensors: [name]).write(to: directory.appendingPathComponent(shard))
    }
    let index = try JSONSerialization.data(withJSONObject: [
        "metadata": ["total_size": shards.count * 4], "weight_map": map,
    ])
    try index.write(to: directory.appendingPathComponent("model.safetensors.index.json"))
}
