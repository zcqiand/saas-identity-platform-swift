import Foundation
import SaasSharedGenerated

/// 生成 client（SaasSharedGenerated）的唯一配置入口（lab swift 同款）。
/// 登录 UI 落地前，baseURL 由 SessionStore 显式配置（ADR-0019），禁 env 默认值兜底。
public enum APIClient {

    /// URL 校验/归一（trim、scheme+host 必备、尾斜杠剥离）。
    /// bootstrap 与 SessionStore.saveConfig 共用；生成层按 basePath + path 拼
    /// URLString，尾斜杠不归一会打歪（双斜杠）。
    public static func normalizeBaseURL(_ raw: String) throws -> String {
        let trimmedBase = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else { throw APIConfigError.missingBaseURL }
        guard let url = URL(string: trimmedBase), url.scheme != nil, url.host != nil else {
            throw APIConfigError.invalidBaseURL(raw)
        }
        var normalized = url.absoluteString
        if normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }

    /// 校验并注入 baseURL + Bearer 会话。任何缺失/非法立即 throw，不兜底。
    public static func bootstrap(baseURL: String, token: String) throws {
        let normalized = try normalizeBaseURL(baseURL)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { throw APIConfigError.missingToken }

        OpenAPIClientAPI.basePath = normalized
        OpenAPIClientAPI.customHeaders["Authorization"] = "Bearer \(trimmedToken)"

        // REQ-2026-008: install the family date formatter through the
        // generated public hook (wire shapes documented in
        // FamilyDateFormatter.swift; idempotent, request bodies stay ISO).
        CodableHelper.dateFormatter = FamilyDateFormatter()
    }
}

public enum APIConfigError: Error, Equatable {
    case missingBaseURL
    case missingToken
    case invalidBaseURL(String)
}
