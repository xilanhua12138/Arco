import CoreVideo
import Foundation

final class DisplayLinkSamples: @unchecked Sendable {
    private let lock = NSLock()
    private let hostClockFrequency = CVGetHostClockFrequency()
    private var previousHostTime: UInt64?
    private var intervals: [Double] = []

    func record(hostTime: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if let previousHostTime, hostTime > previousHostTime {
            let milliseconds = Double(hostTime - previousHostTime)
                / hostClockFrequency
                * 1_000
            intervals.append(milliseconds)
        }
        previousHostTime = hostTime
    }

    func snapshot() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return intervals
    }
}

let duration = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 10
guard duration > 0 else {
    FileHandle.standardError.write(Data("duration must be positive\n".utf8))
    exit(2)
}

let samples = DisplayLinkSamples()
var displayLink: CVDisplayLink?
let createStatus = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
guard createStatus == kCVReturnSuccess, let displayLink else {
    FileHandle.standardError.write(Data("could not create display link: \(createStatus)\n".utf8))
    exit(1)
}

let context = Unmanaged.passUnretained(samples).toOpaque()
let callback: CVDisplayLinkOutputCallback = { _, now, _, _, _, context in
    guard let context else { return kCVReturnError }
    Unmanaged<DisplayLinkSamples>
        .fromOpaque(context)
        .takeUnretainedValue()
        .record(hostTime: now.pointee.hostTime)
    return kCVReturnSuccess
}

let callbackStatus = CVDisplayLinkSetOutputCallback(displayLink, callback, context)
guard callbackStatus == kCVReturnSuccess else {
    FileHandle.standardError.write(Data("could not install display callback: \(callbackStatus)\n".utf8))
    exit(1)
}

let startStatus = CVDisplayLinkStart(displayLink)
guard startStatus == kCVReturnSuccess else {
    FileHandle.standardError.write(Data("could not start display link: \(startStatus)\n".utf8))
    exit(1)
}

RunLoop.current.run(until: Date().addingTimeInterval(duration))
CVDisplayLinkStop(displayLink)

for interval in samples.snapshot().dropFirst(5) {
    print(String(format: "%.6f", interval))
}
