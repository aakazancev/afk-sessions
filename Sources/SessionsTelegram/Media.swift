import Foundation

/// Файл для multipart-запроса Bot API.
public struct UploadFile: Sendable, Equatable {
    public let field: String
    public let filename: String
    public let mime: String
    public let data: Data
    public init(field: String, filename: String, mime: String, data: Data) {
        self.field = field; self.filename = filename; self.mime = mime; self.data = data
    }
}

public enum MediaKind: Sendable { case photo, document }

/// Картинка для отправки: имя файла и содержимое. Читает файлы вызывающий.
public struct MediaFile: Sendable, Equatable {
    public let filename: String
    public let data: Data
    public init(filename: String, data: Data) { self.filename = filename; self.data = data }

    func upload(field: String) -> UploadFile {
        let ext = (filename as NSString).pathExtension.lowercased()
        let mime = ext == "png" ? "image/png" : (ext == "jpg" || ext == "jpeg") ? "image/jpeg" : "application/octet-stream"
        return UploadFile(field: field, filename: filename, mime: mime, data: data)
    }
}

public struct ImageInfo: Sendable {
    public let bytes: Int
    public let width: Int
    public let height: Int
    public init(bytes: Int, width: Int, height: Int) { self.bytes = bytes; self.width = width; self.height = height }
}

/// Лимиты Telegram: что можно слать фото, а что только документом.
public enum MediaPlan {
    public static func fitsPhoto(_ i: ImageInfo) -> Bool {
        guard i.width > 0, i.height > 0 else { return false }
        return i.bytes <= 10 * 1024 * 1024
            && i.width + i.height <= 10_000
            && max(i.width, i.height) <= 20 * min(i.width, i.height)
    }

    public static func fitsDocument(bytes: Int) -> Bool { bytes <= 50 * 1024 * 1024 }
}

public enum Multipart {
    /// multipart/form-data: поля по алфавиту (детерминированно), затем файлы.
    public static func body(boundary: String, fields: [String: String], files: [UploadFile]) -> Data {
        var d = Data()
        func add(_ s: String) { d.append(Data(s.utf8)) }
        for k in fields.keys.sorted() {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(fields[k]!)\r\n")
        }
        for f in files {
            // Кавычки и переводы строк в имени сломали бы заголовок.
            let name = String(f.filename.map { "\"\r\n".contains($0) ? "_" : $0 })
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(f.field)\"; filename=\"\(name)\"\r\nContent-Type: \(f.mime)\r\n\r\n")
            d.append(f.data)
            add("\r\n")
        }
        add("--\(boundary)--\r\n")
        return d
    }
}
