import Foundation

/// Codex plan usage 的原始响应 DTO。
///
/// Codex 没有稳定公开额度 API,字段必须以录制 fixture 为准。这里只表达 AgentMeter
/// 真正需要的最小字段:plan、remaining percent、reset time。窗口字段保持 optional,
/// 缺失或 null 时跳过,不让解析崩溃。
struct CodexPlanUsageResponse: Decodable {
    struct Window: Decodable {
        /// 已用 %,0-100。Codex `/wham/usage` 当前返回该字段。
        let usedPercent: Double?
        /// 剩余 %,0-100。Codex 口径与 Claude 相反,adapter 会转成 usedPercent。
        let remainingPercent: Double?
        let resetsAt: Date?
        let limitWindowSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent
            case usedPercentSnake = "used_percent"
            case remaining
            case remainingPercent
            case remainingPercentSnake = "remaining_percent"
            case remainingPct
            case remainingPctSnake = "remaining_pct"
            case percentRemaining
            case percentRemainingSnake = "percent_remaining"
            case resetsAt
            case resetsAtSnake = "resets_at"
            case resetAt
            case resetAtSnake = "reset_at"
            case limitWindowSeconds
            case limitWindowSecondsSnake = "limit_window_seconds"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = try c.decodeFirstDouble(forKeys: [.usedPercent, .usedPercentSnake])
            remainingPercent = try c.decodeFirstDouble(
                forKeys: [
                    .remainingPercent,
                    .remainingPercentSnake,
                    .remainingPct,
                    .remainingPctSnake,
                    .percentRemaining,
                    .percentRemainingSnake,
                    .remaining,
                ]
            )
            resetsAt = try c.decodeFirstDateOrEpoch(
                forKeys: [.resetsAt, .resetsAtSnake, .resetAt, .resetAtSnake]
            )
            limitWindowSeconds = try c.decodeFirstInt(forKeys: [.limitWindowSeconds, .limitWindowSecondsSnake])
        }
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow
            case primaryWindowSnake = "primary_window"
            case secondaryWindow
            case secondaryWindowSnake = "secondary_window"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            primaryWindow = try c.decodeFirstWindow(forKeys: [.primaryWindow, .primaryWindowSnake])
            secondaryWindow = try c.decodeFirstWindow(forKeys: [.secondaryWindow, .secondaryWindowSnake])
        }
    }

    let plan: String?
    let fiveHour: Window?
    let sevenDay: Window?
    let monthly: Window?
    let rateLimit: RateLimit?

    enum CodingKeys: String, CodingKey {
        case plan
        case planType
        case planTypeSnake = "plan_type"
        case planName
        case planNameSnake = "plan_name"
        case subscriptionPlan
        case subscriptionPlanSnake = "subscription_plan"
        case fiveHour
        case fiveHourSnake = "five_hour"
        case sevenDay
        case sevenDaySnake = "seven_day"
        case weekly
        case monthly
        case usage
        case limits
        case quota
        case rateLimit
        case rateLimitSnake = "rate_limit"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decodeFirstString(
            forKeys: [
                .plan,
                .planType,
                .planTypeSnake,
                .planName,
                .planNameSnake,
                .subscriptionPlan,
                .subscriptionPlanSnake,
            ]
        )
        rateLimit = try c.decodeFirstRateLimit(forKeys: [.rateLimit, .rateLimitSnake])

        let nested = try [
            c.decodeIfPresent(Nested.self, forKey: .usage),
            c.decodeIfPresent(Nested.self, forKey: .limits),
            c.decodeIfPresent(Nested.self, forKey: .quota),
        ].compactMap { $0 }

        fiveHour = try c.decodeFirstWindow(forKeys: [.fiveHour, .fiveHourSnake])
            ?? nested.lazy.compactMap(\.fiveHour).first
        sevenDay = try c.decodeFirstWindow(forKeys: [.sevenDay, .sevenDaySnake, .weekly])
            ?? nested.lazy.compactMap(\.sevenDay).first
        monthly = try c.decodeFirstWindow(forKeys: [.monthly])
            ?? nested.lazy.compactMap(\.monthly).first
    }

    fileprivate struct Nested: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let monthly: Window?

        fileprivate enum CodingKeys: String, CodingKey {
            case fiveHour
            case fiveHourSnake = "five_hour"
            case sevenDay
            case sevenDaySnake = "seven_day"
            case weekly
            case monthly
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try c.decodeFirstWindow(forKeys: [.fiveHour, .fiveHourSnake])
            sevenDay = try c.decodeFirstWindow(forKeys: [.sevenDay, .sevenDaySnake, .weekly])
            monthly = try c.decodeFirstWindow(forKeys: [.monthly])
        }
    }
}

private extension KeyedDecodingContainer where Key == CodexPlanUsageResponse.CodingKeys {
    func decodeFirstString(forKeys keys: [Key]) throws -> String? {
        for key in keys {
            if let value = try decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    func decodeFirstWindow(forKeys keys: [Key]) throws -> CodexPlanUsageResponse.Window? {
        for key in keys {
            if let value = try decodeIfPresent(CodexPlanUsageResponse.Window.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    func decodeFirstRateLimit(forKeys keys: [Key]) throws -> CodexPlanUsageResponse.RateLimit? {
        for key in keys {
            if let value = try decodeIfPresent(CodexPlanUsageResponse.RateLimit.self, forKey: key) {
                return value
            }
        }
        return nil
    }
}

private extension KeyedDecodingContainer where Key == CodexPlanUsageResponse.RateLimit.CodingKeys {
    func decodeFirstWindow(forKeys keys: [Key]) throws -> CodexPlanUsageResponse.Window? {
        for key in keys {
            if let value = try decodeIfPresent(CodexPlanUsageResponse.Window.self, forKey: key) {
                return value
            }
        }
        return nil
    }
}

private extension KeyedDecodingContainer where Key == CodexPlanUsageResponse.Nested.CodingKeys {
    func decodeFirstWindow(forKeys keys: [Key]) throws -> CodexPlanUsageResponse.Window? {
        for key in keys {
            if let value = try decodeIfPresent(CodexPlanUsageResponse.Window.self, forKey: key) {
                return value
            }
        }
        return nil
    }
}

private extension KeyedDecodingContainer where Key == CodexPlanUsageResponse.Window.CodingKeys {
    func decodeFirstDouble(forKeys keys: [Key]) throws -> Double? {
        for key in keys {
            if let value = try decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let intValue = try decodeIfPresent(Int.self, forKey: key) {
                return Double(intValue)
            }
        }
        return nil
    }

    func decodeFirstInt(forKeys keys: [Key]) throws -> Int? {
        for key in keys {
            if let value = try decodeIfPresent(Int.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    func decodeFirstDateOrEpoch(forKeys keys: [Key]) throws -> Date? {
        for key in keys {
            if let value = try? decodeIfPresent(Date.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
            }
            // 用 Int64:watchOS 真机是 arm64_32,Int 仅 32 位,装不下毫秒级 epoch(13 位)。
            if let value = try? decodeIfPresent(Int64.self, forKey: key) {
                let seconds = value > 10_000_000_000 ? Double(value) / 1000 : Double(value)
                return Date(timeIntervalSince1970: seconds)
            }
        }
        return nil
    }
}
