import AVFoundation
import CoreAudio
import Network

/// Receives camera + mic from the PhoneCam iOS app on port+1.
/// Wire format per message: 1 byte type | 4 bytes big-endian length | payload.
///   'H' token  ·  'V' JPEG frame  ·  'A' 16 kHz mono s16le PCM
final class PhoneMediaServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "phone-media")
    private let token: String
    private var audio: AudioOut?          // guarded by lock
    private let micDevice: String
    private var lastAudioAttempt = Date()
    private var _audioChunks = 0
    private var _lastAudioAt = Date.distantPast
    private var recentPCM = Data()        // the last 10 s of mic audio, for /mic.wav
    private let lock = NSLock()
    private var _latestFrame: Data?
    private var _lastFrameAt = Date.distantPast
    var onFrame: ((Data) -> Void)?

    var latestFrame: Data? { lock.lock(); defer { lock.unlock() }; return _latestFrame }
    /// True while frames are arriving (used by /info so the phone UI can show "live").
    var isLive: Bool { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(_lastFrameAt) < 2 }

    /// `micDevice`: part of the name of the output device that receives the phone's mic (normally "BlackHole").
    init(port: UInt16, token: String, micDevice: String) throws {
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        self.token = token
        self.micDevice = micDevice
        audio = AudioOut(deviceMatch: micDevice)
    }

    /// The last 10 seconds of the phone's mic exactly as received (16 kHz mono), as a WAV file: a way to hear
    /// what the phone sends, separately from BlackHole and the app that listens to it.
    var recentMicWAV: Data {
        lock.lock(); let pcm = Data(recentPCM); lock.unlock()
        var wav = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + pcm.count)); wav.append(contentsOf: Array("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(16000)); le(UInt32(32000)); le(UInt16(2)); le(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); le(UInt32(pcm.count)); wav.append(pcm)
        return wav
    }

    /// For /info: which device the phone's mic plays into ("" if none was found) and whether audio is arriving.
    var micStatus: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var status: [String: Any] = ["device": audio?.deviceName ?? "", "receiving": Date().timeIntervalSince(_lastAudioAt) < 2, "chunks": _audioChunks]
        audio?.status.forEach { status[$0] = $1 }
        return status
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
    }

    /// Video/audio from either transport (PhoneCam TCP or the browser's WebSocket).
    func handle(type: UInt8, payload: Data) {
        switch type {
        case UInt8(ascii: "V"):
            lock.lock(); _latestFrame = payload; _lastFrameAt = Date(); lock.unlock()
            onFrame?(payload)
        case UInt8(ascii: "A"):
            lock.lock()
            _audioChunks += 1; _lastAudioAt = Date()
            recentPCM.append(payload)
            if recentPCM.count > 320_000 { recentPCM.removeFirst(recentPCM.count - 320_000) }
            // The device can be missing when PhoneDeck starts (opened at login before the audio system has
            // loaded BlackHole, or BlackHole installed later), so look for it again while audio is arriving.
            if audio == nil, Date().timeIntervalSince(lastAudioAttempt) > 5 {
                lastAudioAttempt = Date()
                audio = AudioOut(deviceMatch: micDevice, quiet: true)
                if let audio { print("Phone mic now plays into \(audio.deviceName)") }
            }
            let out = audio
            lock.unlock()
            out?.play(pcm16: payload)
        default:
            break
        }
    }

    /// Same messages over a secure WebSocket, for modern iPhones streaming from Safari:
    /// each binary message is 1 type byte + payload (WebSocket framing replaces the length).
    func startWebSocket(port: UInt16, identity: sec_identity_t) throws {
        let ws = try NWListener(using: LocalTLS.parameters(identity, websocket: true), on: NWEndpoint.Port(rawValue: port)!)
        ws.newConnectionHandler = { [weak self] conn in self?.acceptWebSocket(conn) }
        ws.start(queue: queue)
        wsListener = ws
    }
    private var wsListener: NWListener?

    private func acceptWebSocket(_ conn: NWConnection) {
        conn.start(queue: queue)
        var authed = false
        func receive() {
            conn.receiveMessage { [weak self] data, _, _, error in
                guard let self, error == nil else {
                    if authed { print("iPhone (browser) stopped streaming") }
                    return conn.cancel()
                }
                if let data, let type = data.first {
                    let payload = data.dropFirst()
                    if !authed {
                        guard type == UInt8(ascii: "H"), String(data: payload, encoding: .utf8) == self.token else {
                            print("Browser stream: rejected a bad token")
                            return conn.cancel()
                        }
                        authed = true
                        print("iPhone (browser) streaming from \(conn.endpoint)")
                    } else {
                        self.handle(type: type, payload: Data(payload))
                    }
                }
                receive()
            }
        }
        receive()
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        var authed = false
        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
                guard let self else { return conn.cancel() }
                if let data { buffer.append(data) }
                while buffer.count >= 5 {
                    let b = buffer.startIndex
                    let type = buffer[b]
                    let len = Int(buffer[b + 1]) << 24 | Int(buffer[b + 2]) << 16 | Int(buffer[b + 3]) << 8 | Int(buffer[b + 4])
                    guard len < 8 << 20 else { return conn.cancel() }
                    guard buffer.count >= 5 + len else { break }
                    let payload = buffer.subdata(in: (b + 5)..<(b + 5 + len))
                    buffer.removeSubrange(b..<(b + 5 + len))
                    if !authed {
                        guard type == UInt8(ascii: "H"), String(data: payload, encoding: .utf8) == self.token else {
                            print("PhoneCam: rejected connection with a bad token")
                            return conn.cancel()
                        }
                        authed = true
                        print("PhoneCam connected from \(conn.endpoint)")
                        continue
                    }
                    self.handle(type: type, payload: payload)
                }
                if done || error != nil {
                    if authed { print("PhoneCam disconnected") }
                    return conn.cancel()
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
    private var inputPeak: Float = 0       // loudest sample in the phone audio received lately (0–1)
    private var outputPeak: Float = 0      // loudest sample the engine handed to the device lately
    private var lastRender = Date.distantPast
    private var restarts = 0
    private var deviceID: AudioDeviceID = 0
    let deviceName: String

    /// Points the engine's output at our device. The engine can fall back to the default output when it reconfigures.
    private func routeToDevice() -> Bool {
        var devID = deviceID
        guard let unit = engine.outputNode.audioUnit else { return false }
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &devID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }
    private var routedDevice: AudioDeviceID {
        var devID: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard let unit = engine.outputNode.audioUnit else { return 0 }
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID, &size)
        return devID
    }

    /// For /info: is the engine running, and how loud is the audio coming in and going out.
    var status: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let s: [String: Any] = ["engineRunning": engine.isRunning, "rendering": Date().timeIntervalSince(lastRender) < 1,
                                "inputPeak": Double((inputPeak * 1000).rounded() / 1000), "outputPeak": Double((outputPeak * 1000).rounded() / 1000),
                                "queuedFrames": queuedFrames, "restarts": restarts, "onDevice": routedDevice == deviceID,
                                "outputFormat": "\(engine.outputNode.outputFormat(forBus: 0))"]
        inputPeak = 0; outputPeak = 0
        return s
    }

    /// Returns nil (and explains why) if no output device matches `deviceMatch`.
    init?(deviceMatch: String, quiet: Bool = false) {
        guard let (id, name) = AudioOut.findOutputDevice(matching: deviceMatch) else {
            if !quiet { print("⚠️  No audio device matching \"\(deviceMatch)\" — install BlackHole 2ch to use the phone as a mic.") }
            return nil
        }
        deviceName = name
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        deviceID = id
        guard routeToDevice() else {
            print("⚠️  Could not route audio to \(name)")
            return nil
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            var peak: Float = 0
            for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[i])) }
            self.lock.lock(); self.outputPeak = max(self.outputPeak, peak); self.lastRender = Date(); self.lock.unlock()
        }
        do { try engine.start() } catch { print("⚠️  Audio engine failed: \(error)"); return nil }
        player.play()
        // macOS stops the engine whenever the audio setup changes (another app starts using a device, a sample
        // rate changes, headphones are plugged in). Start it again, or the phone's mic goes silent for good.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.queuedFrames = 0; self.restarts += 1; self.lock.unlock()
            self.player.stop()
            if self.routedDevice != self.deviceID { _ = self.routeToDevice() }
            do { try self.engine.start(); self.player.play() } catch { print("⚠️  Audio engine restart failed: \(error)") }
        }
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
            var peak: Float = 0
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: s[i])) / 32768; peak = max(peak, abs(out[i])) }
            lock.lock(); inputPeak = max(inputPeak, peak); lock.unlock()
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
