// User-facing preferences, persisted to UserDefaults.
//
// One @Observable singleton; SwiftUI views auto-rerender on mutation, and
// every setter writes through to UserDefaults so values survive relaunch.
//
// Why a separate file and not just scattered `@AppStorage` in views:
//   - The engine needs to read these (plan-tier limits, brake threshold) and
//     it doesn't live in a View
//   - One place to evolve the schema; default values are colocated with the
//     keys; migrations (when they happen) go here too
//
// Implementation note: properties are stored (not computed) so the
// `@Observable` macro instruments them — SwiftUI re-renders when the slider
// or picker mutates them. A `didSet` mirrors the value to UserDefaults so
// values still survive relaunch.

import Foundation
import Observation

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - Plan tier

    enum PlanTier: String, CaseIterable, Identifiable {
        case free
        case pro
        case max5
        case max20
        case api

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .free:  return "Free"
            case .pro:   return "Pro"
            case .max5:  return "Max (5×)"
            case .max20: return "Max (20×)"
            case .api:   return "API key (pay-per-token)"
            }
        }

        /// Approximate per-5-hour session-block token allowances. These count
        /// input + output + cache-creation only (NOT cache reads, which are
        /// near-free re-served bytes). Numbers are calibrated against
        /// observed usage — Anthropic does not publish official limits, so
        /// every percentage we render off these is a rough gauge, not gospel.
        var sessionTokenLimit: Int {
            switch self {
            case .free:  return    200_000
            case .pro:   return  1_000_000
            case .max5:  return  5_000_000
            case .max20: return 20_000_000
            case .api:   return Int.max     // no token-side cap; use dollar cap
            }
        }

        /// API users get the dollar-budget brake instead.
        var usesDollarBudget: Bool { self == .api }
    }

    var planTier: PlanTier {
        didSet { defaults.set(planTier.rawValue, forKey: Self.kPlanTier) }
    }

    /// When false: no cost/token UI surfaces at all. Recording still happens
    /// internally (cheap, useful if user re-enables) but the badge, brake
    /// banner, and per-session cost are all hidden.
    var usageTrackingEnabled: Bool {
        didSet { defaults.set(usageTrackingEnabled, forKey: Self.kUsageTracking) }
    }

    /// Fraction of the session token limit at which the brake fires.
    /// 0.85 = pulse orange when 85% of the way through your 5-hour window.
    var brakeThresholdPercent: Double {
        didSet { defaults.set(brakeThresholdPercent, forKey: Self.kBrakeThreshold) }
    }

    /// API-tier daily dollar cap. Only consulted when `planTier == .api`.
    var dailyCapUSD: Double {
        didSet { defaults.set(dailyCapUSD, forKey: Self.kDailyCap) }
    }

    // MARK: - Working animation

    /// The motion the notch shows while Claude is actively working. Both
    /// styles render in Claude's brand orange — only the motion differs.
    enum WorkingAnimation: String, CaseIterable, Identifiable {
        /// The Claude Code CLI's cycling dingbat "flower" — six frames of
        /// asterisks/florettes rotating at ~80ms. Reads as progress.
        case spinner
        /// A single 8-point star scaling 0.7↔1.0 with fading opacity — the
        /// claude.ai chat logo's pulse, transposed.
        case pulse
        /// The chunky orange pixel-art figure from the CLI's terminal banner,
        /// scuttling — pairs of legs alternate stepping while the eyes stay
        /// dead-still. Reads as a tiny mascot walking in place.
        case mascot

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .spinner: return "Spinner (CLI flower)"
            case .pulse:   return "Pulse (logo breathing)"
            case .mascot:  return "Mascot (walking)"
            }
        }
    }

    var workingAnimation: WorkingAnimation {
        didSet { defaults.set(workingAnimation.rawValue, forKey: Self.kWorkingAnimation) }
    }

    // MARK: - Keys

    private static let kPlanTier         = "notchcode.planTier"
    private static let kUsageTracking    = "notchcode.usageTrackingEnabled"
    private static let kBrakeThreshold   = "notchcode.brakeThresholdPercent"
    private static let kDailyCap         = "notchcode.dailyCapUSD"
    private static let kWorkingAnimation = "notchcode.workingAnimation"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let rawTier = defaults.string(forKey: Self.kPlanTier) ?? PlanTier.max5.rawValue
        self.planTier = PlanTier(rawValue: rawTier) ?? .max5
        self.usageTrackingEnabled = (defaults.object(forKey: Self.kUsageTracking) as? Bool) ?? true
        self.brakeThresholdPercent = (defaults.object(forKey: Self.kBrakeThreshold) as? Double) ?? 0.85
        self.dailyCapUSD = (defaults.object(forKey: Self.kDailyCap) as? Double) ?? 25
        let rawAnim = defaults.string(forKey: Self.kWorkingAnimation) ?? WorkingAnimation.spinner.rawValue
        self.workingAnimation = WorkingAnimation(rawValue: rawAnim) ?? .spinner
    }
}
