import Foundation
import AppKit

// Dispatch: CLI args → CLIHandler, no args → GUI
if CommandLine.arguments.count > 1 {
    // CLI mode: pump a run loop so async work completes
    let sema = DispatchSemaphore(value: 0)
    Task { @MainActor in
        let handled = await CLIHandler.handle(arguments: CommandLine.arguments)
        if !handled {
            MacRunnerApp.main()
            return // main() never returns for GUI
        }
        sema.signal()
    }
    // Keep main thread alive while async work runs
    while sema.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    exit(0)
} else {
    // GUI mode
    MacRunnerApp.main()
}
