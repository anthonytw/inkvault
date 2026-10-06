import ArgumentParser
import Foundation

/// Entry point: maps every failure to one stderr line and the documented
/// exit code (docs/cli.md): 0 ok, 1 failure, 2 usage, 3 unhealthy or
/// incomplete, 4 cannot decrypt, 5 legacy vault.
func runCLI(_ arguments: [String]) -> Int32 {
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

exit(runCLI(Array(CommandLine.arguments.dropFirst())))
