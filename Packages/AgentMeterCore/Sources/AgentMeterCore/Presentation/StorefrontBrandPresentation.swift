#if os(iOS) || os(watchOS)
import Foundation
import StoreKit

public enum StorefrontBrandPresentation {
    public static let screenshotDataArgument = "--agentmeter-screenshot-data"
    public static let screenshotMainlandArgument = "--agentmeter-screenshot-mainland"

    public static func refreshCurrent() async -> BrandPresentationMode {
        if isScreenshotMainlandOverride {
            BrandPresentation.cache(.mainlandChina)
            return .mainlandChina
        }

        let mode = await BrandStorefrontResolver(provider: StoreKitCountryCodeProvider()).refresh()
        BrandPresentation.cache(mode)
        return mode
    }

    public static var updates: AsyncStream<BrandPresentationMode> {
        cacheUpdates(from: BrandStorefrontResolver(provider: StoreKitCountryCodeProvider()).updates)
    }

    public static func refresh(
        using provider: any BrandStorefrontCountryCodeProviding
    ) async -> BrandPresentationMode {
        let mode = await BrandStorefrontResolver(provider: provider).refresh()
        BrandPresentation.cache(mode)
        return mode
    }

    public static func updates(
        using provider: any BrandStorefrontCountryCodeProviding
    ) -> AsyncStream<BrandPresentationMode> {
        cacheUpdates(from: BrandStorefrontResolver(provider: provider).updates)
    }

    private static func cacheUpdates(
        from source: AsyncStream<BrandPresentationMode>
    ) -> AsyncStream<BrandPresentationMode> {
        AsyncStream { continuation in
            let task = Task {
                for await mode in source {
                    guard !Task.isCancelled else { break }
                    BrandPresentation.cache(mode)
                    continuation.yield(mode)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static var isScreenshotMainlandOverride: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(screenshotDataArgument)
            && arguments.contains(screenshotMainlandArgument)
    }
}

private struct StoreKitCountryCodeProvider: BrandStorefrontCountryCodeProviding {
    func currentCountryCode() async -> String? {
        await Storefront.current?.countryCode
    }

    var countryCodeUpdates: AsyncStream<String?> {
        AsyncStream { continuation in
            let task = Task {
                for await storefront in Storefront.updates {
                    guard !Task.isCancelled else { break }
                    continuation.yield(storefront.countryCode)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
