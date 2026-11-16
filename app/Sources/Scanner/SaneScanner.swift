import Foundation

/// All SANE calls go through one serial queue; SANE is not thread-safe.
enum SaneSession {
    static let queue = DispatchQueue(label: "dualscan.sane", qos: .userInitiated)
    private static var initialized = false

    /// Points SANE at the driver built in ../sane, before the first sane_init.
    static func configure() {
        let dir = String(cString: dualscan_sane_dir())
        setenv("SANE_CONFIG_DIR", dir + "/etc/sane.d", 1)
    }

    /// Looks for a Dual IV. Runs on `queue`. When none is found SANE is shut
    /// down again, so the next call rescans USB.
    static func findDualIV() -> (name: String, model: String)? {
        if !initialized {
            var version: SANE_Int = 0
            guard sane_init(&version, nil) == SANE_STATUS_GOOD else { return nil }
            initialized = true
        }
        var list: UnsafeMutablePointer<UnsafePointer<SANE_Device>?>? = nil
        guard sane_get_devices(&list, SANE_Bool(SANE_FALSE)) == SANE_STATUS_GOOD, let list else { return nil }
        var i = 0
        while let dev = list[i] {
            let model = String(cString: dev.pointee.model)
            let vendor = String(cString: dev.pointee.vendor)
            if model.localizedCaseInsensitiveContains("Dual IV") {
                return (String(cString: dev.pointee.name), "\(vendor) \(model)")
            }
            i += 1
        }
        sane_exit()
        initialized = false
        return nil
    }
}

final class SaneScanner: ScannerDevice, @unchecked Sendable {
    let deviceName: String
    let displayName: String
    private var handle: SANE_Handle?
    private let lock = NSLock()
    private var cancelRequested = false

    private static let capInactive: SANE_Int = 1 << 5

    init(deviceName: String, displayName: String) {
        self.deviceName = deviceName
        self.displayName = displayName
    }

    // MARK: ScannerDevice

    func open() async throws {
        try await onQueue {
            var h: SANE_Handle?
            let st = sane_open(self.deviceName, &h)
            guard st == SANE_STATUS_GOOD, let h else { throw Self.error("Could not open the scanner", st) }
            self.handle = h
        }
    }

    func holderPresent() async -> Bool {
        (try? await onQueue { () -> Bool in
            // Reading the frame option makes the driver sense the holder again;
            // the option is inactive while there is no holder.
            guard let (i, _) = self.option("frame") else { return false }
            var v: SANE_Word = 0
            _ = sane_control_option(self.handle, i, SANE_ACTION_GET_VALUE, &v, nil)
            guard let d = sane_get_option_descriptor(self.handle, i) else { return false }
            return d.pointee.cap & Self.capInactive == 0
        }) ?? false
    }

