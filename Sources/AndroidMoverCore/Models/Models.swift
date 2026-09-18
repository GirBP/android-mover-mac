import Foundation

public struct ADBDevice: Identifiable, Equatable, Hashable, Sendable {
    public enum State: Equatable, Hashable, Sendable {
        case ready          // adb каже "device"
        case unauthorized   // треба підтвердити на екрані телефона
        case offline
        case other(String)
    }

    public let serial: String
    public let state: State
    public let model: String?

    public var id: String { serial }

    public var displayName: String {
        if let model { return model.replacingOccurrences(of: "_", with: " ") }
        return serial
    }

    /// v0.14.0 (Wi-Fi): транспорт видно з форми serial — `host:port` для TCP-пристроїв, інакше
    /// USB/емулятор. Адреса ефемерна (порт змінюється після перезавантаження телефона) —
    /// ідентичність пристрою див. `DeviceIdentity`.
    public var isWireless: Bool { Self.parseHostPort(serial) != nil }

    public static func parseHostPort(_ text: String) -> (host: String, port: Int)? {
        guard let colon = text.lastIndex(of: ":") else { return nil }
        let host = String(text[..<colon])
        let portText = String(text[text.index(after: colon)...])
        guard !host.isEmpty, !host.contains(" "), let port = Int(portText), (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    public init(serial: String, state: State, model: String?) {
        self.serial = serial
        self.state = state
        self.model = model
    }
}

public struct RemoteEntry: Identifiable, Hashable, Sendable {
    public let path: String        // повний шлях на телефоні, без trailing slash
    public let name: String        // базове ім'я
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let size: Int64         // байти (для тек — розмір inode, не вмісту)
    public let modified: Date

    public var id: String { path }

    public init(path: String, name: String, isDirectory: Bool, isSymlink: Bool, size: Int64, modified: Date) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.modified = modified
    }

    /// Порожній запит проходить усе; інакше — регістронезалежний пошук підрядка в імені
    /// (`localizedCaseInsensitiveContains` коректно працює і з кирилицею).
    public func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(query)
    }
}

/// Вільне і загальне місце на томі телефона (A2), байти.
public struct RemoteStorageInfo: Sendable, Equatable {
    public let totalBytes: Int64
    public let availableBytes: Int64

    public init(totalBytes: Int64, availableBytes: Int64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    /// Частка зайнятого місця 0...1 — для ProgressView заповненості в deviceBar.
    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        let used = Double(totalBytes - availableBytes)
        return min(1.0, max(0.0, used / Double(totalBytes)))
    }
}

/// Розширення медіафайлів — для best-effort MediaStore-рескану після delete/move (A6).
public enum MediaKind {
    public static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "dng", "raw",
        "mp4", "mov", "mkv", "avi", "webm", "3gp",
        "mp3", "m4a", "wav", "flac", "ogg", "opus", "aac",
    ]
}

public struct RemoteFileRecord: Equatable, Sendable {
    public let path: String
    public let size: Int64

    public init(path: String, size: Int64) {
        self.path = path
        self.size = size
    }
}

/// Шляхи на телефоні: прості POSIX-утиліти без FileManager-семантики macOS.
public enum RemotePath {
    /// Прибирає лише хвостові слеші. НЕ чіпає пробіли — вони можуть бути частиною
    /// реального імені файлу (обрізання ламало б шляхи з листингу).
    public static func normalized(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        if p.isEmpty { p = "/" }
        return p
    }

