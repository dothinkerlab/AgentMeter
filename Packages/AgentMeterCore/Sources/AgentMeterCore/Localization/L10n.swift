import Foundation

public enum L10n {
    public static func string(_ key: String) -> String {
        BrandPresentation.text(NSLocalizedString(key, comment: ""))
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        BrandPresentation.text(
            String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: arguments)
        )
    }

    public static func plural(_ key: String, _ count: Int) -> String {
        BrandPresentation.text(
            String.localizedStringWithFormat(NSLocalizedString(key, comment: ""), count)
        )
    }
}

public enum QuotaWindowLabelStyle {
    case full
    case short
    case compactAbbrev
}

public enum QuotaWindowLabel {
    public static func string(for kind: WindowKind, style: QuotaWindowLabelStyle) -> String {
        switch style {
        case .full:
            return full(kind)
        case .short:
            return short(kind)
        case .compactAbbrev:
            return compactAbbrev(kind)
        }
    }

    private static func full(_ kind: WindowKind) -> String {
        switch kind {
        case .fiveHour: return L10n.string("5 小时窗口")
        case .sevenDay: return L10n.string("每周窗口")
        case .sevenDayOpus: return L10n.string("每周 (Opus)")
        case .sevenDaySonnet: return L10n.string("每周 (Sonnet)")
        case .monthly: return L10n.string("每月窗口")
        case .daily: return L10n.string("每日窗口")
        case .weekly: return L10n.string("每周窗口")
        case .premiumInteractions: return L10n.string("高级请求")
        case .chat: return L10n.string("聊天")
        case .editPredictions: return L10n.string("编辑预测")
        case .messages: return L10n.string("消息")
        case .flowActions: return L10n.string("Flow 操作")
        case .geminiPro: return L10n.string("Pro 每日")
        case .geminiFlash: return L10n.string("Flash 每日")
        case .geminiFlashLite: return L10n.string("Flash Lite 每日")
        case .geminiFiveHour: return L10n.string("5 小时窗口")
        case .geminiWeekly: return L10n.string("每周窗口")
        case .claudeGPTFiveHour: return L10n.string("Claude/GPT 5 小时")
        case .claudeGPTWeekly: return L10n.string("Claude/GPT 每周")
        case .antigravityGemini: return L10n.string("Gemini 模型")
        case .antigravityClaudeGPT: return L10n.string("Claude / GPT")
        }
    }

    private static func short(_ kind: WindowKind) -> String {
        switch kind {
        case .fiveHour: return L10n.string("5 小时")
        case .sevenDay: return L10n.string("每周")
        case .sevenDayOpus: return L10n.string("周 Opus")
        case .sevenDaySonnet: return L10n.string("周 Sonnet")
        case .monthly: return L10n.string("每月")
        case .daily: return L10n.string("每日")
        case .weekly: return L10n.string("每周")
        case .premiumInteractions: return L10n.string("高级请求")
        case .chat: return L10n.string("聊天")
        case .editPredictions: return L10n.string("编辑预测")
        case .messages: return L10n.string("消息")
        case .flowActions: return L10n.string("Flow 操作")
        case .geminiPro: return "Pro"
        case .geminiFlash: return "Flash"
        case .geminiFlashLite: return "Flash Lite"
        case .geminiFiveHour: return L10n.string("5 小时")
        case .geminiWeekly: return L10n.string("每周")
        case .claudeGPTFiveHour: return "C/G 5h"
        case .claudeGPTWeekly: return L10n.string("C/G 每周")
        case .antigravityGemini: return "Gemini"
        case .antigravityClaudeGPT: return "Claude/GPT"
        }
    }

    private static func compactAbbrev(_ kind: WindowKind) -> String {
        switch kind {
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        case .sevenDayOpus: return "7d-O"
        case .sevenDaySonnet: return "7d-S"
        case .monthly: return "mo"
        case .daily: return "1d"
        case .weekly: return "1w"
        case .premiumInteractions: return "Pro"
        case .chat: return "Chat"
        case .editPredictions: return "Edit"
        case .messages: return "Msg"
        case .flowActions: return "Flow"
        case .geminiPro: return "Pro"
        case .geminiFlash: return "Flash"
        case .geminiFlashLite: return "Lite"
        case .geminiFiveHour: return "5h"
        case .geminiWeekly: return "7d"
        case .claudeGPTFiveHour: return "C/G 5h"
        case .claudeGPTWeekly: return "C/G 7d"
        case .antigravityGemini: return "Gem"
        case .antigravityClaudeGPT: return "C/G"
        }
    }
}
