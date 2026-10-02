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

    /// REQ-2026-012：T 分隔零分数位形态（tenant_applications 种子行实测
    /// `2026-01-15T08:00:00Z`）——isoFallback 的 .SSS 咬不住，慢路径又因
    /// 无分数可归一返回 nil。生成物 OpenISO8601DateFormatter 有 withoutSeconds
    /// 兜底，但本 formatter 整体替换了它，链内必须自带同款。
    private static let isoNoFraction: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return f
    }()

    public override func date(from string: String) -> Date? {
        if let d = FamilyDateFormatter.spaceWithMillis.date(from: string) { return d }
        if let d = FamilyDateFormatter.spacePlain.date(from: string) { return d }
        if let d = FamilyDateFormatter.isoFallback.date(from: string) { return d }
        if let d = FamilyDateFormatter.isoNoFraction.date(from: string) { return d }
        // Slow path (REQ-2026-009): fraction digit counts vary on the wire
        // (0/2/3/6 digits observed live). "SSS" is strict 3 digits, so pad or
        // truncate the fraction to exactly 3 and retry the matching format.
        // The fast chain above is untouched, so shipped surfaces keep their
        // behavior (REQ-008 risk row: zero change unless the whole chain failed).
        guard let normalized = FamilyDateFormatter.normalizedFraction(in: string) else {
            return nil
        }
        if normalized.contains(" ") {
            return FamilyDateFormatter.spaceWithMillis.date(from: normalized)
        }
        return FamilyDateFormatter.isoFallback.date(from: normalized)
    }

    /// Pad/truncate the first fractional-seconds group to exactly 3 digits.
    /// Returns nil when there is no fraction to fix (or it is already 3 digits).
    static func normalizedFraction(in string: String) -> String? {
        let ns = string as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = fractionPattern.firstMatch(in: string, options: [], range: range),
              match.range(at: 1).location != NSNotFound,
              let fracRange = Range(match.range(at: 1), in: string) else {
            return nil
        }
        let digits = String(string[fracRange])
        let fixed: String
        if digits.count >= 3 {
            fixed = String(digits.prefix(3))
        } else {
            fixed = digits + String(repeating: "0", count: 3 - digits.count)
        }
        guard fixed != digits else { return nil }
        return string.replacingCharacters(in: fracRange, with: fixed)
    }

    private static let fractionPattern = try! NSRegularExpression(
        pattern: "\\.([0-9]{1,9})(?=(?:Z|[+-][0-9]{2}:?[0-9]{2}?)?\\s*$)"
    )

    public override func string(from date: Date) -> String {
        FamilyDateFormatter.isoFallback.string(from: date)
    }
}
