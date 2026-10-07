import Foundation

enum LLMError: LocalizedError {
    case invalidAPIKey(detail: String = "")
    case networkError(underlying: Error)
    case providerError(message: String)
    /// Transient server-side errors (HTTP 500/502/503/504/529) that should be
    /// retried on the same model rather than triggering a group fallback.
    case transientError(message: String)
    case decodingError(underlying: Error)
    /// 429 / transient throttling. [T-kelivo-retry 09-10] Carries the server's
    /// Retry-After hint when present so the retry loop waits what the provider
    /// asked for instead of a fixed guess.
    case rateLimited(retryAfterSeconds: Double? = nil)
    case cancelled
    case unknown(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey(let detail):
            return detail.isEmpty ? "Invalid API key" : "Invalid API key: \(detail)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .providerError(let message):
            return "Provider error: \(message)"
        case .transientError(let message):
            return "Service temporarily unavailable: \(message)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        case .rateLimited:
            return "Rate limited — please try again later"
        case .cancelled:
            return "Request was cancelled"
        case .unknown(let error):
            return "Unknown error: \(error?.localizedDescription ?? "no details")"
        }
    }

    var isNetworkError: Bool {
        if case .networkError = self { return true }
        return false
    }

    /// Errors that should be retried with countdown on the same provider.
    /// Includes both network errors and transient server-side errors (5xx).
    /// [T-kelivo-retry 09-10] 429 rate limits are now RETRYABLE too — kelivo
    /// treats throttling as transient (wait and retry the same model) and that
    /// is what users expect: switching models on a 429 throws away the
    /// conversation's model affinity for what is usually a seconds-long
    /// throttle. Group fallback still kicks in once retries are exhausted.
    var isRetryable: Bool {
        switch self {
        case .networkError, .transientError, .rateLimited:
            return true
        case .invalidAPIKey, .providerError, .decodingError, .cancelled, .unknown:
            return false
        }
    }

    /// Server's Retry-After hint for rate limits (seconds), when the provider
    /// sent one. The retry loop uses this as the FIRST delay instead of the
    /// exponential guess.
    var retryAfterHint: Double? {
        if case .rateLimited(let seconds) = self { return seconds }
        return nil
    }

    /// Errors that indicate the provider itself cannot serve this request
    /// (rate limit, invalid key, permanent provider-side rejection). These trigger
    /// an immediate fallback to the next model in a group, without retry countdown.
    ///
    /// Note: transientError and networkError are also fallbackable — after
    /// auto-retry is exhausted on the current model, group fallback kicks in.
    var fallbackReason: String {
        switch self {
        case .rateLimited: return "Rate limited"
        case .invalidAPIKey: return "Invalid API key"
        case .providerError(let msg): return "Provider error: \(String(msg.prefix(60)))"
        default: return "Error"
        }
    }

    var isFallbackable: Bool {
        switch self {
        case .rateLimited, .invalidAPIKey, .providerError:
            return true
        case .transientError, .networkError, .decodingError, .cancelled, .unknown:
            return false
        }
    }
}
