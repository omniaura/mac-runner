import Foundation

/// Utility for executing shell processes with common patterns.
/// Eliminates duplicate Process setup code across the codebase.
enum ProcessExecutor {
    /// Result of a process execution
    struct ProcessResult {
        let terminationStatus: Int32
        let output: String

        var succeeded: Bool {
            terminationStatus == 0
        }
    }

    /// Execute a process and capture its output
    /// - Parameters:
    ///   - executable: Path to the executable (e.g., "/usr/bin/sudo")
    ///   - arguments: Command arguments
    ///   - silent: If true, discards output; if false, captures it
    /// - Returns: Process result with status and output
    /// - Throws: ProcessExecutorError if execution fails
    static func run(_ executable: String, arguments: [String], silent: Bool = false) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        if silent {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        } else {
            process.standardOutput = pipe
            process.standardError = pipe
        }

        try process.run()

        let output: String
        if silent {
            process.waitUntilExit()
            output = ""
        } else {
            // Read pipe data BEFORE waiting to prevent deadlock on large outputs
            // (pipe buffer is typically 64KB; processes block if buffer fills)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            output = data.asUTF8String
        }

        return ProcessResult(terminationStatus: process.terminationStatus, output: output)
    }

    /// Execute a process with sudo and capture output
    /// - Parameters:
    ///   - arguments: Arguments to pass to sudo (executable and its args)
    ///   - silent: If true, discards output
    /// - Returns: Process result
    /// - Throws: ProcessExecutorError on failure
    static func runSudo(arguments: [String], silent: Bool = false) throws -> ProcessResult {
        return try run("/usr/bin/sudo", arguments: arguments, silent: silent)
    }

    /// Execute a process and throw if it fails
    /// - Parameters:
    ///   - executable: Path to executable
    ///   - arguments: Command arguments
    ///   - errorMessage: Error message prefix if command fails
    /// - Throws: ProcessExecutorError with output if command fails
    static func runOrThrow(_ executable: String, arguments: [String], errorMessage: String) throws {
        let result = try run(executable, arguments: arguments)
        guard result.succeeded else {
            throw ProcessExecutorError.executionFailed("\(errorMessage): \(result.output)")
        }
    }

    /// Execute sudo command and throw if it fails
    /// - Parameters:
    ///   - arguments: Arguments to sudo
    ///   - errorMessage: Error message prefix if command fails
    /// - Throws: ProcessExecutorError if command fails
    static func runSudoOrThrow(arguments: [String], errorMessage: String) throws {
        let result = try runSudo(arguments: arguments)
        guard result.succeeded else {
            throw ProcessExecutorError.executionFailed("\(errorMessage): \(result.output)")
        }
    }

    /// Silence a process's output by redirecting to null device
    /// - Parameter process: Process to silence
    static func silenceOutput(for process: Process) {
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    /// Execute a process with a working directory and capture output
    /// - Parameters:
    ///   - executable: Path to the executable
    ///   - arguments: Command arguments
    ///   - workingDirectory: Working directory path (nil for inherited)
    ///   - captureOutput: If true, captures output; if false, discards it
    /// - Returns: Process result with status and output
    /// - Throws: ProcessExecutorError if execution fails
    static func runWithWorkingDirectory(
        _ executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        captureOutput: Bool = true
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let workingDir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
        }

        let pipe = Pipe()
        if captureOutput {
            process.standardOutput = pipe
            process.standardError = pipe
        } else {
            silenceOutput(for: process)
        }

        try process.run()

        let output: String
        if captureOutput {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            output = data.asUTF8String
        } else {
            process.waitUntilExit()
            output = ""
        }

        return ProcessResult(terminationStatus: process.terminationStatus, output: output)
    }

    /// Create and configure a Process object with common settings
    /// - Parameters:
    ///   - executable: Path to the executable
    ///   - arguments: Command arguments
    ///   - workingDirectory: Optional working directory
    ///   - outputTo: Optional pipe or file handle for output (nil for null device)
    /// - Returns: Configured Process object (not yet started)
    static func createProcess(
        _ executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        outputTo output: Any? = nil
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let workingDir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
        }

        if let output = output {
            process.standardOutput = output
            process.standardError = output
        } else {
            silenceOutput(for: process)
        }

        return process
    }
}

/// Errors thrown by ProcessExecutor
enum ProcessExecutorError: Error, LocalizedError {
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .executionFailed(let message):
            return message
        }
    }
}

// MARK: - Convenience Extensions

extension Pipe {
    /// Read all data from the pipe and convert to a UTF-8 string
    /// - Returns: String representation of pipe data, or empty string if conversion fails
    func readAsUTF8String() -> String {
        let data = fileHandleForReading.readDataToEndOfFile()
        return data.asUTF8String
    }
}

extension Data {
    /// Convert Data to UTF-8 string with empty string fallback
    /// Eliminates repeated `String(data:encoding:) ?? ""` pattern
    var asUTF8String: String {
        return String(data: self, encoding: .utf8) ?? ""
    }
}
