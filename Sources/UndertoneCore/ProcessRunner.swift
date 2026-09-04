import Foundation
import os

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Abstracted so the client can be unit-tested with canned output.
public protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws -> ProcessResult
}

/// Runs a subprocess off the main actor. Output is accumulated as it arrives (never a blocking read-to-EOF:
/// a grandchild such as deno can inherit the pipe and keep it open after yt-dlp is killed), the process is
/// killed on timeout or task cancellation, and the kill is skipped once the child has already exited.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    @concurrent
    public func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        let stdoutBuffer = OSAllocatedUnfairLock(initialState: Data())
        let stderrBuffer = OSAllocatedUnfairLock(initialState: Data())
        let stdoutEOF = OSAllocatedUnfairLock(initialState: false)
        stdoutHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                stdoutEOF.withLock { $0 = true }
                handle.readabilityHandler = nil
            } else {
                stdoutBuffer.withLock { $0.append(chunk) }
            }
        }
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.withLock { $0.append(chunk) }
            }
        }

        // Buffered stream: the termination handler may fire before we start awaiting.
        let (terminated, continuation) = AsyncStream<Int32>.makeStream()
        let exited = OSAllocatedUnfairLock(initialState: false)
        process.terminationHandler = { finished in
            exited.withLock { $0 = true }
            continuation.yield(finished.terminationStatus)
            continuation.finish()
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            throw YTDLPFailure.launchFailed(error.localizedDescription)
        }

        let pid = process.processIdentifier
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = Task.detached {
            try await Task.sleep(for: timeout)
            timedOut.withLock { $0 = true }
            if !exited.withLock({ $0 }) { kill(pid, SIGKILL) }
        }
        defer { watchdog.cancel() }

        return try await withTaskCancellationHandler {
            var status: Int32 = -1
            for await code in terminated {
                status = code
                break
            }
            // Let the readability handlers deliver the tail of stdout (normally immediate), but never wait
            // on a pipe a lingering grandchild might still hold: cap at ~1 s.
            var polls = 0
            while !stdoutEOF.withLock({ $0 }), polls < 50 {
                try? await Task.sleep(for: .milliseconds(20))
                polls += 1
            }
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            let out = stdoutBuffer.withLock { $0 }
            let err = stderrBuffer.withLock { $0 }
            if timedOut.withLock({ $0 }) { throw YTDLPFailure.timedOut }
            if Task.isCancelled { throw YTDLPFailure.cancelled }
            return ProcessResult(exitCode: status, stdout: out, stderr: err)
        } onCancel: {
            if !exited.withLock({ $0 }) { kill(pid, SIGTERM) }
        }
    }
}
