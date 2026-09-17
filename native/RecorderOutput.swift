import Darwin
import Foundation

// The capture clock must never wait for an ASR reader. Keep a bounded FIFO
// across short stalls, and make even a permanently blocked pipe cancellable.
final class RecorderPCMOutput {
    private let descriptor: Int32
    private let maxBufferedBytes: Int
    private let stallTimeout: TimeInterval
    private let onFailure: (String) -> Void
    private let queue = DispatchQueue(label: "app.arco.recorder.stdout")
    private let lock = NSLock()
    private let drained = DispatchGroup()
    private var chunks: [Data?] = []
    private var head = 0
    private var bufferedBytes = 0 // Includes the chunk currently being written.
    private var running = false
    private var accepting = true
    private var cancelled = false
    private var failure: String?

    init(descriptor: Int32, maxBufferedBytes: Int = 16_000 * 4 * 30,
         stallTimeout: TimeInterval = 30, onFailure: @escaping (String) -> Void) throws {
        self.descriptor = descriptor
        self.maxBufferedBytes = maxBufferedBytes
        self.stallTimeout = stallTimeout
        self.onFailure = onFailure
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    @discardableResult
    func enqueue(_ data: Data) -> Bool {
        lock.lock()
        guard accepting, failure == nil else { lock.unlock(); return false }
        guard data.count <= maxBufferedBytes - bufferedBytes else {
            lock.unlock()
            fail("audio output backlog exceeded \(maxBufferedBytes) bytes; transcription is not draining")
            return false
        }
        chunks.append(data)
        bufferedBytes += data.count
        if !running {
            running = true
            drained.enter()
            queue.async { [self] in drain() }
        }
        lock.unlock()
        return true
    }

    // Stop accepting before waiting so capture shutdown has a finite deadline.
    // A timeout never leaves a thread stuck in write(2).
    func finish(timeout: TimeInterval = 2) -> Bool {
        lock.lock(); accepting = false; lock.unlock()
        let completed = drained.wait(timeout: .now() + timeout) == .success
        lock.lock()
        if !completed { cancelled = true }
        let succeeded = completed && failure == nil
        lock.unlock()
        if !completed { _ = drained.wait(timeout: .now() + 0.2) }
        return succeeded
    }

    private func fail(_ reason: String) {
        lock.lock()
        guard failure == nil, !cancelled else { lock.unlock(); return }
        failure = reason
        accepting = false
        lock.unlock()
        onFailure(reason)
    }

    private func drain() {
        defer { drained.leave() }
        while true {
            lock.lock()
            guard !cancelled, failure == nil, head < chunks.count else {
                chunks.removeAll(keepingCapacity: true)
                head = 0
                bufferedBytes = 0
                running = false
                lock.unlock()
                return
            }
            let data = chunks[head]!
            chunks[head] = nil
            head += 1
            if head == chunks.count {
                chunks.removeAll(keepingCapacity: true)
                head = 0
            }
            lock.unlock()
            if !write(data) { continue }
            lock.lock(); bufferedBytes -= data.count; lock.unlock()
        }
    }

    private func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            var lastProgress = ProcessInfo.processInfo.systemUptime
            while offset < bytes.count {
                lock.lock(); let stopped = cancelled || failure != nil; lock.unlock()
                if stopped { return false }
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written > 0 {
                    offset += written
                    lastProgress = ProcessInfo.processInfo.systemUptime
                    continue
                }
                let code = errno
                if written < 0, code == EINTR { continue }
                guard written < 0, code == EAGAIN || code == EWOULDBLOCK else {
                    fail("audio output failed: errno=\(code)")
                    return false
                }
                if ProcessInfo.processInfo.systemUptime - lastProgress >= stallTimeout {
                    fail("audio output made no progress for \(stallTimeout) seconds")
                    return false
                }
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                _ = Darwin.poll(&pollDescriptor, 1, 50)
            }
            return true
        }
    }
}
