import Foundation
import ImageIO
import CoreGraphics

/// Мініатюра фото з ПЕРШИХ байтів файла — JPEG тримає EXIF-thumbnail в
/// APP1-сегменті (≤64 КБ за стандартом), HEIC — 'thmb'-айтем у meta-боксі на початку файла.
/// Тому замість стягування цілого фото (5–20 МБ) читаємо `headBytes` через `adb exec-out head`
/// і віддаємо ImageIO лише ВБУДОВАНУ мініатюру (без декодування повного зображення, якого
/// в нас і нема). Нема вбудованої — nil, і викликач запам'ятовує «мініатюри нема».
public enum EmbeddedThumbnail {
    /// 64 КБ: EXIF APP1 обмежений 65 535 байтами; головна мініатюра HEIC теж укладається.
    public static let headBytes = 65_536
    /// Лише формати, що реально носять вбудовану мініатюру: PNG/GIF/WebP її не мають
    /// (там довелося б декодувати всю картинку), відео — окрема історія.
    public static let supportedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "dng"]

    public static func supports(name: String) -> Bool {
        supportedExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Вбудована мініатюра з (можливо, обрізаних) перших байтів файла; `maxPixelSize` — довша
    /// сторона. Інкрементальне джерело: ImageIO знає, що дані неповні, і не намагається
    /// читати за їхніми межами. `CreateThumbnailFromImageIfAbsent: false` — жодного
    /// декодування повного зображення (його в буфері нема), лише готова мініатюра.
    public static func extract(from head: Data, maxPixelSize: Int) -> CGImage? {
        guard !head.isEmpty, let source = CGImageSourceCreateIncremental(nil) as CGImageSource? else { return nil }
        CGImageSourceUpdateData(source, head as CFData, false)
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// JPEG-байти для дискового кешу (мініатюра ≤160 px → ~3–6 КБ).
    public static func jpegData(_ image: CGImage, quality: Double = 0.8) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
