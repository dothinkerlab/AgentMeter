import Foundation

public extension ProcessInfo {
    func agentMeterArgument(after flag: String) -> String? {
        let args = arguments
        guard let index = args.firstIndex(of: flag) else { return nil }
        let valueIndex = args.index(after: index)
        guard valueIndex < args.endIndex else { return nil }
        return args[valueIndex]
    }
}
