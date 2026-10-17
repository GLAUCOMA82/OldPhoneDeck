import AVFoundation
import CoreAudio
import Network

/// Receives camera + mic from the PhoneCam iOS app on port+1.
/// Wire format per message: 1 byte type | 4 bytes big-endian length | payload.
///   'H' token  ·  'V' JPEG frame  ·  'A' 16 kHz mono s16le PCM
final class PhoneMediaServer {
    // Receives camera + mic from a modern iPhone's browser over a secure WebSocket.
    // Each binary message: 1 type byte + payload.  'H' token  ·  'V' JPEG frame  ·  'A' 16 kHz mono s16le PCM
    private let queue = DispatchQueue(label: "phone-media")
    private let token: String
    private let audio: AudioOut?
    private let lock = NSLock()
    private var _latestFrame: Data?
    private var _lastFrameAt = Date.distantPast
    private var wsListener: NWListener?
    var onFrame: ((Data) -> Void)?

    var latestFrame: Data? { lock.lock(); defer { lock.unlock() }; return _latestFrame }
    var isLive: Bool { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(_lastFrameAt) < 2 }

    init(token: String, audio: AudioOut?) {
        self.token = token
        self.audio = audio
    }

    func handle(type: UInt8, payload: Data) {
        switch type {
        case UInt8(ascii: "V"):
            lock.lock(); _latestFrame = payload; _lastFrameAt = Date(); lock.unlock()
            onFrame?(payload)
        case UInt8(ascii: "A"):
            audio?.play(pcm16: payload)
        default:
            break
        }
    }

    func startWebSocket(port: UInt16, identity: sec_identity_t) throws {
        let ws = try NWListener(using: LocalTLS.parameters(identity, websocket: true), on: NWEndpoint.Port(rawValue: port)!)
        ws.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        ws.start(queue: queue)
        wsListener = ws
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        var authed = false
        func receive() {
            conn.receiveMessage { [weak self] data, _, _, error in
                guard let self, error == nil else {
                    if authed { print("Phone stopped streaming") }
                    return conn.cancel()
                }
                if let data, let type = data.first {
                    let payload = data.dropFirst()
                    if !authed {
                        guard type == UInt8(ascii: "H"), String(data: payload, encoding: .utf8) == self.token else {
                            print("Stream: rejected a bad token")
                            return conn.cancel()
                        }
                        authed = true
                        print("Phone streaming from \(conn.endpoint)")
                    } else {
                        self.handle(type: type, payload: Data(payload))
                    }
                }
                receive()
            }
        }
        receive()
    }
}

/// Plays the phone's mic into an output device — normally the BlackHole virtual device,
/// so other apps can pick "BlackHole 2ch" as their microphone.
final class AudioOut {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var queuedFrames = 0
    let deviceName: String

    /// Returns nil (and explains why) if no output device matches `deviceMatch`.
    init?(deviceMatch: String) {
        guard let (id, name) = AudioOut.findOutputDevice(matching: deviceMatch) else {
            print("⚠️  No audio device matching \"\(deviceMatch)\" — install BlackHole 2ch to use the phone as a mic.")
            return nil
        }
        deviceName = name
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        var devID = id
        guard let unit = engine.outputNode.audioUnit,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &devID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            print("⚠️  Could not route audio to \(name)")
            return nil
        }
        do { try engine.start() } catch { print("⚠️  Audio engine failed: \(error)"); return nil }
        player.play()
    }

    func play(pcm16 data: Data) {
        let frames = data.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        lock.lock()
        // Keep latency bounded: if more than ~250 ms is queued (Wi-Fi hiccup), drop this chunk.
        if queuedFrames > 4000 { lock.unlock(); return }
        queuedFrames += frames
        lock.unlock()
        buf.frameLength = AVAudioFrameCount(frames)
        let out = buf.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: s[i])) / 32768 }
        }
        player.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.queuedFrames -= frames; self.lock.unlock()
        }
    }

    static func findOutputDevice(matching match: String) -> (AudioDeviceID, String)? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        for id in ids {
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name) == noErr,
                  let n = name?.takeRetainedValue() as String?,
                  n.localizedCaseInsensitiveContains(match) else { continue }
            // Must be able to output audio.
            var streamsAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                         mScope: kAudioDevicePropertyScopeOutput,
                                                         mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize)
            if streamsSize > 0 { return (id, n) }
        }
        return nil
    }
}
