import Foundation

/// The one JSON configuration the app uses.
///
/// Dates are stored as seconds since 1970 rather than ISO-8601 strings.
/// ISO-8601 truncates below the second, which means a saved and reloaded
/// session is not byte-for-byte the document that was saved — a difference that
/// is invisible day to day and extremely confusing the first time recovery
/// appears to "change" an edit. The session file is machine-readable anyway, so
/// exactness is worth more here than human-readable timestamps.
enum FramesJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