    func scan(_ request: ScanRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> ScanResult {
        lock.withLock { cancelRequested = false }
        return try await onQueue { try self.scanOnQueue(request, progress: progress) }
    }

    func eject() async throws {
        try await onQueue {
            guard let (i, _) = self.option("eject") else { return }
            let st = sane_control_option(self.handle, i, SANE_ACTION_SET_VALUE, nil, nil)
            guard st == SANE_STATUS_GOOD else { throw Self.error("Could not eject the holder", st) }
        }
    }

    func cancel() {
        lock.withLock { cancelRequested = true }
        if let handle { sane_cancel(handle) }
    }

    func close() {
        SaneSession.queue.async {
            if let h = self.handle { sane_close(h) }
            self.handle = nil
        }
    }

    // MARK: Scanning

    private func scanOnQueue(_ r: ScanRequest, progress: @Sendable (Double) -> Void) throws -> ScanResult {
        let s = r.settings
        setString("mode", preferring: ["16bit Color", "12bit Color", "Color"])
        setBool("preview", false)
        setNumber("resolution", Double(r.preview ? 800 : s.dpi))
        setNumber("frame", Double(r.frame))
        setBool("multi-sample", r.preview ? false : s.multiSample)
        setBool("autofocus", r.preview ? false : s.autofocus)
        if r.preview || s.autoExposure {
            setBool("ae", true)
        } else {
            setBool("ae", false)
            setNumber("scan-exposure-time-r", Double(s.exposure.r))
            setNumber("scan-exposure-time-g", Double(s.exposure.g))
            setNumber("scan-exposure-time-b", Double(s.exposure.b))
        }

        var st = sane_start(handle)
        if st == SANE_STATUS_NO_DOCS { throw ScannerError.noHolder }
        if st == SANE_STATUS_CANCELLED { throw ScannerError.cancelled }
        guard st == SANE_STATUS_GOOD else { throw Self.error("The scan did not start", st) }
        defer { sane_cancel(handle) }

        var p = SANE_Parameters()
        st = sane_get_parameters(handle, &p)
        guard st == SANE_STATUS_GOOD else { throw Self.error("No scan parameters", st) }

        let bpl = Int(p.bytes_per_line), width = Int(p.pixels_per_line)
        let knownLines = Int(p.lines)
        var bytes = [UInt8]()
        if knownLines > 0 { bytes.reserveCapacity(bpl * knownLines) }
        let total = Double(max(1, bpl * max(knownLines, 1)))
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        var lastReport = 0.0

        while true {
            if lock.withLock({ cancelRequested }) { throw ScannerError.cancelled }
            var len: SANE_Int = 0
            st = buf.withUnsafeMutableBufferPointer { sane_read(handle, $0.baseAddress, SANE_Int($0.count), &len) }
            if st == SANE_STATUS_EOF { break }
            if st == SANE_STATUS_CANCELLED { throw ScannerError.cancelled }
            guard st == SANE_STATUS_GOOD else { throw Self.error("Reading the scan failed", st) }
            bytes.append(contentsOf: buf[0..<Int(len)])
            let f = min(1, Double(bytes.count) / total)
            if knownLines > 0, f - lastReport > 0.01 { lastReport = f; progress(f) }
        }
        progress(1)

        let lines = bytes.count / bpl
        let image = try Self.toImage(bytes, width: width, lines: lines, bytesPerLine: bpl,
                                     depth: Int(p.depth), gray: p.format == SANE_FRAME_GRAY)
        let exposure = RGBExposure(r: getInt("scan-exposure-time-r") ?? 100,
                                   g: getInt("scan-exposure-time-g") ?? 100,
                                   b: getInt("scan-exposure-time-b") ?? 100)
        return ScanResult(image: image, exposure: exposure, focus: getInt("focus"))
    }

    private static func toImage(_ bytes: [UInt8], width: Int, lines: Int, bytesPerLine: Int, depth: Int, gray: Bool) throws -> Image16 {
        let ch = gray ? 1 : 3
        var out = [UInt16](repeating: 0, count: width * lines * 3)
        bytes.withUnsafeBytes { raw in
            for y in 0..<lines {
                let row = raw.baseAddress!.advanced(by: y * bytesPerLine)
                for x in 0..<width {
                    for c in 0..<3 {
                        let s = x * ch + (gray ? 0 : c)
                        let v: UInt16 = depth == 16
                            ? row.loadUnaligned(fromByteOffset: s * 2, as: UInt16.self)   // SANE: host byte order
                            : UInt16(row.load(fromByteOffset: s, as: UInt8.self)) * 257
                        out[(y * width + x) * 3 + c] = v
                    }
                }
            }
        }
        return Image16(width: width, height: lines, data: out)
    }

    // MARK: Options

    private func option(_ name: String) -> (SANE_Int, UnsafePointer<SANE_Option_Descriptor>)? {
        guard let handle else { return nil }
        var count: SANE_Int = 0
        guard sane_control_option(handle, 0, SANE_ACTION_GET_VALUE, &count, nil) == SANE_STATUS_GOOD else { return nil }
        for i in 1..<max(1, count) {
            guard let d = sane_get_option_descriptor(handle, i), let n = d.pointee.name else { continue }
            if String(cString: n) == name { return (i, d) }
        }
        return nil
    }

    private func isActive(_ d: UnsafePointer<SANE_Option_Descriptor>) -> Bool {
        d.pointee.cap & Self.capInactive == 0
    }

    private func setNumber(_ name: String, _ value: Double) {
        guard let (i, d) = option(name), isActive(d) else { return }
        var w: SANE_Word = d.pointee.type == SANE_TYPE_FIXED ? SANE_Word(value * 65536) : SANE_Word(value)
        _ = sane_control_option(handle, i, SANE_ACTION_SET_VALUE, &w, nil)
    }

    private func setBool(_ name: String, _ value: Bool) {
        guard let (i, d) = option(name), isActive(d) else { return }
        var w: SANE_Word = value ? SANE_TRUE : SANE_FALSE
        _ = sane_control_option(handle, i, SANE_ACTION_SET_VALUE, &w, nil)
    }

    private func getInt(_ name: String) -> Int? {
        guard let (i, d) = option(name), isActive(d) else { return nil }
        var w: SANE_Word = 0
        guard sane_control_option(handle, i, SANE_ACTION_GET_VALUE, &w, nil) == SANE_STATUS_GOOD else { return nil }
        return d.pointee.type == SANE_TYPE_FIXED ? Int(w / 65536) : Int(w)
    }

    /// Sets the first value from `preferring` that the option offers.
    private func setString(_ name: String, preferring: [String]) {
        guard let (i, d) = option(name), isActive(d) else { return }
        var offered: [String] = []
        if d.pointee.constraint_type == SANE_CONSTRAINT_STRING_LIST, var p = d.pointee.constraint.string_list {
            while let s = p.pointee { offered.append(String(cString: s)); p += 1 }
        }
        guard let pick = preferring.first(where: { offered.isEmpty || offered.contains($0) }) else { return }
        var buf = [CChar](repeating: 0, count: max(Int(d.pointee.size), pick.utf8.count + 1))
        _ = pick.withCString { strncpy(&buf, $0, buf.count - 1) }
        _ = sane_control_option(handle, i, SANE_ACTION_SET_VALUE, &buf, nil)
    }

    // MARK: Helpers

    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            SaneSession.queue.async {
                do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
            }
        }
    }

    private static func error(_ what: String, _ st: SANE_Status) -> ScannerError {
        .sane("\(what): \(String(cString: sane_strstatus(st)))")
    }
}
