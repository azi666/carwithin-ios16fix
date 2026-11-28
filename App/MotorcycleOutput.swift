import CoreImage
import Foundation
import ImageIO
import VideoToolbox

final class MotorcycleOutput {
    private let queue: DispatchQueue
    private var session: Session?

    init(name: String = "cfmoto") {
        queue = DispatchQueue(label: "CarWithin.\(name)", qos: .userInitiated)
    }

    deinit { stop() }

    func start(localAddress: String, targetAddress: String, device: UUID?, profile: MotorcycleProfile,
               eryaVideoPort: UInt16 = 11111, eryaControlPort: UInt16 = 11113,
               onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
               requestKeyframe: @escaping () -> Void) {
        stop()
        let next = Session(queue: queue, localAddress: localAddress, targetAddress: targetAddress,
                           device: device, profile: profile, eryaVideoPort: eryaVideoPort, eryaControlPort: eryaControlPort,
                           onState: onState, onLog: onLog, requestKeyframe: requestKeyframe)
        session = next
        next.start()
    }

    func append(_ data: Data, codec: VideoCodec, keyframe: Bool) {
        guard codec == .h264 else { return }
        session?.append(data, keyframe: keyframe)
    }

    func stop() {
        guard let previous = session else { return }
        session = nil
        previous.cancel()
        queue.async { previous.close() }
    }

    private final class Session: @unchecked Sendable {
        let queue: DispatchQueue
        let profile: MotorcycleProfile
        let onState: (String) -> Void
        let onLog: (String) -> Void
        let requestKeyframe: () -> Void
        private let lock = NSLock()
        private var cancelled = false
        private var acceptingFrames = true
        private var queued = 0
        private var skipping = false
        private var decoded: CVPixelBuffer?
        private var decodeError: Error?
        private var encoded: Result<H264EncodedFrame, Error>?

        private var encodeWidth: Int
        private var encodeHeight: Int
        private let erya: EryaConnection?
        private let eryaVideoPort: UInt16
        private let eryaControlPort: UInt16
        private let yunmo: YunmoConnection?
        private let thinker: ThinkerRideConnection?
        private let shouqu: ShouquConnection?
        private let localAddress: String
        private let targetAddress: String
        private let device: UUID?
        private var decoder: TailingH264Decoder?
        private var encoder: H264Encoder?
        private var parameters = VideoParameterSets(codec: .h264)
        private var waitingForIDR = true
        private var latest: CVPixelBuffer?
        private lazy var compositor = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        private var lastKeyframe = -Double.infinity
        private var lastCodecFailure = -Double.infinity
        private var status = ""

        init(queue: DispatchQueue, localAddress: String, targetAddress: String, device: UUID?,
             profile: MotorcycleProfile, eryaVideoPort: UInt16, eryaControlPort: UInt16, onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
             requestKeyframe: @escaping () -> Void) {
            self.queue = queue
            self.eryaVideoPort = eryaVideoPort; self.eryaControlPort = eryaControlPort
            self.erya = profile.transport == .erya ? EryaConnection(log: onLog) : nil
            self.profile = profile
            self.encodeWidth = profile.width
            self.encodeHeight = profile.height
            self.localAddress = localAddress; self.targetAddress = targetAddress; self.device = device
            self.yunmo = profile.transport == .yunmo ? YunmoConnection(log: onLog) : nil
            self.thinker = profile.transport == .thinkerRide ? ThinkerRideConnection(profile: profile, log: onLog) : nil
            self.shouqu = profile.transport == .shouqu ? ShouquConnection(local: localAddress, target: targetAddress, log: onLog) : nil
            self.onState = onState
            self.onLog = onLog
            self.requestKeyframe = requestKeyframe
        }

