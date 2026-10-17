import AppKit
import Carbon
import Foundation
import IFlicksCapture

/// Mutations are restricted to the exact per-video ID bound by the approved
/// import. No global rules, presets, destinations or preferences are changed.
public actor IFlicksController: IFlicksTransport {
    private let reader: any IFlicksTransport
    private let sender: any IFlicksEventSending
    private let pollAttempts: Int
    private let pollDelay: Duration
    public init(sender: any IFlicksEventSending = NativeIFlicksEventSender(), reader: any IFlicksTransport = AppleEventTransport(), pollAttempts: Int = 30, pollDelay: Duration = .milliseconds(250)) {
        self.sender = sender; self.reader = reader; self.pollAttempts = pollAttempts; self.pollDelay = pollDelay
    }
    public func sample(process: IFlicksProcess, timeout: TimeInterval) async throws -> [IFlicksVideo] {
        try await reader.sample(process: process, timeout: timeout)
    }
    private static func code(_ value: String) -> UInt32 { value.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    public static func processIdentity(_ process: IFlicksProcess) -> String { "\(process.pid):\(process.launchUnixMs ?? 0)" }
    static func object(id: String) -> NSAppleEventDescriptor {
        let value = NSAppleEventDescriptor.record()
        value.setDescriptor(NSAppleEventDescriptor(typeCode: code("ivid")), forKeyword: AEKeyword(keyAEDesiredClass))
        value.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formUniqueID)), forKeyword: AEKeyword(keyAEKeyForm))
        value.setDescriptor(NSAppleEventDescriptor(string: id), forKeyword: AEKeyword(keyAEKeyData))
        value.setDescriptor(.null(), forKeyword: AEKeyword(keyAEContainer))
        return value.coerce(toDescriptorType: OSType(typeObjectSpecifier))!
    }
    static func property(_ name: String, id: String) -> NSAppleEventDescriptor {
        let value = NSAppleEventDescriptor.record()
        value.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        value.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        value.setDescriptor(NSAppleEventDescriptor(typeCode: code(name)), forKeyword: AEKeyword(keyAEKeyData))
        value.setDescriptor(object(id: id), forKeyword: AEKeyword(keyAEContainer))
        return value.coerce(toDescriptorType: OSType(typeObjectSpecifier))!
    }
    private func send(process: IFlicksProcess, suite: String, command: String, direct: NSAppleEventDescriptor, data: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor {
        try sender.send(process: process, suite: suite, command: command, direct: direct, data: data)
    }
    public func importVideo(path: String, process: IFlicksProcess, existing: [IFlicksVideo]) async throws -> IFlicksVideo {
        guard !existing.contains(where: { $0.filePath == path }) else { throw RelayFailure.message("This exact input is already in iFlicks. Inspect it before binding; it was not imported again.") }
        let url = URL(fileURLWithPath: path).absoluteString
        let files = NSAppleEventDescriptor.list()
        files.insert(NSAppleEventDescriptor(descriptorType: OSType(typeFileURL), data: Data(url.utf8))!, at: 1)
        // Open can time out after iFlicks has accepted the file. Resolve that
        // single intent by observing the queue; never send the import twice.
        do { _ = try send(process: process, suite: "aevt", command: "odoc", direct: files) }
        catch let failure as IFlicksCommandFailure where failure.code == -1712 {}
        catch let failure as NSError where failure.code == -1712 {}
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        let previous = Set(existing.map(\.id))
        for _ in 0..<pollAttempts {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            let videos: [IFlicksVideo]
            do { videos = try await sample(process: process, timeout: 1) }
            catch let failure as IFlicksQueryFailure where failure.code == -1712 {
                try await Task.sleep(for: pollDelay); continue
            }
            let matches = videos.filter { !previous.contains($0.id) && $0.filePath == path }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw RelayFailure.message("Multiple imported objects report this input; automatic binding stopped") }
            try await Task.sleep(for: pollDelay)
        }
        throw RelayFailure.message("Import outcome is uncertain. Inspect iFlicks; RELAY will not resubmit this input automatically.")
    }
    private func get(_ name: String, id: String, process: IFlicksProcess) throws -> NSAppleEventDescriptor {
        try send(process: process, suite: "core", command: "getd", direct: Self.property(name, id: id))
    }
    private func set(_ name: String, id: String, process: IFlicksProcess, value: NSAppleEventDescriptor) throws {
        let allowed = ["pKnd", "pShw", "pnam", "pSeN", "pEpN", "pEpD", "pRlD"]
        guard allowed.contains(name) else { throw RelayFailure.message("Unapproved metadata property") }
        _ = try send(process: process, suite: "core", command: "setd", direct: Self.property(name, id: id), data: value)
    }
    public func applyMetadata(_ identity: MediaIdentity, id: String, process: IFlicksProcess) throws {
        let status = try get("pSts", id: id, process: process).enumCodeValue
        guard status != Self.code("kWrk"), status != Self.code("kCpl") else {
            throw RelayFailure.message("iFlicks already started this object. RELAY did not change its metadata. Review its output/identity manually.")
        }
        if identity.kind == "tv" {
            try set("pKnd", id: id, process: process, value: NSAppleEventDescriptor(enumCode: Self.code("kVdT")))
            try set("pShw", id: id, process: process, value: NSAppleEventDescriptor(string: identity.title))
            try set("pSeN", id: id, process: process, value: NSAppleEventDescriptor(int32: Int32(identity.season ?? 0)))
            try set("pEpN", id: id, process: process, value: NSAppleEventDescriptor(int32: Int32(identity.episode ?? 0)))
            try set("pEpD", id: id, process: process, value: NSAppleEventDescriptor(string: String(format: "S%02dE%02d", identity.season ?? 0, identity.episode ?? 0)))
            if !identity.episodeTitle.isEmpty { try set("pnam", id: id, process: process, value: NSAppleEventDescriptor(string: identity.episodeTitle)) }
        } else {
            try set("pKnd", id: id, process: process, value: NSAppleEventDescriptor(enumCode: Self.code("kVdM")))
            try set("pnam", id: id, process: process, value: NSAppleEventDescriptor(string: identity.title))
            if let date = identity.releaseDate {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
                if let value = formatter.date(from: date) { try set("pRlD", id: id, process: process, value: NSAppleEventDescriptor(date: value)) }
            }
        }
    }
    public func verifyMetadata(_ identity: MediaIdentity, id: String, process: IFlicksProcess) throws {
        func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        if identity.kind == "tv" {
            let show = try get("pShw", id: id, process: process).stringValue ?? ""
            let season = try get("pSeN", id: id, process: process).int32Value
            let episode = try get("pEpN", id: id, process: process).int32Value
            let title = try get("pnam", id: id, process: process).stringValue ?? ""
            guard normalized(show) == normalized(identity.title), Int(season) == identity.season, Int(episode) == identity.episode,
                  identity.episodeTitle.isEmpty || normalized(title) == normalized(identity.episodeTitle) else { throw RelayFailure.message("iFlicks identity conflicts with the approved show/season/episode. Correct it in iFlicks, then Verify & Start.") }
        } else {
            let name = try get("pnam", id: id, process: process).stringValue ?? ""
            let date = try get("pRlD", id: id, process: process).dateValue
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let year = date.map { calendar.component(.year, from: $0) }
            guard normalized(name) == normalized(identity.title), year == identity.year else { throw RelayFailure.message("iFlicks movie title/year differs from the approved identity. Correct it in iFlicks, then Verify & Start.") }
        }
    }
    public func start(id: String, process: IFlicksProcess) throws {
        let status = try get("pSts", id: id, process: process).enumCodeValue
        guard status != Self.code("kWrk"), status != Self.code("kCpl") else { return }
        _ = try send(process: process, suite: "iFls", command: "Strt", direct: Self.object(id: id))
    }
}


