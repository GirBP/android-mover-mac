import SwiftUI
import AndroidMoverCore

/// Банер над таблицею — знайдено незавершену операцію (крах/вимкнення/kill посеред
/// перенесення, або «скопійовано, але не видалено»). Показує перший запис журналу;
/// «Продовжити» ставить решту в чергу (і довидаляє після повторної перевірки), «Відхилити» —
/// прибирає запис. Копії на Mac у tmp-теках не чіпаються — їх прибере sweep.
struct RecoveryBanner: View {
    let record: JournalRecord
    let message: String?
    let onResume: () -> Void
    let onDismiss: () -> Void

    private var summary: String {
        let pending = record.pendingEntries.count
        let cleanup = record.copiedNotDeletedEntries.count
        var parts: [String] = []
        if pending > 0 { parts.append(String(localized: "не перенесено: \(pending)")) }
        if cleanup > 0 { parts.append(String(localized: "довидалити з телефона: \(cleanup)")) }
        let kind = record.kind == .pull
            ? (record.move ? String(localized: "переміщення на Mac") : String(localized: "копіювання на Mac"))
            : String(localized: "копіювання на телефон")
        return "\(kind) · \(Format.date(record.startedAt)) · \(record.deviceLabel) · " + parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Незавершена операція")
                        .font(.callout.weight(.medium))
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Відхилити") { onDismiss() }
                    .help("Забути про цю операцію. Файли на Mac і телефоні не чіпаються.")
                Button("Продовжити") { onResume() }
                    .buttonStyle(.borderedProminent)
                    .help("Перенести решту і довидалити перевірені копії з телефона")
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}