        func start() {
            report("正在连接\(profile.title)仪表…")
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    let size: (Int, Int)
                    if let erya { size = try erya.start(local: localAddress, target: targetAddress, videoPort: eryaVideoPort, controlPort: eryaControlPort) }
                    else if let shouqu { size = try shouqu.start() }
                    else if let yunmo { size = try yunmo.start(local: localAddress, target: targetAddress) }
                    else if let thinker, let device { size = try thinker.start(local: localAddress, target: targetAddress, device: device) }
                    else { throw ConfigurationError(CWL("请先扫描并选择仪表蓝牙。")) }
                    guard active else { return }
                    encodeWidth = size.0; encodeHeight = size.1
                    report("仪表已连接，等待 CarPlay 画面…")
                    var first = true
                    var nextFrame = ProcessInfo.processInfo.systemUptime
                    while active {
                        try erya?.checkHealth(); try yunmo?.checkHealth(); try thinker?.checkHealth(); try shouqu?.checkHealth()
                        let ready = queue.sync { latest != nil }
                        if !ready { Thread.sleep(forTimeInterval: 0.05); continue }
                        let remaining = nextFrame - ProcessInfo.processInfo.systemUptime
                        if remaining > 0 { Thread.sleep(forTimeInterval: min(remaining, 0.04)); continue }
                        nextFrame = ProcessInfo.processInfo.systemUptime + 1.0 / Double(profile.fps)
                        guard active else { break }
                        if yunmo != nil || shouqu != nil || erya != nil {
                            try yunmo?.waitWritable(); try erya?.waitWritable()
                            let jpeg: Data? = try queue.sync {
                                guard active, let image = latest else { return nil }
                                let fitted = try fittedImage(image)
                                let qualities: [Double] = shouqu == nil ? [0.6] : [0.65, 0.5, 0.35, 0.2]
                                for quality in qualities {
                                    if let data = compositor.jpegRepresentation(of: CIImage(cvPixelBuffer: fitted),
                                        colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]),
                                       shouqu == nil || data.count <= ShouquProtocol.maximumJPEGBytes { return data }
                                }
                                return nil
                            }
                            guard let jpeg else { continue }
                            try erya?.send(jpeg); try yunmo?.send(jpeg); try shouqu?.send(jpeg)
                            report("正在投屏 · \(encodeWidth)×\(encodeHeight) · JPEG · \(profile.fps) FPS")
                            continue
                        }
                        let result = queue.sync { () -> H264EncodedFrame? in
                            guard active, let image = latest else { return nil }
                            return encode(image, at: ProcessInfo.processInfo.systemUptime, forceKeyframe: first)
                        }
                        guard let result else {
                            // 仪表已经拉帧，这里保留请求，等一帧可编码画面用关键帧补上。
                            var recovered: H264EncodedFrame?
                            for _ in 0..<20 where active && recovered == nil {
                                Thread.sleep(forTimeInterval: 0.05)
                                recovered = queue.sync {
                                    guard let image = latest else { return nil }
                                    return encode(image, at: ProcessInfo.processInfo.systemUptime, forceKeyframe: true)
                                }
                            }
                            guard let recovered else { throw TailingError.timeout("等待 H.264 编码画面") }
                            try thinker?.send(recovered.data)
                            first = false
                            report("正在投屏 · \(encodeWidth)×\(encodeHeight) · H.264")
                            continue
                        }
                        try thinker?.send(result.data)
                        first = false
                        report("正在投屏 · \(encodeWidth)×\(encodeHeight) · H.264")
                    }
                } catch {
                    if active {
                        onLog("\(profile.title)输出失败：\(error.localizedDescription)")
                        report("\(profile.title)连接失败：\(error.localizedDescription)")
                    }
                }
                erya?.close(); yunmo?.close(); thinker?.close(); shouqu?.close()
                queue.async { [self] in close() }
            }
        }

        private var active: Bool { lock.withLock { !cancelled } }

        func cancel() { lock.withLock { cancelled = true }; erya?.close(); yunmo?.close(); thinker?.close(); shouqu?.close() }

        func append(_ data: Data, keyframe: Bool) {
            let (accepted, needsKeyframe) = lock.withLock {
                guard !cancelled, acceptingFrames else { return (false, false) }
                if queued >= 6 {
                    let request = !skipping
                    skipping = true
                    return (false, request)
                }
                guard !skipping || keyframe else { return (false, false) }
                skipping = false
                queued += 1
                return (true, false)
            }
            if needsKeyframe { requestKeyframe() }
            guard accepted else { return }
            queue.async { [self] in
                defer { lock.withLock { queued -= 1 } }
                guard lock.withLock({ !cancelled && acceptingFrames }) else { return }
                decode(data, keyframe: keyframe)
            }
        }

        private func decode(_ data: Data, keyframe: Bool) {
            do {
                var picture: [Data] = []
                for unit in try AnnexB.units(in: data) {
                    if VideoCodec.h264.parameterSet(unit) != nil {
                        if parameters.absorb(unit) { waitingForIDR = true }
                    } else { picture.append(unit) }
                }
                if waitingForIDR {
                    guard parameters.isComplete, keyframe, !picture.isEmpty else { return }
                    guard ProcessInfo.processInfo.systemUptime - lastCodecFailure >= 0.5 else {
                        requestKeyframe()
                        return
                    }
                    decoder?.invalidate()
                    decoder = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
                        output: { [weak self] image in
                            guard let self else { return }
                            self.lock.withLock { self.decoded = image }
                        }, failure: { [weak self] error in
                            guard let self else { return }
                            self.lock.withLock { self.decodeError = error }
                        })
                    waitingForIDR = false
                }
                guard let decoder, !picture.isEmpty else { return }
                try decoder.decode(AnnexB.lengthPrefixed(picture),
                    presentationTimeMicroseconds: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000), isKeyframe: keyframe)
                decoder.waitForFrames()
                let (image, error) = lock.withLock {
                    defer { decoded = nil; decodeError = nil }
                    return (decoded, decodeError)
                }
                if let error { throw error }
                if let image { latest = image }
            } catch {
                decoder?.invalidate()
                decoder = nil
                lock.withLock { decoded = nil; decodeError = nil }
                waitingForIDR = true
                logCodecFailure("解码", error)
                requestKeyframe()
            }
        }

        private func encode(_ image: CVPixelBuffer, at now: Double, forceKeyframe: Bool) -> H264EncodedFrame? {
            do {
                if encoder == nil {
                    guard now - lastCodecFailure >= 0.5 else { return nil }
                    encoder = try H264Encoder(width: encodeWidth, height: encodeHeight,
                                              fps: profile.fps, bitrate: profile.width * profile.height * 3) { [weak self] result in
                        guard let self else { return }
                        self.lock.withLock { self.encoded = result }
                    }
                    lastKeyframe = -.infinity
                }
                guard let encoder else { return nil }
                let stamp = CMTime(seconds: now, preferredTimescale: 1_000_000)
                try encoder.encode(try fittedImage(image), presentationTime: stamp,
                                   forceKeyframe: forceKeyframe || now - lastKeyframe >= 1)
                encoder.complete()
                let result = lock.withLock {
                    defer { encoded = nil }
                    return encoded
                }
                let frame = try result?.get()
                if frame?.isKeyframe == true { lastKeyframe = now }
                return frame
            } catch H264EncoderError.frameDropped {
                return nil
            } catch {
                encoder?.invalidate()
                encoder = nil
                lastKeyframe = -.infinity
                lock.withLock { encoded = nil }
                logCodecFailure("编码", error)
                return nil
            }
        }

        private func fittedImage(_ image: CVPixelBuffer) throws -> CVPixelBuffer {
            let width = encodeWidth, height = encodeHeight
            if CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height { return image }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                             [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else {
                throw ConfigurationError("无法分配\(profile.title)缩放画面（\(status)）")
            }
            let source = CIImage(cvPixelBuffer: image)
            let scale = min(CGFloat(width) / source.extent.width, CGFloat(height) / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: (CGFloat(width) - scaled.extent.width) / 2,
                y: (CGFloat(height) - scaled.extent.height) / 2))
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            compositor.render(positioned.composited(over: CIImage(color: .black)).cropped(to: bounds),
                              to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            return buffer
        }

        private func logCodecFailure(_ stage: String, _ error: Error) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCodecFailure > 4 { onLog("\(profile.title)\(stage)恢复：\(error.localizedDescription)") }
            lastCodecFailure = now
        }

        private func report(_ message: String) {
            guard active, message != status else { return }
            status = message
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                self.onState(message)
            }
        }

        func close() {
            lock.withLock { acceptingFrames = false }
            erya?.close(); yunmo?.close(); thinker?.close(); shouqu?.close()
            decoder?.invalidate()
            decoder = nil
            encoder?.invalidate()
            encoder = nil
            latest = nil
        }
    }
}
