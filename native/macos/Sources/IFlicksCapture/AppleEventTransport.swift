import AppKit
import Carbon
import Foundation

/// This transport has no launch API and no write/send-process commands. The
/// address is a kernel PID, so a stale target cannot relaunch the application.
public actor AppleEventTransport: IFlicksTransport {
    static func code(_ value: String) -> UInt32 {
        value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    static let properties = ["ID  ", "pSts", "file", "pPrg"]
    static func request(pid: Int32, property: String) -> NSAppleEventDescriptor {
        precondition(properties.contains(property))
        let videos = NSAppleEventDescriptor.record()
        videos.setDescriptor(NSAppleEventDescriptor(typeCode: code("ivid")), forKeyword: AEKeyword(keyAEDesiredClass))
        videos.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formAbsolutePosition)), forKeyword: AEKeyword(keyAEKeyForm))
        // 'all ' is an absolute ordinal ('abso'), not an enumeration
        // ('enum'). Cocoa rejects the latter with errAECoercionFail (-1700).
        let ordinalData = withUnsafeBytes(of: OSType(kAEAll)) { Data($0) }
        videos.setDescriptor(NSAppleEventDescriptor(descriptorType: OSType(typeAbsoluteOrdinal), data: ordinalData)!, forKeyword: AEKeyword(keyAEKeyData))
        videos.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        let prop = NSAppleEventDescriptor.record()
        prop.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        prop.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        prop.setDescriptor(NSAppleEventDescriptor(typeCode: code(property)), forKeyword: AEKeyword(keyAEKeyData))
        prop.setDescriptor(videos.coerce(toDescriptorType: OSType(typeObjectSpecifier))!, forKeyword: AEKeyword(keyAEContainer))
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid), returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(prop.coerce(toDescriptorType: OSType(typeObjectSpecifier))!, forKeyword: AEKeyword(keyDirectObject))
        return event
    }
    static func queryFailure(property: String, code: Int, detail: String?) -> IFlicksQueryFailure {
        let name = ["ID  ": "id", "pSts": "status", "file": "file", "pPrg": "progress"][property] ?? property
        let explanation = detail ?? (code == -1700 ? "Apple-event type conversion failed" : "Apple-event query failed")
        return IFlicksQueryFailure(code, "Read video \(name) [\(property)]: \(explanation) (\(code))")
    }
    public init() {}
    public func sample(process: IFlicksProcess, timeout: TimeInterval) async throws -> [IFlicksVideo] {
        let deadline = ProcessInfo.processInfo.systemUptime + min(1, timeout)
        func read(_ property: String) throws -> [NSAppleEventDescriptor] {
            guard IFlicksProcess.running() == process else { throw IFlicksQueryFailure(-600, "iFlicks process is no longer running") }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Self.queryFailure(property: property, code: -1712, detail: "One-second query timeout") }
            let reply: NSAppleEventDescriptor
            do {
                reply = try Self.request(pid: process.pid, property: property).sendEvent(
                    options: [.waitForReply, .neverInteract, .dontRecord, NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAEDontReconnect))], timeout: remaining)
            } catch {
                let error = error as NSError
                throw Self.queryFailure(property: property, code: error.code, detail: error.code == -1712 ? "One-second query timeout" : error.localizedDescription)
            }
            if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
                throw Self.queryFailure(property: property, code: Int(error.int32Value), detail: reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue)
            }
            guard let result = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { throw Self.queryFailure(property: property, code: -1700, detail: "Missing query result") }
            if result.descriptorType == OSType(typeAEList) {
                return (0..<result.numberOfItems).compactMap { result.atIndex($0 + 1) }
            }
            return [result]
        }
        func ids(_ values: [NSAppleEventDescriptor]) throws -> [String] {
            try values.map {
                guard let id = $0.stringValue, !id.isEmpty else { throw IFlicksQueryFailure(-1700, "Invalid video ID") }
                return id
            }
        }
        let before = try ids(read("ID  "))
        let statuses = try read("pSts"), files = try read("file"), progress = try read("pPrg")
        let after = try ids(read("ID  "))
        guard before == after, statuses.count == before.count, files.count == before.count, progress.count == before.count else {
            throw IFlicksQueryFailure(-1700, "Queue changed during query; incomplete sample discarded")
        }
        let names = ["kUkn": "unknown", "kQue": "queued", "kWrk": "working", "kCpl": "completed", "kErr": "failed", "kCld": "cancelled"]
        return before.indices.map { index in
            let raw = statuses[index].enumCodeValue
            let code = String(bytes: [UInt8((raw >> 24) & 255), UInt8((raw >> 16) & 255), UInt8((raw >> 8) & 255), UInt8(raw & 255)], encoding: .macOSRoman) ?? "unknown"
            let url = files[index].coerce(toDescriptorType: OSType(typeFileURL)).flatMap { String(data: $0.data, encoding: .utf8) }.flatMap(URL.init(string:))
            let amount = progress[index].coerce(toDescriptorType: OSType(typeSInt64)).flatMap { $0.stringValue }.flatMap(Int64.init)
                ?? progress[index].coerce(toDescriptorType: OSType(typeSInt32)).map { Int64($0.int32Value) }
            return IFlicksVideo(id: before[index], status: names[code] ?? "unknown", statusCode: code,
                progress: amount, filePath: url?.isFileURL == true ? url?.path : nil,
                fileError: url?.isFileURL == true ? nil : "Reported file is missing or cannot be decoded as a file URL")
        }
    }
}
