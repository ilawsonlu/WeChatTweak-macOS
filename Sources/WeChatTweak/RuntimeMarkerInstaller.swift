import Foundation

struct RuntimeMarkerInstaller {
    static let targetIdentifier = "runtime-marker"

    private static let dylibFileName = "libWeChatTweakRuntime.dylib"
    private static let installName = "@loader_path/\(dylibFileName)"
    private static let hostBinaryPath = "Contents/Resources/wechat.dylib"
    private static let destinationDylibPath = "Contents/Resources/\(dylibFileName)"
    private static let supportedBuild = "270098"

    static var installedDylibPath: String { destinationDylibPath }

    enum Error: LocalizedError {
        case unsupportedBuild(String)
        case runtimeNotFound([String])
        case runtimeDoesNotContainArm64(String)

        var errorDescription: String? {
            switch self {
            case let .unsupportedBuild(build):
                return "The orange revoke marker only supports WeChat build \(supportedBuild); found \(build)"
            case let .runtimeNotFound(paths):
                return "Runtime dylib not found. Looked in:\n\(paths.map { "  " + $0 }.joined(separator: "\n"))"
            case let .runtimeDoesNotContainArm64(path):
                return "Runtime dylib does not contain an arm64 slice: \(path)"
            }
        }
    }

    static func install(app: URL, buildVersion: String) throws {
        guard buildVersion == supportedBuild else { throw Error.unsupportedBuild(buildVersion) }

        let source = try resolveSourceDylib()
        let runtimeData = try Data(contentsOf: source, options: .mappedIfSafe)
        guard MachODylibInjector.containsArm64Slice(runtimeData) else {
            throw Error.runtimeDoesNotContainArm64(source.path)
        }

        let host = app.appendingPathComponent(hostBinaryPath)
        let destination = app.appendingPathComponent(destinationDylibPath)
        let injector = MachODylibInjector(fileURL: host)
        _ = try injector.inject(
            installName: installName,
            cpuType: MachODylibInjector.cpuTypeArm64,
            dryRun: true
        )
        try Patcher.backup(binary: host, version: buildVersion)

        try runtimeData.write(to: destination, options: .atomic)
        let result = try injector.inject(
            installName: installName,
            cpuType: MachODylibInjector.cpuTypeArm64
        )
        switch result {
        case let .injected(commandOffset, paddingLeft):
            print("[arm64] injected \(installName) at fileoff=\(String(format: "0x%llx", commandOffset)); header padding left: \(paddingLeft) bytes")
        case let .alreadyInjected(commandOffset):
            print("[arm64] \(installName) already injected at fileoff=\(String(format: "0x%llx", commandOffset)) — refreshing runtime dylib")
        }
    }

    private static func resolveSourceDylib() throws -> URL {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["WECHATTWEAK_RUNTIME_DYLIB"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent(dylibFileName))
        }

        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        candidates.append(current.appendingPathComponent(".build/release/\(dylibFileName)"))
        candidates.append(current.appendingPathComponent(".build/arm64-apple-macosx/release/\(dylibFileName)"))

        var seen: Set<String> = []
        let unique = candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
        if let found = unique.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return found
        }
        throw Error.runtimeNotFound(unique.map(\.path))
    }
}

private struct MachODylibInjector {
    static let cpuTypeArm64: UInt32 = 0x0100000c

    enum Result {
        case injected(commandOffset: UInt64, paddingLeft: Int)
        case alreadyInjected(commandOffset: UInt64)
    }

    enum Error: LocalizedError {
        case malformed(String)
        case noMatchingSlice(String)
        case insufficientHeaderPadding(required: Int, available: Int)
        case occupiedHeaderPadding

        var errorDescription: String? {
            switch self {
            case let .malformed(path):
                return "Unsupported or malformed Mach-O: \(path)"
            case let .noMatchingSlice(path):
                return "No arm64 Mach-O slice found in \(path)"
            case let .insufficientHeaderPadding(required, available):
                return "Mach-O header padding is too small for runtime injection (need \(required) bytes, have \(available))"
            case .occupiedHeaderPadding:
                return "Mach-O header padding contains non-zero data — refusing to overwrite it"
            }
        }
    }

    private static let machMagic64: UInt32 = 0xfeedfacf
    private static let fatMagic: UInt32 = 0xcafebabe
    private static let fatMagic64: UInt32 = 0xcafebabf
    private static let loadDylibCommand: UInt32 = 0x0c
    private static let segment64Command: UInt32 = 0x19

    let fileURL: URL

