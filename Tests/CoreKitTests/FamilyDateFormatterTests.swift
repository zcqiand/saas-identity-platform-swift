import XCTest
import SaasSharedGenerated
@testable import CoreKit

/// REQ-2026-008: family wire date shapes vs the generated formatter (AC-5).
/// Live probe 2026-10-01 @5101: /me is RFC3339 (generated parser OK), but
/// admin/tenants, admin/clients and menus emit space-separated + bare-offset
/// strings ("2026-03-10 18:00:00+08", "2026-08-30 00:07:19.257+08") that the
/// generated OpenISO8601DateFormatter cannot parse -> any [SysMenu]/[Tenant]/
/// [OAuthClient] decode would throw. FamilyDateFormatter (installed via the
/// generated public hook CodableHelper.dateFormatter at bootstrap) parses all
/// three shapes and keeps encoding ISO.
final class FamilyDateFormatterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Install through the generated hook exactly like APIClient.bootstrap.
        CodableHelper.dateFormatter = FamilyDateFormatter()
    }

    private func utcComponents(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    func testParsesSpaceSeparatedMillisWithBareOffset() {
    // fn: M04.F04
        let formatter = FamilyDateFormatter()
        let parsed = formatter.date(from: "2026-08-30 00:07:19.257+08")
        XCTAssertNotNil(parsed, "menus wire shape must parse (AC-5)")
        let c = utcComponents(parsed!)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 8)
        XCTAssertEqual(c.day, 29, "+08 offset means 2026-08-29T16:07:19Z in UTC")
        XCTAssertEqual(c.hour, 16)
        XCTAssertEqual(c.minute, 7)
        XCTAssertEqual(c.second, 19)
    }

    func testParsesSpaceSeparatedPlainWithBareOffset() {
    // fn: M04.F04
        let formatter = FamilyDateFormatter()
        let parsed = formatter.date(from: "2026-03-10 18:00:00+08")
        XCTAssertNotNil(parsed, "admin/tenants + admin/clients wire shape must parse (AC-5)")
        let c = utcComponents(parsed!)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 3)
        XCTAssertEqual(c.day, 10)
        XCTAssertEqual(c.hour, 10, "18:00+08 == 10:00Z")
    }

    func testParsesGeneratedISOFallback() {
    // fn: M04.F04
        let formatter = FamilyDateFormatter()
        let parsed = formatter.date(from: "2026-01-20T08:00:00.000Z")
        XCTAssertNotNil(parsed, "/me wire shape keeps working through the ISO fallback")
        let c = utcComponents(parsed!)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 1)
        XCTAssertEqual(c.day, 20)
        XCTAssertEqual(c.hour, 8)
    }

    func testEncodeStaysISO() {
    // fn: M04.F04
        let formatter = FamilyDateFormatter()
        let parsed = formatter.date(from: "2026-01-20T08:00:00.000Z")!
        XCTAssertEqual(
            formatter.string(from: parsed),
            "2026-01-20T08:00:00.000Z",
            "encoding (request bodies) stays ISO, unchanged from generated behavior"
        )
    }

    func testSysMenuDecodeWithSpaceDateSucceeds() {
    // fn: M04.F04
        // The real integration point: the generated decoder (CodableHelper.jsonDecoder
        // with dateDecodingStrategy .formatted(CodableHelper.dateFormatter)) must
        // decode a SysMenu whose createdAt uses the menus wire shape.
        let json = """
        {
          "id": "00000000-0000-0000-0000-910000000001",
          "clientId": "lab-management",
          "parentId": "00000000-0000-0000-0000-000000000000",
          "title": "Dashboard",
          "type": "menu",
          "path": "dashboard",
          "sortOrder": 1,
          "status": 1,
          "createdAt": "2026-08-30 00:07:19.257+08"
        }
        """
        let result = CodableHelper.decode(SysMenu.self, from: Data(json.utf8))
        switch result {
        case .success(let menu):
            XCTAssertEqual(menu.title, "Dashboard")
            XCTAssertEqual(menu.parentId, UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        case .failure(let error):
            XCTFail("SysMenu decode with space+08 createdAt must succeed (AC-5), threw: \(error)")
        }
    }

    func testTenantDecodeWithSpaceDateSucceeds() {
    // fn: M04.F04
        // Same shim retroactively covers the admin/tenants + admin/clients surfaces.
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "tenantKey": "acme",
          "name": "ACME Corp",
          "status": "active",
          "createdAt": "2026-03-10 18:00:00+08",
          "updatedAt": "2026-08-01 20:00:00+08"
        }
        """
        let result = CodableHelper.decode(Tenant.self, from: Data(json.utf8))
        switch result {
        case .success(let tenant):
            XCTAssertEqual(tenant.name, "ACME Corp")
        case .failure(let error):
            XCTFail("Tenant decode with space+08 createdAt must succeed (AC-5), threw: \(error)")
        }
    }
}
