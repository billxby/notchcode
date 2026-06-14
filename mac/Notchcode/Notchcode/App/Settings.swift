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

    /// A plan tier for one of the agents. Claude and Codex draw from disjoint
    /// subsets of these cases (see `tiers(for:)`); `api` is shared by both —
    /// it means pay-per-token, so the brake meters dollars-vs-daily-cap instead
    /// of tokens-vs-weekly-budget.
    enum PlanTier: String, CaseIterable, Identifiable {
        // Claude (Anthropic) subscription tiers.
        case free
        case pro
        case max5
        case max20
        // Codex (OpenAI / ChatGPT) subscription tiers. `codexPro` is distinct
        // from Claude's `pro` (different default budget) but displays as "Pro".
        case plus
        case codexPro
        case business
        case enterprise
        // Shared pay-per-token tier.
        case api

        var id: String { rawValue }

        /// The tiers offered for a given agent's "Your plan" picker.
        static func tiers(for agent: Agent) -> [PlanTier] {
            switch agent {
            case .claude: return [.free, .pro, .max5, .max20, .api]
            case .codex:  return [.plus, .codexPro, .business, .enterprise, .api]
            }
        }

        /// The default tier when a user hasn't picked one yet, per agent.
        static func `default`(for agent: Agent) -> PlanTier {
            switch agent {
            case .claude: return .max5
            case .codex:  return .plus
            }
        }

        var displayName: String {
            switch self {
            case .free:       return "Free"
            case .pro:        return "Pro"
            case .max5:       return "Max (5×)"
            case .max20:      return "Max (20×)"
            case .plus:       return "Plus"
            case .codexPro:   return "Pro"
            case .business:   return "Business"
            case .enterprise: return "Enterprise"
            case .api:        return "API key (pay-per-token)"
            }
        }

        /// Suggested weekly token budget per tier — the DEFAULT for the
        /// user-editable `weeklyTokenBudget`, not a hard limit. These count
        /// input + output + cache-creation only (NOT cache reads, which are
        /// near-free re-served bytes). Rough presets: neither Anthropic nor
        /// OpenAI publish per-plan token numbers, so the user is expected to
        /// tune their own budget after watching a week of real usage.
        var defaultWeeklyTokenBudget: Int {
            switch self {
            case .free:       return   1_000_000
            case .pro:        return  10_000_000
            case .max5:       return  50_000_000
            case .max20:      return 200_000_000
            case .plus:       return  10_000_000
            case .codexPro:   return  50_000_000
            case .business:   return 100_000_000
            case .enterprise: return 300_000_000
            case .api:        return 0          // unused — dollar cap instead
            }
        }

        /// API users get the dollar-budget brake instead.
        var usesDollarBudget: Bool { self == .api }
    }

    // MARK: - Per-agent plan/budget
    //
    // Each agent (Claude, Codex) carries its OWN plan tier, weekly token
    // budget, and daily $ cap so the usage badge and brake meter each agent
    // against the right limits — they're billed by separate providers on
    // separate plans. The brake threshold % and the master usage toggle stay
    // global (one knob applies to both).
    //
    // Storage note: the Claude trio keeps the original (un-prefixed) keys so
    // pre-per-agent installs migrate transparently — an old `weeklyTokenBudget`
    // is exactly the Claude budget now. Codex uses new prefixed keys, seeded
    // from its tier preset on first read.

    var planTier: PlanTier {
        didSet {
            defaults.set(planTier.rawValue, forKey: Self.kPlanTier)
            // Switching tiers re-seeds the weekly budget with the new tier's
            // preset — the old number was calibrated to the old plan.
            if !planTier.usesDollarBudget {
                weeklyTokenBudget = planTier.defaultWeeklyTokenBudget
            }
        }
    }

    /// User-editable weekly token budget the brake measures against. Seeded
    /// from the plan tier's preset; this is the user's own gauge — providers
    /// don't publish per-plan token limits, and we deliberately stopped
    /// pretending to know them (see SessionStateEngine's usage redesign).
    var weeklyTokenBudget: Int {
        didSet { defaults.set(weeklyTokenBudget, forKey: Self.kWeeklyBudget) }
    }

    /// API-tier daily dollar cap. Only consulted when `planTier == .api`.
    var dailyCapUSD: Double {
        didSet { defaults.set(dailyCapUSD, forKey: Self.kDailyCap) }
    }

    /// Codex equivalents of the three above.
    var codexPlanTier: PlanTier {
        didSet {
            defaults.set(codexPlanTier.rawValue, forKey: Self.kCodexPlanTier)
            if !codexPlanTier.usesDollarBudget {
                codexWeeklyTokenBudget = codexPlanTier.defaultWeeklyTokenBudget
            }
        }
    }

    var codexWeeklyTokenBudget: Int {
        didSet { defaults.set(codexWeeklyTokenBudget, forKey: Self.kCodexWeeklyBudget) }
    }

    var codexDailyCapUSD: Double {
        didSet { defaults.set(codexDailyCapUSD, forKey: Self.kCodexDailyCap) }
    }

    // MARK: - Per-agent accessors
    //
    // Views and the engine address budget settings by `Agent`; these dispatch
    // to the right stored property so callers never branch on the agent
    // themselves. Stored (not computed) properties back them so @Observable
    // still re-renders on mutation.

    func planTier(for agent: Agent) -> PlanTier {
        agent == .claude ? planTier : codexPlanTier
    }

    func setPlanTier(_ tier: PlanTier, for agent: Agent) {
        if agent == .claude { planTier = tier } else { codexPlanTier = tier }
    }

    func weeklyTokenBudget(for agent: Agent) -> Int {
        agent == .claude ? weeklyTokenBudget : codexWeeklyTokenBudget
    }

    func setWeeklyTokenBudget(_ value: Int, for agent: Agent) {
        if agent == .claude { weeklyTokenBudget = value } else { codexWeeklyTokenBudget = value }
    }

    func dailyCapUSD(for agent: Agent) -> Double {
        agent == .claude ? dailyCapUSD : codexDailyCapUSD
    }

    func setDailyCapUSD(_ value: Double, for agent: Agent) {
        if agent == .claude { dailyCapUSD = value } else { codexDailyCapUSD = value }
    }

    /// When false: no cost/token UI surfaces at all. Recording still happens
    /// internally (cheap, useful if user re-enables) but the badge, brake
    /// banner, and per-session cost are all hidden.
    var usageTrackingEnabled: Bool {
        didSet { defaults.set(usageTrackingEnabled, forKey: Self.kUsageTracking) }
    }

    /// Per-agent visibility of the usage chip + brake. The combined notch chip
    /// shows a segment (and brakes) only for agents whose toggle is on — so a
    /// user can watch both, either alone, or neither. Gated under the master
    /// `usageTrackingEnabled` switch above; both default on.
    var showUsageClaude: Bool {
        didSet { defaults.set(showUsageClaude, forKey: Self.kShowUsageClaude) }
    }

    var showUsageCodex: Bool {
        didSet { defaults.set(showUsageCodex, forKey: Self.kShowUsageCodex) }
    }

    func showUsage(for agent: Agent) -> Bool {
        agent == .claude ? showUsageClaude : showUsageCodex
    }

    func setShowUsage(_ value: Bool, for agent: Agent) {
        if agent == .claude { showUsageClaude = value } else { showUsageCodex = value }
    }

    /// Fraction of the weekly token budget (or daily $ cap for API tier) at
    /// which the brake fires. 0.85 = warn at 85% of your budget. Shared by
    /// both agents.
    var brakeThresholdPercent: Double {
        didSet { defaults.set(brakeThresholdPercent, forKey: Self.kBrakeThreshold) }
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

    // MARK: - Notifications

    /// Post a macOS notification banner when a session blocks on the user
    /// (a permission/approval request). The notch already turns yellow, but a
    /// banner reaches you when you've switched to another app — the whole
    /// point, since the agent is stalled until you answer. Codex in particular
    /// asks for approval often, so this defaults on.
    var notifyOnWaiting: Bool {
        didSet { defaults.set(notifyOnWaiting, forKey: Self.kNotifyOnWaiting) }
    }

    /// Also bring the agent's terminal window to the front the moment it starts
    /// waiting, without you having to click the banner or the notch. Defaults
    /// on; turn off if you'd rather not have focus pulled mid-task.
    var focusTerminalOnWaiting: Bool {
        didSet { defaults.set(focusTerminalOnWaiting, forKey: Self.kFocusOnWaiting) }
    }

    // MARK: - Keys

    private static let kPlanTier         = "notchcode.planTier"
    private static let kUsageTracking    = "notchcode.usageTrackingEnabled"
    private static let kShowUsageClaude  = "notchcode.showUsageClaude"
    private static let kShowUsageCodex   = "notchcode.showUsageCodex"
    private static let kBrakeThreshold   = "notchcode.brakeThresholdPercent"
    private static let kDailyCap         = "notchcode.dailyCapUSD"
    private static let kWeeklyBudget     = "notchcode.weeklyTokenBudget"
    private static let kCodexPlanTier    = "notchcode.codex.planTier"
    private static let kCodexDailyCap    = "notchcode.codex.dailyCapUSD"
    private static let kCodexWeeklyBudget = "notchcode.codex.weeklyTokenBudget"
    private static let kWorkingAnimation = "notchcode.workingAnimation"
    private static let kNotifyOnWaiting   = "notchcode.notifyOnWaiting"
    private static let kFocusOnWaiting    = "notchcode.focusTerminalOnWaiting"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Claude plan (keeps the original un-prefixed keys for migration).
        let claudeDefault = PlanTier.default(for: .claude)
        let rawTier = defaults.string(forKey: Self.kPlanTier) ?? claudeDefault.rawValue
        let tier = PlanTier(rawValue: rawTier) ?? claudeDefault
        self.planTier = tier
        // Stored budget wins; otherwise seed from the tier preset. (didSet
        // doesn't fire during init, so this is the only seeding path.)
        self.weeklyTokenBudget = (defaults.object(forKey: Self.kWeeklyBudget) as? Int)
            ?? tier.defaultWeeklyTokenBudget
        self.dailyCapUSD = (defaults.object(forKey: Self.kDailyCap) as? Double) ?? 25

        // Codex plan (new prefixed keys; seeded from the Codex preset).
        let codexDefault = PlanTier.default(for: .codex)
        let rawCodexTier = defaults.string(forKey: Self.kCodexPlanTier) ?? codexDefault.rawValue
        let codexTier = PlanTier(rawValue: rawCodexTier) ?? codexDefault
        self.codexPlanTier = codexTier
        self.codexWeeklyTokenBudget = (defaults.object(forKey: Self.kCodexWeeklyBudget) as? Int)
            ?? codexTier.defaultWeeklyTokenBudget
        self.codexDailyCapUSD = (defaults.object(forKey: Self.kCodexDailyCap) as? Double) ?? 25

        self.usageTrackingEnabled = (defaults.object(forKey: Self.kUsageTracking) as? Bool) ?? true
        self.showUsageClaude = (defaults.object(forKey: Self.kShowUsageClaude) as? Bool) ?? true
        self.showUsageCodex = (defaults.object(forKey: Self.kShowUsageCodex) as? Bool) ?? true
        self.brakeThresholdPercent = (defaults.object(forKey: Self.kBrakeThreshold) as? Double) ?? 0.85
        let rawAnim = defaults.string(forKey: Self.kWorkingAnimation) ?? WorkingAnimation.mascot.rawValue
        self.workingAnimation = WorkingAnimation(rawValue: rawAnim) ?? .mascot
        self.notifyOnWaiting = (defaults.object(forKey: Self.kNotifyOnWaiting) as? Bool) ?? true
        self.focusTerminalOnWaiting = (defaults.object(forKey: Self.kFocusOnWaiting) as? Bool) ?? true
    }
}
