import Darwin
import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

private final class FailureLog {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}

private func withPipe(_ body: (Int32, Int32) throws -> Void) rethrows {
    var descriptors: [Int32] = [0, 0]
    check(pipe(&descriptors) == 0, "create pipe")
    defer { close(descriptors[0]); close(descriptors[1]) }
    try body(descriptors[0], descriptors[1])
}

@main
struct RecorderOutputTests {
    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        // A stalled real pipe used to terminate capture after one 100ms tick.
        // Continue capturing for 500ms, then require byte-for-byte FIFO replay.
        try withPipe { readFD, writeFD in
            let failures = FailureLog()
            let writer = try RecorderPCMOutput(descriptor: writeFD, onFailure: failures.append)
            let expected = Data((0..<512_000).map { UInt8($0 % 251) })
            let captureStart = ProcessInfo.processInfo.systemUptime
            for offset in stride(from: 0, to: expected.count, by: 6_400) {
                check(writer.enqueue(expected.subdata(in: offset..<min(offset + 6_400, expected.count))), "accept audio during stall")
            }
            check(ProcessInfo.processInfo.systemUptime - captureStart < 0.2, "capture must not block on pipe")
            Thread.sleep(forTimeInterval: 0.5)
            check(failures.count == 0, "500ms stall must not fail")
            let readDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                var actual = Data()
                var buffer = [UInt8](repeating: 0, count: 8_192)
                while actual.count < expected.count {
                    let count = Darwin.read(readFD, &buffer, buffer.count)
                    check(count > 0, "read queued PCM")
                    actual.append(contentsOf: buffer.prefix(count))
                }
                check(actual == expected, "no lost, duplicated, reordered or partial PCM")
                readDone.signal()
            }
            check(writer.finish(), "drain after reader resumes")
            check(readDone.wait(timeout: .now() + 2) == .success, "reader completes")
            check(failures.count == 0, "healthy drain must not fail")
            check(!writer.enqueue(Data([1])), "no audio accepted after finish")
        }
        print("PASS: stalled pipe resumes with byte-exact ordered PCM")

        try withPipe { _, writeFD in
            let failures = FailureLog()
            let writer = try RecorderPCMOutput(descriptor: writeFD, onFailure: failures.append)
            check(writer.enqueue(Data(repeating: 1, count: 512_000)), "queue blocked output")
            let start = ProcessInfo.processInfo.systemUptime
            check(!writer.finish(timeout: 0.1), "blocked shutdown reports incomplete drain")
            check(ProcessInfo.processInfo.systemUptime - start < 0.5, "blocked shutdown stays bounded")
            check(failures.count == 0, "shutdown cancellation does not emit another failure")
        }
        print("PASS: permanently blocked pipe has bounded shutdown")

        try withPipe { _, writeFD in
            let failures = FailureLog()
            let writer = try RecorderPCMOutput(descriptor: writeFD, maxBufferedBytes: 128, onFailure: failures.append)
            check(!writer.enqueue(Data(repeating: 1, count: 129)), "backlog has a hard memory bound")
            check(!writer.enqueue(Data([2])), "failed output stays closed")
            check(failures.count == 1, "report overflow once")
            check(!writer.finish(), "overflow is not reported as successful flush")
        }
        print("PASS: backlog overflow is bounded and explicit")

        try withPipe { _, writeFD in
            let failed = DispatchSemaphore(value: 0)
            let writer = try RecorderPCMOutput(descriptor: writeFD, stallTimeout: 0.15) { _ in failed.signal() }
            writer.enqueue(Data(repeating: 1, count: 512_000))
            check(failed.wait(timeout: .now() + 1) == .success, "permanent stall must be reported")
            check(!writer.finish(), "stalled output cannot claim successful drain")
        }
        print("PASS: permanent stall reports a specific timeout")

        var descriptors: [Int32] = [0, 0]
        check(pipe(&descriptors) == 0, "create closed-reader pipe")
        close(descriptors[0])
        defer { close(descriptors[1]) }
        let failed = DispatchSemaphore(value: 0)
        let writer = try RecorderPCMOutput(descriptor: descriptors[1]) { reason in
            check(reason.contains("errno=\(EPIPE)"), "report closed reader")
            failed.signal()
        }
        writer.enqueue(Data([1, 2, 3, 4]))
        check(failed.wait(timeout: .now() + 1) == .success, "closed reader cannot kill process via SIGPIPE")
        check(!writer.finish(), "closed reader returns failure")
        print("PASS: closed reader reports EPIPE without signal termination")
    }
}
