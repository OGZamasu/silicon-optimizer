import AudioToolbox
import AVFoundation
import Foundation
import Observation

/// Plays audio as it arrives from a `…/stream` operation, and stops when told.
///
/// MP3 (ElevenLabs' default) is split into packets by AudioFileStream and decoded as each
/// packet lands; raw `pcm_<rate>` is converted directly. Either way the sound starts with the
/// first chunk rather than the last. Other formats (μ-law, A-law, Opus) are not played live —
/// the collected file is still kept.
@MainActor
@Observable
final class ElevenLabsStreamPlayer {
    private(set) var isPlaying = false
    private(set) var receivedBytes = 0
    /// Why nothing is playing, when the format cannot be played live.
    private(set) var problem: String?

    @ObservationIgnored private let engine: ElevenLabsStreamEngine?
    @ObservationIgnored private var finished = false

    /// - Parameter outputFormat: The operation's `output_format` argument, when given:
    ///   `mp3_44100_128` (the default), `pcm_24000`…
    init(outputFormat: String? = nil) {
        let format = (outputFormat ?? "mp3").lowercased()
        let decoder: (any ElevenLabsStreamDecoding)?
        if format.hasPrefix("mp3") {
            decoder = ElevenLabsMP3StreamDecoder()
        } else if format.hasPrefix("pcm_"), let rate = Double(format.dropFirst(4).prefix { $0.isNumber }), rate > 0 {
            decoder = ElevenLabsPCMStreamDecoder(sampleRate: rate)
        } else {
            decoder = nil
        }
        if let decoder {
            engine = ElevenLabsStreamEngine(decoder: decoder)
        } else {
            engine = nil
            problem = "\(outputFormat ?? "This format") cannot be played as it arrives; it is kept to play when done."
        }
        engine?.onPlaying = { [weak self] playing in
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    /// The next piece of audio, in arrival order.
    func append(_ data: Data) {
        guard !finished else { return }
        receivedBytes += data.count
        engine?.feed(data)
    }

    /// The stream ended: whatever has not played yet plays out.
    func finish() {
        guard !finished else { return }
        finished = true
        engine?.finish()
    }

    /// Silence, at once.
    func stop() {
        finished = true
        engine?.stop()
        isPlaying = false
    }
}

/// Turns arriving bytes into PCM buffers.
protocol ElevenLabsStreamDecoding: AnyObject {
    /// Called with each decoded buffer, on the engine's queue.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    func feed(_ data: Data)
}

/// Owns the audio engine for one stream. Everything happens on its own serial queue, never
/// the main thread: decoding a chunk must not stall the window.
final class ElevenLabsStreamEngine: @unchecked Sendable {
    var onPlaying: (@Sendable (Bool) -> Void)?

    private let queue = DispatchQueue(label: "dev.siliconoptimizer.elevenlabs.stream")
    private let decoder: any ElevenLabsStreamDecoding
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var pending = 0
    private var ended = false
    private var stopped = false

    init(decoder: any ElevenLabsStreamDecoding) {
        self.decoder = decoder
        decoder.onBuffer = { [unowned self] buffer in self.schedule(buffer) }
    }

    func feed(_ data: Data) {
        queue.async { [self] in
            guard !stopped else { return }
            decoder.feed(data)
        }
    }

    func finish() {
        queue.async { [self] in
            ended = true
            if pending == 0 { tearDown() }
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            tearDown()
        }
    }

    /// On the queue.
    private func schedule(_ buffer: AVAudioPCMBuffer) {
        guard !stopped, buffer.frameLength > 0 else { return }
        if engine == nil {
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
            do {
                try engine.start()
            } catch {
                stopped = true
                return
            }
            node.play()
            self.engine = engine
            self.node = node
            onPlaying?(true)
        }
        pending += 1
        node?.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.pending -= 1
                if self.ended, self.pending == 0 { self.tearDown() }
            }
        }
    }

    private func tearDown() {
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
        onPlaying?(false)
    }
}