    /// Для ВВЕДЕНОГО КОРИСТУВАЧЕМ шляху: обрізає випадкові пробіли навколо і нормалізує.
    public static func userInput(_ path: String) -> String {
        normalized(path.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 1.7: розбиває шлях на компоненти по "/" на рівні UNICODE-СКАЛЯРІВ, а не
    /// Character/grapheme-кластерів. `String.split(separator: "/")` (за замовчуванням
    /// Character-based) хибно ЗЛИВАЄ "/" із НАСТУПНИМ комбінуючим знаком (напр. U+0306) в один
    /// grapheme-кластер (правило "Extend" з UAX #29 для "звичайних" символів, на відміну від
    /// "\n", де категорія Control примусово ставить межу) — тоді "/" перестає збігатися як
    /// окремий символ, і розбиття мовчки ламається для імен, що ПОЧИНАЮТЬСЯ з комбінуючого
    /// знака (реальний файл з телефона з таким іменем існує — знайдено фазз-тестом 1.7).
    /// Порожні компоненти (подвійне "//") не включаються — як і дефолтний split.
    private static func pathComponents(_ path: String) -> [String] {
        var components: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in path.unicodeScalars {
            if scalar == "/" {
                if !current.isEmpty {
                    components.append(String(current))
                    current = String.UnicodeScalarView()
                }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { components.append(String(current)) }
        return components
    }

    public static func baseName(_ path: String) -> String {
        let p = normalized(path)
        guard p != "/" else { return "/" }
        return pathComponents(p).last ?? ""
    }

    public static func parent(_ path: String) -> String {
        let p = normalized(path)
        guard p != "/" else { return "/" }
        let components = pathComponents(p).dropLast()
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    public static func join(_ dir: String, _ name: String) -> String {
        let d = normalized(dir)
        return d == "/" ? "/\(name)" : "\(d)/\(name)"
    }

    /// Обгортає шлях в одинарні лапки для shell телефона. 1.7: пройдено по UNICODE-СКАЛЯРАХ,
    /// а НЕ через `replacingOccurrences(of: "'", with:)` (Character/grapheme-based) — той
    /// варіант мовчки НЕ замінював "'", коли одразу за ним ішов комбінуючий знак (напр.
    /// U+0306): "'" + Extend зливаються в один grapheme-кластер, який більше не збігається з
    /// самотнім Character("'"), і replacingOccurrences тихо нічого не робить — лапка лишається
    /// НЕекранованою, ламаючи shell-квотинг (знайдено фазз-тестом 1.7). На рівні
    /// unicodeScalars така фузія не існує — кожен "'" завжди зіставляється сам із собою.
    public static func shellQuote(_ path: String) -> String {
        var result = String.UnicodeScalarView()
        result.append("'")
        for scalar in path.unicodeScalars {
            if scalar == "'" {
                result.append(contentsOf: "'\\''".unicodeScalars)
            } else {
                result.append(scalar)
            }
        }
        result.append("'")
        return String(result)
    }

    /// Шляхи, які заборонено видаляти. Захищає корені ВСІХ томів (включно зі знімними
    /// SD-картками /storage/XXXX-XXXX) — rm -rf по точці монтування стер би цілий том.
    /// Дозволено видаляти лише вміст УСЕРЕДИНІ тому користувацького сховища.
    public static func isUnsafeToDelete(_ path: String) -> Bool {
        let p = normalized(path)
        guard p.hasPrefix("/") else { return true }
        let components = pathComponents(p)
        // Компоненти ".." могли б вивести rm за межі дозволеного кореня.
        if components.contains("..") || components.contains(".") { return true }

        guard let first = components.first else { return true } // "/"
        switch first {
        case "sdcard":
            // /sdcard/<щось> — ок; сам /sdcard — ні.
            return components.count < 2
        case "storage":
            guard components.count >= 2 else { return true } // /storage
            switch components[1] {
            case "emulated":
                // /storage/emulated/<n>/<щось> — ок; корінь профілю — ні.
                return components.count < 4
            case "self":
                // /storage/self/primary/<щось> — ок.
                return components.count < 4
            default:
                // Знімний том /storage/XXXX-XXXX: сам корінь тому чіпати не можна,
                // /storage/XXXX-XXXX/<щось> — можна.
                return components.count < 3
            }
        default:
            // Усе поза користувацьким сховищем (у т.ч. /data, /mnt, /system) — не чіпаємо.
            return true
        }
    }

    /// Шляхи, куди дозволено ПИСАТИ (push, B1). На відміну від isUnsafeToDelete — сам корінь
    /// /sdcard чи будь-якого тому під /storage/... писати можна (mkdir/push туди безпечні,
    /// на відміну від rm -rf кореня, який стер би точку монтування). Захищає лише те, що поза
    /// користувацьким сховищем (/data, /system, /mnt тощо), і компоненти "." / "..", якими
    /// можна було б вибратись за межі дозволеного префікса попри текстовий збіг.
    public static func isAllowedPushTarget(_ path: String) -> Bool {
        let p = normalized(path)
        guard p.hasPrefix("/") else { return false }
        let components = pathComponents(p)
        guard !components.contains("..") && !components.contains(".") else { return false }
        return p == "/sdcard" || p.hasPrefix("/sdcard/") || p.hasPrefix("/storage/")
    }
}
