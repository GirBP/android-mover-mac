import SwiftUI
import AndroidMoverCore

/// Settings-сцена (⌘,) — фундамент для майбутніх налаштувань. Поки що лише історія операцій (A5).
struct SettingsView: View {
    @AppStorage("history.enabled") private var historyEnabled = true
    /// v0.11.0 (P1): коли звіряти md5 копії з телефоном (TransferCoordinator.checksumPolicy).
    @AppStorage("transfer.checksumPolicy") private var checksumPolicy = ChecksumPolicy.beforeDelete.rawValue
    /// 4.1: мініатюри фото з перших 64 КБ файла на телефоні (ThumbnailCache+Remote).
    @AppStorage(ThumbnailCache.remoteThumbnailsDefaultsKey) private var remoteThumbnails = true
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Picker("Контрольна сума копії (md5)", selection: $checksumPolicy) {
                Text("Перед видаленням з телефона (рекомендовано)").tag(ChecksumPolicy.beforeDelete.rawValue)
                Text("Завжди — і при копіюванні (повільніше)").tag(ChecksumPolicy.always.rawValue)
                Text("Ніколи — лише розміри").tag(ChecksumPolicy.never.rawValue)
            }
            .pickerStyle(.radioGroup)
            .help("Телефон рахує md5 (~50–200 МБ/с), Mac — свій; розбіжність → файл перекопіюється, з телефона нічого не видаляється.")

            Divider()

            Toggle("Мініатюри фото з телефона", isOn: $remoteThumbnails)
                .help("Для видимих JPEG/HEIC читає лише перші 64 КБ файла — вбудовану EXIF-мініатюру, не ціле фото. Результат кешується на Mac.")

            Divider()

            Toggle("Вести історію операцій", isOn: $historyEnabled)
                .help("Копіювання, переміщення і видалення файлів записуються в локальний журнал на цьому Mac.")

            Button("Очистити історію…", role: .destructive) {
                confirmingClear = true
            }
            .help("Видаляє весь журнал операцій. Працює незалежно від тумблера вище.")
        }
        .padding(20)
        .frame(width: 440)
        .confirmationDialog(
            "Очистити всю історію операцій?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Очистити", role: .destructive) {
                try? HistoryStore(fileURL: HistoryStore.defaultURL).clear()
                NotificationCenter.default.post(name: .androidMoverHistoryDidChange, object: nil)
            }
            Button("Скасувати", role: .cancel) {}
        } message: {
            Text("Дію не можна скасувати. Файли на Mac і телефоні не зачіпаються.")
        }
    }
}
