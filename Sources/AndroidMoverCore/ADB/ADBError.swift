import Foundation

public enum ADBError: LocalizedError, Equatable {
    case adbNotFound
    case timeout(String)
    case commandFailed(command: String, code: Int32, stderr: String)
    case notADirectory(String)
    case toyboxMissing
    case unsafeDeletePath(String)
    case deleteFailed(String)
    case mkdirFailed(String)
    case renameFailed(String)
    case alreadyExists(String)
    case invalidName(String)
    case verificationFailed(String)
    case pullProducedNothing(String)
    case notEnoughDiskSpace(needed: Int64, available: Int64)
    /// v0.12.2 (M1, аудит M3): бракує місця НА ТЕЛЕФОНІ під push — чесна відмова до першого байта.
    case notEnoughSpaceOnDevice(needed: Int64, available: Int64)
    /// v0.14.0 (Wi-Fi): pair/connect/mdns не вдалися — текст із виводу adb.
    case wirelessFailed(String)
    case destinationNotWritable(String)
    case statFailed(String)
    case cancelled
    case unsafePushTarget(String)
    case pushVerificationFailed(String)
    /// v0.11.0 (P1): md5 копії не збігається з телефоном — файл перепулюється (resumable).
    case checksumMismatch(String)
    /// v0.11.0 (P6): файла/теки на телефоні більше нема (видалено після лістингу) — не resumable.
    case remoteMissing(String)

    public var errorDescription: String? {
        switch self {
        case .adbNotFound:
            return "ADB не знайдено. Встановіть його через додаток або Homebrew."
        case .timeout(let what):
            return "Команда не відповіла вчасно: \(what). Перевірте кабель і розблокуйте телефон."
        case .commandFailed(let command, let code, let stderr):
            let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Команда «\(command)» завершилась з кодом \(code)." + (details.isEmpty ? "" : " \(details)")
        case .notADirectory(let path):
            return "Тека «\(path)» не існує на телефоні."
        case .toyboxMissing:
            return "Телефон не підтримує потрібні команди (toybox відсутній). Потрібен Android 6 або новіший."
        case .unsafeDeletePath(let path):
            return "Відмова видаляти системний шлях «\(path)»."
        case .deleteFailed(let path):
            return "Не вдалося видалити «\(path)» з телефона."
        case .mkdirFailed(let path):
            return "Не вдалося створити теку «\(path)»."
        case .renameFailed(let details):
            return "Не вдалося перейменувати: \(details)"
        case .alreadyExists(let name):
            return "«\(name)» уже існує в цій теці."
        case .invalidName(let name):
            return "Недопустиме ім'я «\(name)»: без «/» і порожніх імен."
        case .verificationFailed(let details):
            return "Перевірка копії не пройшла — файли з телефона НЕ видалено. \(details)"
        case .pullProducedNothing(let path):
            return "ADB не скопіював «\(path)» — файл міг зникнути або бути недоступним."
        case .notEnoughDiskSpace(let needed, let available):
            let f = ByteCountFormatter.string(fromByteCount:countStyle:)
            return "Недостатньо місця на диску: потрібно \(f(needed, .file)), вільно \(f(available, .file))."
        case .notEnoughSpaceOnDevice(let needed, let available):
            let f = ByteCountFormatter.string(fromByteCount:countStyle:)
            return "Недостатньо місця на телефоні: потрібно \(f(needed, .file)), вільно \(f(available, .file))."
        case .wirelessFailed(let details):
            return "Wi-Fi: \(details)"
        case .destinationNotWritable(let path):
            return "Тека призначення недоступна для запису: «\(path)». Перевірте, чи підключено диск і чи він не «лише для читання» (NTFS на Mac — лише читання)."
        case .statFailed(let path):
            return "Не вдалося визначити вільне місце для «\(path)»."
        case .cancelled:
            return "Операцію скасовано."
        case .unsafePushTarget(let path):
            return "Відмова записувати в системний шлях «\(path)»."
        case .remoteMissing(let path):
            return "«\(path)» на телефоні більше не існує — можливо, видалено або перейменовано після відкриття теки."
        case .checksumMismatch(let path):
            return "Контрольна сума копії не збігається з телефоном: «\(path)». Файл буде перекопійовано."
        case .pushVerificationFailed(let details):
            return "Перевірка копії на телефоні не пройшла — файл НЕ додано у видиму теку. \(details)"
        }
    }
}
