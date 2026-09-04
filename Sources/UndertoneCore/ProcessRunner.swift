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

/// Runs a subprocess off the main actor, draining both pipes concurrently (yt-dlp's JSON exceeds the 64 KB pipe buffer),
/// killing it on timeout or task cancellation.
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

        // Buffered stream: the termination handler may fire before we start awaiting.
        let (terminated, continuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            continuation.yield(finished.terminationStatus)
            continuation.finish()
        }

        do {
            try process.run()
        } catch {
            throw YTDLPFailure.launchFailed(error.localizedDescription)
        }

        let pid = process.processIdentifier
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let timedOut = OSAllocatedUnfairLock(initialState: false)

        let watchdog = Task.detached {
            try await Task.sleep(for: timeout)
            timedOut.withLock { $0 = true }
            kill(pid, SIGKILL)
        }
        defer { watchdog.cancel() }

        return try await withTaskCancellationHandler {
            async let stdoutData = Self.drain(stdoutHandle)
            async let stderrData = Self.drain(stderrHandle)
            var status: Int32 = -1
            for await code in terminated {
                status = code
                break
            }
            let out = await stdoutData
            let err = await stderrData
            if timedOut.withLock({ $0 }) { throw YTDLPFailure.timedOut }
            if Task.isCancelled { throw YTDLPFailure.cancelled }
            return ProcessResult(exitCode: status, stdout: out, stderr: err)
        } onCancel: {
            kill(pid, SIGTERM)
        }
    }

    private static func drain(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}