public protocol IFlicksEventSending: Sendable {
    func send(process: IFlicksProcess, suite: String, command: String, direct: NSAppleEventDescriptor, data: NSAppleEventDescriptor?) throws -> NSAppleEventDescriptor
}
public struct NativeIFlicksEventSender: IFlicksEventSending {
    public init() {}
    public func send(process: IFlicksProcess, suite: String, command: String, direct: NSAppleEventDescriptor, data: NSAppleEventDescriptor?) throws -> NSAppleEventDescriptor {
        guard IFlicksProcess.running() == process else { throw RelayFailure.message("The bound iFlicks process exited or restarted") }
        let request = NSAppleEventDescriptor(eventClass: suite.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }, eventID: command.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }, targetDescriptor: NSAppleEventDescriptor(processIdentifier: process.pid), returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        request.setParam(direct, forKeyword: AEKeyword(keyDirectObject))
        if let data { request.setParam(data, forKeyword: AEKeyword(keyAEData)) }
        let response: NSAppleEventDescriptor
        do { response = try request.sendEvent(options: [.waitForReply, .neverInteract, .dontRecord, NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAEDontReconnect))], timeout: 1) }
        catch { throw IFlicksCommandFailure(code: (error as NSError).code, message: "iFlicks \(suite)/\(command): \(error.localizedDescription)") }
        if let error = response.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
            throw RelayFailure.message("iFlicks \(suite)/\(command) failed (\(error.int32Value)): \(response.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue ?? "Check the queue and Automation permission")")
        }
        return response.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) ?? .null()
    }
}

public struct IFlicksCommandFailure: LocalizedError, Sendable {
    public var code: Int
    public var message: String
    public var errorDescription: String? { message }
    public init(code: Int, message: String) { self.code = code; self.message = message }
}