    func inject(installName: String, cpuType: UInt32, dryRun: Bool = false) throws -> Result {
        var data = try Data(contentsOf: fileURL)
        let result = try Self.inject(
            installName: installName,
            cpuType: cpuType,
            filePath: fileURL.path,
            data: &data
        )
        if !dryRun, case .injected = result {
            let handle = try FileHandle(forUpdating: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }
        return result
    }

    static func containsArm64Slice(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        if data.uint32LE(at: 0) == machMagic64 {
            return data.uint32LE(at: 4) == cpuTypeArm64
        }
        guard let magic = data.uint32BE(at: 0), magic == fatMagic || magic == fatMagic64,
              let countValue = data.uint32BE(at: 4) else { return false }
        let count = Int(countValue)
        let entrySize = magic == fatMagic64 ? 32 : 20
        guard count >= 0, count <= (data.count - 8) / entrySize else { return false }
        for index in 0..<count {
            let offset = 8 + index * entrySize
            if data.uint32BE(at: offset) == cpuTypeArm64 {
                return true
            }
        }
        return false
    }

    private static func inject(
        installName: String,
        cpuType: UInt32,
        filePath: String,
        data: inout Data
    ) throws -> Result {
        guard data.count >= 4 else { throw Error.malformed(filePath) }

        if data.uint32LE(at: 0) == machMagic64 {
            return try injectThin(
                installName: installName,
                cpuType: cpuType,
                machOffset: 0,
                sliceSize: data.count,
                filePath: filePath,
                data: &data
            )
        }

        guard let magic = data.uint32BE(at: 0), magic == fatMagic || magic == fatMagic64,
              let countValue = data.uint32BE(at: 4) else {
            throw Error.malformed(filePath)
        }
        let count = Int(countValue)
        let entrySize = magic == fatMagic64 ? 32 : 20
        guard count >= 0, count <= (data.count - 8) / entrySize else {
            throw Error.malformed(filePath)
        }

        for index in 0..<count {
            let entry = 8 + index * entrySize
            guard data.uint32BE(at: entry) == cpuType else { continue }
            let offsetValue: UInt64?
            let sizeValue: UInt64?
            if magic == fatMagic64 {
                offsetValue = data.uint64BE(at: entry + 8)
                sizeValue = data.uint64BE(at: entry + 16)
            } else {
                offsetValue = data.uint32BE(at: entry + 8).map(UInt64.init)
                sizeValue = data.uint32BE(at: entry + 12).map(UInt64.init)
            }
            guard let offsetValue, let sizeValue,
                  let machOffset = Int(exactly: offsetValue),
                  let sliceSize = Int(exactly: sizeValue),
                  machOffset >= 0, sliceSize >= 32,
                  machOffset <= data.count - sliceSize else {
                throw Error.malformed(filePath)
            }
            return try injectThin(
                installName: installName,
                cpuType: cpuType,
                machOffset: machOffset,
                sliceSize: sliceSize,
                filePath: filePath,
                data: &data
            )
        }
        throw Error.noMatchingSlice(filePath)
    }

    private static func injectThin(
        installName: String,
        cpuType: UInt32,
        machOffset: Int,
        sliceSize: Int,
        filePath: String,
        data: inout Data
    ) throws -> Result {
        guard data.hasRange(machOffset, length: 32),
              data.uint32LE(at: machOffset) == machMagic64,
              data.uint32LE(at: machOffset + 4) == cpuType,
              let commandCountValue = data.uint32LE(at: machOffset + 16),
              let commandsSizeValue = data.uint32LE(at: machOffset + 20) else {
            throw Error.malformed(filePath)
        }

        let commandCount = Int(commandCountValue)
        let commandsSize = Int(commandsSizeValue)
        let commandStart = machOffset + 32
        let sliceEnd = machOffset + sliceSize
        guard commandsSize >= 0, commandStart <= sliceEnd,
              commandsSize <= sliceEnd - commandStart else {
            throw Error.malformed(filePath)
        }
        let commandEnd = commandStart + commandsSize

        var commandOffset = commandStart
        var firstContentOffset = sliceEnd
        for _ in 0..<commandCount {
            guard data.hasRange(commandOffset, length: 8), commandOffset + 8 <= commandEnd,
                  let command = data.uint32LE(at: commandOffset),
                  let commandSizeValue = data.uint32LE(at: commandOffset + 4) else {
                throw Error.malformed(filePath)
            }
            let commandSize = Int(commandSizeValue)
            guard commandSize >= 8, commandSize <= commandEnd - commandOffset else {
                throw Error.malformed(filePath)
            }

            if command == loadDylibCommand {
                guard commandSize >= 24,
                      let nameOffsetValue = data.uint32LE(at: commandOffset + 8) else {
                    throw Error.malformed(filePath)
                }
                let nameOffset = Int(nameOffsetValue)
                guard nameOffset >= 24, nameOffset < commandSize else {
                    throw Error.malformed(filePath)
                }
                let nameStart = commandOffset + nameOffset
                let nameEndLimit = commandOffset + commandSize
                let nameEnd = (nameStart..<nameEndLimit).first(where: { data[$0] == 0 }) ?? nameEndLimit
                if String(data: data[nameStart..<nameEnd], encoding: .utf8) == installName {
                    return .alreadyInjected(commandOffset: UInt64(commandOffset))
                }
            }

            if command == segment64Command {
                guard commandSize >= 72,
                      let sectionCountValue = data.uint32LE(at: commandOffset + 64),
                      let segmentFileOffset = data.uint64LE(at: commandOffset + 40) else {
                    throw Error.malformed(filePath)
                }
                let sectionCount = Int(sectionCountValue)
                guard sectionCount >= 0, sectionCount <= (commandSize - 72) / 80 else {
                    throw Error.malformed(filePath)
                }
                if sectionCount == 0, segmentFileOffset > 0,
                   let relative = Int(exactly: segmentFileOffset), relative <= sliceSize {
                    firstContentOffset = min(firstContentOffset, machOffset + relative)
                }
                for sectionIndex in 0..<sectionCount {
                    let section = commandOffset + 72 + sectionIndex * 80
                    guard let relativeValue = data.uint32LE(at: section + 48) else {
                        throw Error.malformed(filePath)
                    }
                    let relative = Int(relativeValue)
                    if relative > 0, relative <= sliceSize {
                        firstContentOffset = min(firstContentOffset, machOffset + relative)
                    }
                }
            }
            commandOffset += commandSize
        }
        guard commandOffset == commandEnd, firstContentOffset >= commandEnd else {
            throw Error.malformed(filePath)
        }

        let commandData = makeLoadDylibCommand(installName: installName)
        let available = firstContentOffset - commandEnd
        guard commandData.count <= available else {
            throw Error.insufficientHeaderPadding(required: commandData.count, available: available)
        }
        let insertionRange = commandEnd..<(commandEnd + commandData.count)
        guard data[insertionRange].allSatisfy({ $0 == 0 }) else {
            throw Error.occupiedHeaderPadding
        }
        guard commandCountValue < UInt32.max,
              commandsSizeValue <= UInt32.max - UInt32(commandData.count) else {
            throw Error.malformed(filePath)
        }

        data.replaceSubrange(insertionRange, with: commandData)
        data.setUInt32LE(commandCountValue + 1, at: machOffset + 16)
        data.setUInt32LE(commandsSizeValue + UInt32(commandData.count), at: machOffset + 20)
        return .injected(
            commandOffset: UInt64(commandEnd),
            paddingLeft: available - commandData.count
        )
    }

    private static func makeLoadDylibCommand(installName: String) -> Data {
        let pathBytes = Array(installName.utf8) + [0]
        let commandSize = (24 + pathBytes.count + 7) & ~7
        var data = Data()
        data.appendUInt32LE(loadDylibCommand)
        data.appendUInt32LE(UInt32(commandSize))
        data.appendUInt32LE(24)
        data.appendUInt32LE(2)
        data.appendUInt32LE(0)
        data.appendUInt32LE(0)
        data.append(contentsOf: pathBytes)
        data.append(contentsOf: repeatElement(0, count: commandSize - data.count))
        return data
    }
}

private extension Data {
    func hasRange(_ offset: Int, length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= count && length <= count - offset
    }

    func uint32LE(at offset: Int) -> UInt32? {
        guard hasRange(offset, length: 4) else { return nil }
        return self[offset..<(offset + 4)].enumerated().reduce(0) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
    }

    func uint32BE(at offset: Int) -> UInt32? {
        guard hasRange(offset, length: 4) else { return nil }
        return self[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func uint64LE(at offset: Int) -> UInt64? {
        guard hasRange(offset, length: 8) else { return nil }
        return self[offset..<(offset + 8)].enumerated().reduce(0) {
            $0 | (UInt64($1.element) << UInt64($1.offset * 8))
        }
    }

    func uint64BE(at offset: Int) -> UInt64? {
        guard hasRange(offset, length: 8) else { return nil }
        return self[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    mutating func setUInt32LE(_ value: UInt32, at offset: Int) {
        replaceSubrange(offset..<(offset + 4), with: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }
}
