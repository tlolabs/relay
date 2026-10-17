import SwiftUI
import RelayKit

struct APIUsageSettings: View {
    @Bindable var model: RelayModel
    var body: some View {
        Form {
            Section("API connections & usage") {
                VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Check All Connections") { model.beginConnectionChecks() }.disabled(model.checkingConnections || model.plexBusy)
                    if model.checkingConnections {
                        ProgressView().controlSize(.small)
                        Button("Stop") { model.connectionCheckTask?.cancel() }
                    }
                    Spacer()
                    Button("Refresh Stats") { Task { await model.refreshAPIUsage() } }
                }
                Text("Every network attempt, including tests and redirects, counts before it is sent. Failed attempts still use the budget. Cached lookups do not. Caps and counters persist across restarts; there is no reset button.").font(.caption).foregroundStyle(.secondary)
                Text("These are Relay's counts on this Mac, starting with this version. Requests made by other apps or devices are not visible here. Provider-reported limits can pause Relay sooner. Daily/monthly totals use UTC; rolling windows add protection across reset boundaries.").font(.caption).foregroundStyle(.secondary)
                if !model.apiUsageError.isEmpty { Text(model.apiUsageError).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            ForEach(model.apiUsage) { value in APIUsageRow(model: model, value: value) }
            Section("IMDb") { Text("Local dataset index. No online API requests or metered API usage.").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
        .task {
            guard !model.smokeMode else { return }
            while !Task.isCancelled {
                await model.refreshAPIUsage()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }
}

private struct APIUsageRow: View {
    let model: RelayModel
    let value: APIUsageSnapshot
    private var policy: APIUsagePolicy { value.provider.policy }
    var body: some View {
        Section(value.provider.rawValue) {
            VStack(alignment: .leading, spacing: 7) {
            if let check = value.check {
                Label(check.message, systemImage: check.passed ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(check.passed ? Color.green : Color.secondary).font(.callout).textSelection(.enabled)
                Text("Tested \(check.checkedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            } else { Text("Connection not tested yet.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("Today: \(value.today.requests) · Month: \(value.monthRequests) · All time: \(value.lifetime.requests)")
                Spacer()
                Button("Test") { model.beginConnectionChecks(only: value.provider) }.disabled(model.checkingConnections || model.plexBusy)
            }.font(.caption).monospacedDigit()
            budget("Daily / rolling 24h", used: max(value.today.requests, value.rollingDayRequests), cap: policy.daily)
            budget(value.provider == .brave ? "Month / rolling 31 days" : "Monthly", used: value.provider == .brave ? max(value.monthRequests, value.rollingMonthRequests) : value.monthRequests, cap: policy.monthly)
            Text("Today: \(value.today.cacheHits) cached · \(value.today.failures) failed HTTP attempts · \(value.today.blocked) blocked locally").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let until = value.cooldownUntil { Text("Paused until \(until.formatted(date: .abbreviated, time: .standard))").foregroundStyle(.orange).font(.caption) }
            HStack {
                Text(value.lastHTTPStatus.map { "Last HTTP status: \($0)" } ?? "No HTTP response recorded")
                if let remaining = value.remoteRemaining { Text("· Provider last reported \(remaining) remaining") }
            }.font(.caption).foregroundStyle(.secondary)
            if let windows = value.remoteWindows, !windows.isEmpty {
                Text(windows.map { window in
                    let period = window.seconds.map { $0 == 1 ? "1 sec" : $0 >= 2_419_200 ? "month" : "\($0) sec" } ?? "window"
                    return window.limit == 0 ? "Provider \(period): unlimited" : "Provider \(period): \(window.remaining) / \(window.limit) remaining"
                }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            Text(policy.published).font(.caption).foregroundStyle(.secondary)
            Link("Provider limits & terms", destination: URL(string: policy.documentation)!).font(.caption)
            }.padding(.vertical, 4)
        }
    }
    private func budget(_ label: String, used: Int, cap: Int) -> some View {
        HStack {
            Text(label).frame(width: 170, alignment: .leading)
            ProgressView(value: Double(min(used, cap)), total: Double(cap))
            Text("\(used) / \(cap)").monospacedDigit().frame(width: 110, alignment: .trailing)
        }.font(.caption)
    }
}
