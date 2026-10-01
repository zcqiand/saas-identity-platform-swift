import Foundation
import SaasSharedGenerated

// REQ-2026-008: family wire date shapes vs the generated formatter.
// The generated OpenISO8601DateFormatter only parses 'T'-separated RFC3339,
// but family backends emit space-separated + bare offsets on the admin
// surfaces (live probe 2026-10-01 @5101):
//   /me                -> 2026-01-20T08:00:00.000Z      (generated OK)
//   admin/tenants      -> 2026-03-10 18:00:00+08       (decode would throw)
//   menus (SysMenu)    -> 2026-08-30 00:07:19.257+08   (decode would throw)
// We install THIS formatter through the generated public hook
// `CodableHelper.dateFormatter` (the generator's designed customization
// point, same spirit as APIClient.bootstrap) - no Generated/ file is
// touched. Format chain: space variants first, then the generated ISO
// fallback so the /me surface keeps its old behavior. Encoding (string(from:))
// stays ISO to keep request bodies unchanged.

/// Multi-format date formatter for the family wire shapes. Install via
/// `CodableHelper.dateFormatter = FamilyDateFormatter()` at bootstrap.
public final class FamilyDateFormatter: DateFormatter {

    private static let spaceWithMillis: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSX"
        return f
    }()

    private static let spacePlain: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd HH:mm:ssX"
        return f
    }()

    private static let isoFallback: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        return f
    }()

    public override func date(from string: String) -> Date? {
        if let d = FamilyDateFormatter.spaceWithMillis.date(from: string) { return d }
        if let d = FamilyDateFormatter.spacePlain.date(from: string) { return d }
        return FamilyDateFormatter.isoFallback.date(from: string)
    }

    public override func string(from date: Date) -> String {
        FamilyDateFormatter.isoFallback.string(from: date)
    }
}
