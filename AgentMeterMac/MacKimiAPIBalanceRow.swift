import SwiftUI
import AgentMeterCore

struct MacKimiAPIBalanceRow: View {
    let balance: KimiAPIBalance
    private func amount(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = balance.region == .china ? "CNY" : "USD"
        formatter.maximumFractionDigits = 5
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Kimi API").font(.system(size: 13, weight: .bold))
                Text(balance.region == .china ? "CN · Mac" : "Global · Mac").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if balance.confidence != .fresh { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            if balance.hasKnownValue {
                Text(amount(balance.availableBalance)).font(.system(size: 22, weight: .bold, design: .rounded))
                Text("\(L10n.string("代金券")) \(amount(balance.voucherBalance)) · \(L10n.string("现金")) \(amount(balance.cashBalance))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("—").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
}
