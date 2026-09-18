import Foundation

public enum ADBInstallerError: LocalizedError {
    case downloadFailed(String)
    case unzipFailed(String)
    case adbNotInArchive
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let details):
            return "Не вдалося завантажити platform-tools: \(details)"
        case .unzipFailed(let details):
            return "Не вдалося розпакувати архів: \(details)"
        case .adbNotInArchive:
            return "В архіві немає adb — можливо, завантаження пошкоджене."
        case .verificationFailed(let details):
            return "Встановлений adb не запускається: \(details)"
        }
    }
}

/// Завантажує офіційний platform-tools від Google в Application Support і повертає шлях до adb.
/// Викликається лише за явним кліком користувача в інтерфейсі.
public final class ADBInstaller: Sendable {
    public static let downloadURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!

    public init() {}

    /// Стрімить архів прямо у файл через downloadTask; прогрес — з task.progress.
    /// onProgress: частка 0…1, або nil поки сервер не віддав Content-Length.
    static func download(
        _ url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        let observationBox = LockedBox<NSKeyValueObservation>()
        defer { observationBox.value?.invalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                if let error {
                    continuation.resume(throwing: ADBInstallerError.downloadFailed(
                        "\(error.localizedDescription) Перевірте інтернет-з'єднання."
                    ))
                    return
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    continuation.resume(throwing: ADBInstallerError.downloadFailed("HTTP \(http.statusCode)"))
                    return
                }
                guard let location else {
                    continuation.resume(throwing: ADBInstallerError.downloadFailed("порожня відповідь сервера"))
                    return
                }
                do {
                    // Тимчасовий файл живе лише до кінця цього замикання — переносимо одразу.
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: ADBInstallerError.downloadFailed(error.localizedDescription))
                }
            }
            observationBox.value = task.progress.observe(\.fractionCompleted) { progress, _ in
                onProgress(progress.totalUnitCount > 0 ? progress.fractionCompleted : nil)
            }
            task.resume()
        }
        onProgress(1.0)
    }

    public func install(onProgress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws -> String {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroidMover", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)

        let zipURL = support.appendingPathComponent("platform-tools.zip")
        try await Self.download(Self.downloadURL, to: zipURL, onProgress: onProgress)
        defer { try? fileManager.removeItem(at: zipURL) }

        let toolsDir = support.appendingPathComponent("platform-tools", isDirectory: true)
        try? fileManager.removeItem(at: toolsDir)

        let unzip = try await ProcessRunner.run(
            executable: "/usr/bin/unzip",
            arguments: ["-o", "-q", zipURL.path, "-d", support.path],
            timeout: 300
        )
        guard unzip.exitCode == 0 else {
            throw ADBInstallerError.unzipFailed(unzip.err.isEmpty ? "код \(unzip.exitCode)" : unzip.err)
        }

        let adbPath = toolsDir.appendingPathComponent("adb").path
        guard fileManager.fileExists(atPath: adbPath) else {
            throw ADBInstallerError.adbNotInArchive
        }
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbPath)

        let check = try await ProcessRunner.run(executable: adbPath, arguments: ["version"], timeout: 30)
        guard check.exitCode == 0, check.out.contains("Android Debug Bridge") else {
            throw ADBInstallerError.verificationFailed(check.err.isEmpty ? check.out : check.err)
        }
        return adbPath
    }
}
