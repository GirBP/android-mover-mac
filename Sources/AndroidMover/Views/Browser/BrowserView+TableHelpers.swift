import SwiftUI
import AndroidMoverCore

/// Допоміжні методи для клітинок `table` (BrowserView.swift) — винесені окремим файлом
/// (той самий підхід, що BrowserView+Toolbar.swift/+Alerts.swift), щоб BrowserView.swift
/// лишався ≤400 рядків.
extension BrowserView {
    /// Мініатюра (A3), якщо файл уже проходив Quick Look і QLThumbnailGenerator встиг її
    /// згенерувати; інакше — звичайний SF Symbol, як і раніше.
    @ViewBuilder
    func nameIcon(for entry: RemoteEntry) -> some View {
        if let thumbnail = state.preview.thumbnails.thumbnail(for: entry) {
            // 4.1: картинка 20 px, але ВЕРСТКА займає 16 px (як SF Symbol поряд) — інакше рядки
            // з мініатюрою на 4 px вищі за сусідні і список «дихає» при скролі. Table рядки
            // не обрізають, 2 px виступу зверху/знизу — у межах міжрядкового відступу.
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 3.5))
                .frame(width: 20, height: 16)
        } else {
            Image(systemName: entry.iconName)
                .foregroundStyle(entry.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }

    /// nil, якщо перенесення зараз неможливе (нема adb-шляху чи активного пристрою) —
    /// на практиці таблиця показується лише в stage == .ready, де обидва завжди є.
    /// Symlink відхиляється тут само, як і всюди інде (превʼю, звичайний трансфер) —
    /// це єдиний content-шлях, де раніше не було цього guard-а.
    /// v0.10.2: payload для `TableRow.draggable` — безумовний (рядок завжди має payload,
    /// інакше довелось би будувати різні TableRow у ForEach); недоступність (нема adb/пристрою,
    /// symlink) RemoteFileTransfer.export перевіряє сам у момент дропу.
    func rowDragPayload(for entry: RemoteEntry) -> RemoteFileTransfer {
        RemoteFileTransfer(
            entry: entry,
            adbPath: state.devices.adbPath ?? "",
            serial: state.devices.activeDevice?.serial ?? ""
        )
    }

    /// 3.6: комбінований accessibility-опис рядка таблиці (ім'я+тип+розмір+дата) —
    /// `Table` подає кожну колонку окремим AX-елементом, тому єдиний надійний спосіб дати
    /// VoiceOver один зв'язний опис — повісити його на клітинку "Назва" і сховати решту
    /// колонок (`.accessibilityHidden(true)` на "Розмір"/"Змінено" в BrowserView.swift).
    func rowAccessibilityLabel(for entry: RemoteEntry) -> String {
        var parts = [entry.name, entry.isDirectory ? "тека" : "файл"]
        if !entry.isDirectory {
            parts.append(Format.bytes(entry.size))
        }
        parts.append(Format.date(entry.modified))
        return parts.joined(separator: ", ")
    }
}