/// MP3 packets from AudioFileStream, decoded with AVAudioConverter.
final class ElevenLabsMP3StreamDecoder: ElevenLabsStreamDecoding {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var stream: AudioFileStreamID?
    private var sourceFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    /// Once parsing fails the rest of the stream is ignored rather than fed to a parser in an
    /// unknown state.
    private var failed = false

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioFileStreamOpen(
            context,
            { context, stream, property, _ in
                Unmanaged<ElevenLabsMP3StreamDecoder>.fromOpaque(context).takeUnretainedValue()
                    .propertyChanged(stream, property)
            },
            { context, byteCount, packetCount, bytes, descriptions in
                Unmanaged<ElevenLabsMP3StreamDecoder>.fromOpaque(context).takeUnretainedValue()
                    .packets(byteCount, packetCount, bytes, descriptions)
            },
            kAudioFileMP3Type, &stream
        )
        if status != noErr { failed = true }
    }

    deinit {
        if let stream { AudioFileStreamClose(stream) }
    }

    func feed(_ data: Data) {
        guard !failed, let stream, !data.isEmpty else { return }
        let status = data.withUnsafeBytes { raw in
            AudioFileStreamParseBytes(stream, UInt32(raw.count), raw.baseAddress, [])
        }
        if status != noErr { failed = true }
    }

    private func propertyChanged(_ stream: AudioFileStreamID, _ property: AudioFileStreamPropertyID) {
        guard property == kAudioFileStreamProperty_ReadyToProducePackets else { return }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &description) == noErr,
              let source = AVAudioFormat(streamDescription: &description),
              let output = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: description.mSampleRate,
                  channels: max(1, description.mChannelsPerFrame), interleaved: false
              ),
              let converter = AVAudioConverter(from: source, to: output)
        else {
            failed = true
            return
        }
        sourceFormat = source
        outputFormat = output
        self.converter = converter
    }

    private func packets(
        _ byteCount: UInt32, _ packetCount: UInt32, _ bytes: UnsafeRawPointer,
        _ descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        guard let sourceFormat, let outputFormat, let converter, let descriptions, packetCount > 0 else { return }
        var largest: UInt32 = 0
        for index in 0..<Int(packetCount) { largest = max(largest, descriptions[index].mDataByteSize) }
        let compressed = AVAudioCompressedBuffer(
            format: sourceFormat, packetCapacity: packetCount, maximumPacketSize: Int(max(largest, 1))
        )
        compressed.data.copyMemory(from: bytes, byteCount: Int(byteCount))
        compressed.byteLength = byteCount
        compressed.packetCount = packetCount
        compressed.packetDescriptions?.update(from: descriptions, count: Int(packetCount))

        let framesPerPacket = max(sourceFormat.streamDescription.pointee.mFramesPerPacket, 1152)
        guard let pcm = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(packetCount) * framesPerPacket
        ) else { return }
        // The input block runs inside `convert`, on this thread, before it returns; the box
        // only tells the compiler what the documentation already says.
        let input = ConverterInput(compressed)
        var error: NSError?
        converter.convert(to: pcm, error: &error) { _, status in
            guard let buffer = input.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
        if error == nil { onBuffer?(pcm) }
    }

    /// One compressed buffer, handed to the converter once.
    private final class ConverterInput: @unchecked Sendable {
        private var buffer: AVAudioCompressedBuffer?
        init(_ buffer: AVAudioCompressedBuffer) { self.buffer = buffer }
        func take() -> AVAudioCompressedBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }
}

/// Raw 16-bit little-endian mono PCM at a known rate, as `pcm_<rate>` sends it.
final class ElevenLabsPCMStreamDecoder: ElevenLabsStreamDecoding {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private let format: AVAudioFormat?
    /// An odd byte left from the last chunk: samples may straddle chunk boundaries.
    private var carry: UInt8?

    init(sampleRate: Double) {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    func feed(_ data: Data) {
        guard let format else { return }
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count + 1)
        if let carry { bytes.append(carry) }
        bytes.append(contentsOf: data)
        carry = bytes.count % 2 == 1 ? bytes.removeLast() : nil
        let samples = bytes.count / 2
        guard samples > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples)),
              let channel = buffer.floatChannelData?[0] else { return }
        for index in 0..<samples {
            let value = Int16(bitPattern: UInt16(bytes[2 * index]) | UInt16(bytes[2 * index + 1]) << 8)
            channel[index] = Float(value) / 32_768
        }
        buffer.frameLength = AVAudioFrameCount(samples)
        onBuffer?(buffer)
    }
}
