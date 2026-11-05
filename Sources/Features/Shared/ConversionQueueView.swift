import SwiftUI
import AppKit

/// The batch sheet: one row per extension with its live state, then what to do
/// once it's over.
struct ConversionQueueView: View {
    @ObservedObject var queue: ConversionQueue
    @ObservedObject var vm: ConverterViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title)
                    .font(Theme.Font.headingMD())
                    .foregroundStyle(Theme.Colors.ink)
                Text(subtitle)
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.Colors.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if queue.isRunning {
                ProgressView(value: Double(queue.finishedCount), total: Double(max(queue.items.count, 1)))
                    .tint(Theme.Colors.primary)
            }

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(queue.items) { row($0) }
                }
            }
            .frame(minHeight: 160, maxHeight: 340)

            footer
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
        .background(AmbientBackground())
    }

    private var title: String {
        if queue.isRunning {
            let n = min(queue.finishedCount + 1, queue.items.count)
            return "Converting \(n) of \(queue.items.count)"
        }
        switch queue.stopReason {
        case .needsUpgrade: return "Free conversions used up"
        case .needsXcode:   return "Xcode is needed"
        case .cancelled:    return "Stopped"
        case nil:           return "Finished"
        }
    }

    private var subtitle: String {
        let done = queue.doneCount
        let failed = queue.items.filter { if case .failed = $0.status { return true }; return false }.count
        if queue.isRunning {
            return vm.phase == .idle ? "Getting the next one ready" : vm.phase.title
        }
        var parts = ["\(done) installed"]
        if failed > 0 { parts.append("\(failed) failed") }
        switch queue.stopReason {
        case .needsUpgrade(let browser):
            parts.append("the rest need a \(browser.displayName) license")
        case .needsXcode:
            parts.append("install Xcode, then run the rest again")
        default:
            break
        }
        var text = parts.joined(separator: ", ") + "."
        if done > 0 { text += " Turn them on in Safari's Extensions settings." }
        return text
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if queue.isRunning {
                Spacer()
                Button("Stop") { queue.cancel() }
                    .buttonStyle(.raycastTertiary)
            } else {
                Button("Close") { queue.dismiss() }
                    .buttonStyle(.raycastGhost)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if case .needsUpgrade(let browser) = queue.stopReason {
                    Button("Upgrade") {
                        queue.dismiss()
                        // One sheet at a time per window: let this one leave first.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { vm.presentPaywall(for: browser) }
                    }
                    .buttonStyle(.raycastPrimary)
                } else if queue.doneCount > 0 {
                    Button("Open Safari Settings") {
                        queue.openSafariExtensionSettings()
                        queue.dismiss()
                    }
                    .buttonStyle(.raycastPrimary)
                }
            }
        }
    }

    private func row(_ item: QueueItem) -> some View {
        HStack(spacing: Theme.Space.sm) {
            HistoryIcon(iconData: item.iconPNG,
                        monogram: item.name.first.map(String.init)?.uppercased() ?? "?")
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(Theme.Font.body())
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1).truncationMode(.middle)
                if let detail = detail(item) {
                    Text(detail)
                        .font(Theme.Font.caption())
                        .foregroundStyle(detailColor(item))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            statusIcon(item.status)
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 6)
    }

    private func detail(_ item: QueueItem) -> String? {
        switch item.status {
        case .pending:              return item.note
        case .preparing:            return "Getting it ready"
        case .converting:           return vm.phase == .idle ? "Starting" : vm.phase.title
        case .waiting:              return "Answer the signing question in the Viaduct window"
        case .done:                 return item.note
        case let .failed(why):      return why
        case let .skipped(why):     return why.isEmpty ? nil : why
        }
    }

    private func detailColor(_ item: QueueItem) -> Color {
        if case .failed = item.status { return Theme.Colors.accentRed }
        return Theme.Colors.mute
    }

    @ViewBuilder
    private func statusIcon(_ status: QueueItem.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(Theme.Colors.stone)
        case .preparing, .converting, .waiting:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Colors.accentGreen)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Colors.accentRed)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(Theme.Colors.ash)
        }
    }
}
