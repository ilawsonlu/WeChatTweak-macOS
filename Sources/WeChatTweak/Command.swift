//
//  Command.swift
//
//  Created by Sunny Young.
//

import Foundation
import ArgumentParser

struct Command {
    enum Error: @unchecked Sendable, LocalizedError {
        case executing(command: String, error: NSDictionary)

        var errorDescription: String? {
            switch self {
            case let .executing(command, error):
                return "executing: \(command) error: \(error)"
            }
        }
    }

    static func version(app: URL) async throws -> String? {
        try await Command.execute(command: "defaults read \(quote(app.appendingPathComponent("Contents/Info.plist").path)) CFBundleVersion")
    }

    static func isRunning(app: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", app.standardizedFileURL.appendingPathComponent("Contents/MacOS/").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static let defaultBinary = "Contents/MacOS/WeChat"

    /// Patch every target in the binary declared by its config entry. Newer WeChat
    /// builds keep business logic in Contents/Resources/wechat.dylib, while legacy
    /// builds still use the main executable.
    @discardableResult
    static func patch(app: URL, config: Config) throws -> [String] {
        var entriesByBinary: [String: [Config.Entry]] = [:]
        var binaryOrder: [String] = []
        let installsRuntimeMarker = config.targets.contains {
            $0.identifier == RuntimeMarkerInstaller.targetIdentifier
        }

        for target in config.targets {
            let relative = target.binary ?? defaultBinary
            print("------ Target: \(target.identifier) (\(relative)) ------")
            if entriesByBinary[relative] == nil {
                binaryOrder.append(relative)
            }
            entriesByBinary[relative, default: []].append(contentsOf: target.entries)
        }

        // Validate every configured range before injecting a load command. This keeps
        // wrong builds byte-for-byte untouched rather than leaving a half-installed dylib.
        for relative in binaryOrder {
            let inspections = try Patcher.inspect(
                binary: app.appendingPathComponent(relative),
                entries: entriesByBinary[relative]!
            )
            if let unknown = inspections.first(where: { $0.state == .unknown }) {
                throw Patcher.Error.expectedMismatch(
                    arch: unknown.entry.arch.rawValue,
                    va: unknown.entry.addr,
                    found: unknown.currentHex,
                    want: unknown.entry.expected.map(\.hexString)
                )
            }
        }

        if installsRuntimeMarker {
            print("------ Runtime: orange revoke marker ------")
            try RuntimeMarkerInstaller.install(app: app, buildVersion: config.version)
        }

        for relative in binaryOrder {
            try Patcher.patch(
                binary: app.appendingPathComponent(relative),
                entries: entriesByBinary[relative]!,
                backupVersion: config.version
            )
        }
        if installsRuntimeMarker {
            binaryOrder.append(RuntimeMarkerInstaller.installedDylibPath)
        }
        return binaryOrder
    }

    static func resign(app: URL, patchedBinaries: [String]) async throws {
        let nested = patchedBinaries
            .filter { $0 != defaultBinary }
            .map { app.appendingPathComponent($0) }
        try Resigner.resign(app: app, patchedBinaries: nested)
    }

    private static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private static func execute(command: String) async throws -> String? {
        guard let script = NSAppleScript(source: "do shell script \"\(command)\"") else {
            throw Error.executing(
                command: command,
                error: ["error": "Create script failed."]
            )
        }

        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)

        if let error = error {
            throw Error.executing(
                command: command,
                error: error
            )
        } else {
            return descriptor.stringValue
        }
    }
}
