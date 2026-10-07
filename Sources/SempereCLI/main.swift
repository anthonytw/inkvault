import ArgumentParser
import Foundation

/// Entry point: maps every failure to one stderr line and the documented
/// exit code (docs/cli.md): 0 ok, 1 failure, 2 usage, 3 unhealthy or
/// incomplete, 4 cannot decrypt, 5 legacy vault, 6 untrusted recipients list, 7 read-only (newer format version).
func runCLI(_ arguments: [String]) -> Int32 {
    // Whatever the command wrote, even when it then failed (format.md §1:
    // the index is an unknown file; docs/web-viewer.md "Hosting").
    defer {
        OpenedVaults.shared.refreshWebIndexes()
        UntaggedVaults.shared.reportUpgrades()
    }
    do {
        var command = try SempereCLI.parseAsRoot(arguments)
        try command.run()
        return 0
    } catch let e as CLIError {
        printError(e.message)
        return e.code
    } catch let e as ExitCode {
        return e.rawValue
    } catch {
        let code = SempereCLI.exitCode(for: error)
        if code == .success {
            print(SempereCLI.fullMessage(for: error))
            return 0
        }
        if code == .validationFailure {
            printStderr(SempereCLI.fullMessage(for: error))
            return 2
        }
        let mapped = CLIError.from(error)
        printError(mapped.message)
        return mapped.code
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == ExecLimited.command { ExecLimited.main(Array(arguments.dropFirst())) }
exit(runCLI(arguments))
