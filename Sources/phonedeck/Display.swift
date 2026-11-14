import AppKit
import CGVirtualDisplayPrivate
import CoreImage
import ScreenCaptureKit

/// Creates a software display that macOS treats like a real monitor.
/// It exists only while this object is alive.
final class VirtualDisplay {
    let display: CGVirtualDisplay
    var displayID: CGDirectDisplayID { display.displayID }

    init?(name: String, width: UInt32, height: UInt32, hiDPI: Bool) {
        let desc = CGVirtualDisplayDescriptor()
        desc.queue = DispatchQueue.main
        desc.name = name
        let scale: UInt32 = hiDPI ? 2 : 1
        desc.maxPixelsWide = width * scale
        desc.maxPixelsHigh = height * scale
        // iPhone 4S panel: 3.5" diagonal, ~74.9 x 49.9 mm in landscape.
        desc.sizeInMillimeters = CGSize(width: 75, height: 50)
        desc.vendorID = 0x1234
        desc.productID = 0x4545
        desc.serialNum = 0x0001
        desc.terminationHandler = { _, _ in print("Virtual display terminated by the system") }

        guard let display = CGVirtualDisplay(descriptor: desc) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: width, height: height, refreshRate: 60)]
        guard display.apply(settings) else { return nil }
        self.display = display
        makeExtended()
    }

    /// macOS may attach a new display as a mirror (dragging the real monitor down to 960x640).
    /// Force "extend" mode and park the phone screen to the right of the main display.
    func makeExtended() {
        let id = displayID
        for attempt in 0..<10 {
            var count: UInt32 = 0
            CGGetOnlineDisplayList(0, nil, &count)
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetOnlineDisplayList(count, &ids, &count)
            let others = ids.filter { $0 != id }
            let mirrored = CGDisplayIsInMirrorSet(id) != 0 || others.contains { CGDisplayIsInMirrorSet($0) != 0 }
            let main = others.first { CGDisplayIsMain($0) != 0 } ?? others.first

            var cfg: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
            for d in [id] + others where CGDisplayIsInMirrorSet(d) != 0 {
                CGConfigureDisplayMirrorOfDisplay(cfg, d, kCGNullDirectDisplay)
            }
            if let main {
                let b = CGDisplayBounds(main)
                CGConfigureDisplayOrigin(cfg, main, 0, 0)  // keep the real monitor as the origin/main display
                CGConfigureDisplayOrigin(cfg, id, Int32(b.width), 0)
            }
            CGCompleteDisplayConfiguration(cfg, .forSession)
            if !mirrored && attempt > 0 { return }
            usleep(200_000)
        }
    }
}

/// Captures one display with ScreenCaptureKit and encodes each frame as JPEG.
final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "capture")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let quality: Double
    private let lock = NSLock()
    private var _latest: Data?
    var onFrame: ((Data) -> Void)?

    var latest: Data? { lock.lock(); defer { lock.unlock() }; return _latest }

    init(quality: Double) { self.quality = quality }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        // A freshly created virtual display can take a moment to show up in shareable content.
        var scDisplay: SCDisplay?
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            scDisplay = content.displays.first { $0.displayID == displayID }
            if scDisplay != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let scDisplay else {
            throw NSError(domain: "phonedeck", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Display \(displayID) not visible to ScreenCaptureKit"])
        }

        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = true
        cfg.queueDepth = 3

        let stream = SCStream(filter: SCContentFilter(display: scDisplay, excludingWindows: []),
                              configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let pixelBuffer = sb.imageBuffer else { return }
        // Skip idle/blank status frames; only "complete" frames carry new pixels.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let opts = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        guard let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: opts) else { return }
        lock.lock(); _latest = jpeg; lock.unlock()
        onFrame?(jpeg)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Capture stopped: \(error.localizedDescription)")
    }
}
