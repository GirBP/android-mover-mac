import Foundation
import AndroidMoverCore

/// 2.5 (Swift 6 strict): формат-кеші (ByteCountFormatter/DateFormatter) не Sendable — усі
/// виклики й так ідуть з MainActor-ізольованих View, тому саме сховище ізолюємо явно.
@MainActor
enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH:mm"
        return f
    }()

    /// v0.10.4: залишок часу людською мовою: «45 с», «2 хв», «1 год 05 хв».
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return String(localized: "\(total) с") }
        let minutes = total / 60
        if minutes < 60 { return String(localized: "\(minutes) хв") }
        let hours = minutes / 60
        let rest = minutes % 60
        return String(localized: "\(hours) год \(String(format: "%02d", rest)) хв")
    }

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: value)
    }

    static func date(_ value: Date) -> String {
        dateFormatter.string(from: value)
    }
}

extension RemoteEntry {
    var iconName: String {
        if isDirectory { return "folder.fill" }
        if isSymlink { return "link" }
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "dng", "raw":
            return "photo"
        case "mp4", "mov", "mkv", "avi", "webm", "3gp", "m4v":
            return "film"
        case "mp3", "m4a", "wav", "flac", "ogg", "opus", "aac":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "doc", "docx", "txt", "rtf", "odt":
            return "doc.text"
        case "zip", "rar", "7z", "tar", "gz":
            return "archivebox"
        case "apk":
            return "app.gift"
        default:
            return "doc"
        }
    }
}
