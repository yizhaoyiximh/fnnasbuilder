@preconcurrency import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let output: String
}

enum ProcessRunnerError: LocalizedError {
    case executableNotFound(String)
    case cancelled

    var errorDescription: String {
        switch self {
        case .executableNotFound(let path):
            return "找不到可执行文件：\(path)"
        case .cancelled:
            return "操作已取消"
        }
    }
}

/// Runs one command at a time and forwards combined stdout/stderr chunks as they arrive.
///
/// `Process` and file-handle callbacks are not actor-isolated APIs. The small locked control
/// objects below contain that synchronous state, while `run` exposes an async cancellation-safe
/// interface to callers.
final class ProcessRunner: @unchecked Sendable {
    private let control = ProcessControl()

    func run(
        _ executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessRunnerError.executableNotFound(executable)
        }
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        var processEnvironment = ProcessInfo.processInfo.environment
        environment.forEach { processEnvironment[$0.key] = $0.value }
        process.environment = processEnvironment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let invocation = ProcessInvocation(process: process)
        control.activate(invocation)

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let output = OutputState(callback: onOutput)
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty, let chunk = String(data: data, encoding: .utf8) {
                        output.append(chunk)
                    }
                }

                process.terminationHandler = { [weak self] terminatedProcess in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
                    if !tail.isEmpty, let chunk = String(data: tail, encoding: .utf8) {
                        output.append(chunk)
                    }

                    self?.control.finish(invocation)
                    if invocation.wasCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(
                            returning: ProcessResult(
                                status: terminatedProcess.terminationStatus,
                                output: output.snapshot()
                            )
                        )
                    }
                }

                do {
                    try process.run()
                    // A cancellation can arrive after activation but before Process.run().
                    // Honour it immediately once the child process has actually launched.
                    if invocation.wasCancelled, process.isRunning {
                        process.terminate()
                    }
                } catch {
                    self.control.finish(invocation)
                    if invocation.wasCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { [control] in
            control.cancelActiveProcess()
        })
    }

    /// Requests cancellation of the active child process, if any.
    func cancel() {
        control.cancelActiveProcess()
    }

    private final class ProcessControl: @unchecked Sendable {
        private let lock = NSLock()
        private var activeInvocation: ProcessInvocation?

        func activate(_ invocation: ProcessInvocation) {
            lock.withLock {
                activeInvocation = invocation
            }
        }

        func finish(_ invocation: ProcessInvocation) {
            lock.withLock {
                if activeInvocation === invocation {
                    activeInvocation = nil
                }
            }
        }

        func cancelActiveProcess() {
            let invocation = lock.withLock { activeInvocation }
            invocation?.cancel()
        }
    }

    private final class ProcessInvocation: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var cancelled = false

        init(process: Process) {
            self.process = process
        }

        var wasCancelled: Bool {
            lock.withLock { cancelled }
        }

        func cancel() {
            let shouldTerminate = lock.withLock { () -> Bool in
                cancelled = true
                return process.isRunning
            }
            if shouldTerminate {
                process.terminate()
            }
        }
    }

    private final class OutputState: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        private let callback: @Sendable (String) -> Void

        init(callback: @escaping @Sendable (String) -> Void) {
            self.callback = callback
        }

        func append(_ text: String) {
            lock.withLock {
                value += text
            }
            callback(text)
        }

        func snapshot() -> String {
            lock.withLock { value }
        }
    }
}
