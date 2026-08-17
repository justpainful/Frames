import Foundation

/// The one JSON configuration the app uses.
///
/// Dates are stored as whole milliseconds since 1970. Neither ISO-8601 strings
/// nor `secondsSince1970` doubles survive a round trip exactly — the first
/// truncates below the second, the second goes through a decimal
/// representation — and a document that is not byte-for-byte itself after
/// being saved and reloaded is a very confusing thing to debug the first time
/// recovery appears to "change" an edit.
///
/// Integer milliseconds are exactly representable in JSON, which makes the
/// round trip exact. `Date.framesNow()` creates document timestamps at the same
/// resolution, so a freshly made document is already in the representable set.
enum FramesJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int((date.timeIntervalSince1970 * 1000).rounded()))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let milliseconds = try container.decode(Int.self)
            return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }
        return decoder
    }
}

extension Date {
    /// Now, at the resolution the session file stores.
    ///
    /// Every timestamp that goes into a document is created through this, so
    /// saving and reloading returns the same value rather than one a few
    /// microseconds away.
    static func framesNow() -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
