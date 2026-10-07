// Extracted from OpenMinis (GPL-3.0) — engine logic only, no UI.
// Part of Dudu native rewrite.
import Foundation

/// A normalized, user-facing description of a web navigation failure.
struct WebLoadError: Equatable {
    let title: String
    let message: String
    let systemImage: String
    /// The URL that failed, so a Retry can reload exactly it.
    let failedURL: URL?

    /// Build from a WebKit/Foundation navigation error. Returns nil for the
    /// benign "cancelled" cases (e.g. a load superseded by another, or a
    /// policy-cancelled non-http scheme handed off to the system) so the UI
    /// doesn't flash an error for a normal in-flight cancellation.
    init?(error: Error, failedURL: URL? = nil) {
        let ns = error as NSError

        // NSURLErrorCancelled (-999) and WKError frame-load-interrupted (102)
        // fire for superseded / policy-cancelled loads that are not real
        // failures — e.g. a non-http scheme handed off to the system, or a
        // load replaced by a newer one. Don't surface an error for those.
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return nil }
        if ns.domain == WKError.errorDomain, ns.code == 102 { return nil }

        // Prefer the URL WebKit reports in the error, then the caller's hint.
        let urlFromError = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        self.failedURL = urlFromError ?? failedURL

        // Map the most common URLError codes to Safari-style copy. Anything
        // else falls through to a generic message that still names the host.
        let host = self.failedURL?.host
        switch (ns.domain, ns.code) {
        case (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            title = AppLocalized("Cannot Open Page")
            message = host.map {
                AppLocalized("我的小家 can’t open the page because it can’t find the server “\($0)”.")
            } ?? AppLocalized("我的小家 can’t open the page because it can’t find the server.")
            systemImage = "wifi.exclamationmark"

        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost):
            title = AppLocalized("Cannot Open Page")
            message = AppLocalized("我的小家 can’t open the page because it can’t connect to the server.")
            systemImage = "wifi.exclamationmark"

        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
             (NSURLErrorDomain, NSURLErrorNetworkConnectionLost),
             (NSURLErrorDomain, NSURLErrorInternationalRoamingOff),
             (NSURLErrorDomain, NSURLErrorDataNotAllowed):
            title = AppLocalized("You Are Not Connected to the Internet")
            message = AppLocalized("The page couldn’t load because you’re not connected to the internet.")
            systemImage = "wifi.slash"

        case (NSURLErrorDomain, NSURLErrorTimedOut):
            title = AppLocalized("The Connection Timed Out")
            message = host.map {
                AppLocalized("The server “\($0)” took too long to respond.")
            } ?? AppLocalized("The server took too long to respond.")
            systemImage = "clock.badge.exclamationmark"

        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid),
             (NSURLErrorDomain, NSURLErrorClientCertificateRejected),
             (NSURLErrorDomain, NSURLErrorClientCertificateRequired):
            title = AppLocalized("This Connection Is Not Private")
            message = host.map {
                AppLocalized("我的小家 can’t verify the identity of the server “\($0)”.")
            } ?? AppLocalized("我的小家 can’t verify the identity of the server.")
            systemImage = "lock.slash"

        case (NSURLErrorDomain, NSURLErrorUnsupportedURL),
             (NSURLErrorDomain, NSURLErrorBadURL):
            title = AppLocalized("Cannot Open Page")
            message = AppLocalized("The address isn’t valid.")
            systemImage = "exclamationmark.triangle"

        default:
            title = AppLocalized("Cannot Open Page")
            message = host.map {
                AppLocalized("A problem occurred loading “\($0)”.")
            } ?? AppLocalized("A problem occurred while loading this page.")
            systemImage = "exclamationmark.triangle"
        }
    }
}

/// Centered Safari-style error card shown over a blank WKWebView, with Retry.

