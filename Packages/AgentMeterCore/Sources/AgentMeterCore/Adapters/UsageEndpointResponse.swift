import Foundation

/// `GET /api/oauth/usage` 的原始响应 DTO。**字段以实测为准**,这是非官方端点,
/// 随时可能变;所有字段都是 optional,缺字段不应导致解析崩溃(CLAUDE.md 铁律 2)。
struct UsageEndpointResponse: Decodable {
    struct Window: Decodable {
        /// 已用 %,0–100。可能为 null。
        let utilization: Double?
        let resetsAt: Date?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }
}
