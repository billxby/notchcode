// Inline settings page, rendered INSIDE the notch sheet — the web port of the
// Mac SettingsView. Same dark surface and typography as the session list; not a
// separate OS window. Sections: Usage tracking, Appearance, Claude Code
// integration, General (open at login), About.

import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { getVersion } from "@tauri-apps/api/app";
import { openUrl } from "@tauri-apps/plugin-opener";
import {
  type AppSettings,
  type PlanTier,
  type WorkingAnimation,
  PLAN_LABELS,
  PLAN_DEFAULT_BUDGET,
  WORKING_ANIM_LABELS,
  usesDollarBudget,
  compactTokens,
} from "./types";

const GITHUB_URL = "https://github.com/billxby/notchcode";

/** 1M steps below 10M, 5M above — usable across the whole free→Max 20× range. */
function budgetStep(current: number): number {
  return current < 10_000_000 ? 1_000_000 : 5_000_000;
}

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <div className="set-section">
      <div className="set-section-title">{title}</div>
      <div className="set-card">{children}</div>
    </div>
  );
}

function Toggle({
  checked,
  onChange,
  disabled,
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <button
      role="switch"
      aria-checked={checked}
      className={`toggle ${checked ? "on" : ""}`}
      disabled={disabled}
      onClick={() => onChange(!checked)}
    >
      <span className="toggle-knob" />
    </button>
  );
}

export default function SettingsView({
  settings,
  onChange,
  onClose,
}: {
  settings: AppSettings;
  onChange: (next: AppSettings) => void;
  onClose: () => void;
}) {
  const patch = (p: Partial<AppSettings>) => onChange({ ...settings, ...p });

  // Hook install state.
  const [installed, setInstalled] = useState(false);
  const [hookBusy, setHookBusy] = useState(false);
  const [hookErr, setHookErr] = useState<string | null>(null);
  // Launch-at-login (owned by the system; re-read after every toggle).
  const [autostart, setAutostart] = useState(false);
  const [version, setVersion] = useState("");

  useEffect(() => {
    invoke<boolean>("hooks_installed").then(setInstalled).catch(() => {});
    invoke<boolean>("autostart_enabled").then(setAutostart).catch(() => {});
    getVersion().then(setVersion).catch(() => {});
  }, []);

  async function runInstall() {
    setHookBusy(true);
    setHookErr(null);
    try {
      await invoke<string>("install_hooks");
      setInstalled(await invoke<boolean>("hooks_installed"));
    } catch (e) {
      setHookErr(String(e));
    } finally {
      setHookBusy(false);
    }
  }

  async function runRemove() {
    setHookBusy(true);
    setHookErr(null);
    try {
      await invoke<string>("uninstall_hooks");
      setInstalled(await invoke<boolean>("hooks_installed"));
    } catch (e) {
      setHookErr(String(e));
    } finally {
      setHookBusy(false);
    }
  }

  async function toggleAutostart(v: boolean) {
    try {
      await invoke("set_autostart", { enabled: v });
    } catch {
      /* keep UI honest by re-reading below */
    }
    setAutostart(await invoke<boolean>("autostart_enabled"));
  }

  function setPlan(tier: PlanTier) {
    // Switching tiers re-seeds the weekly budget with the new tier's preset.
    if (usesDollarBudget(tier)) {
      patch({ plan_tier: tier });
    } else {
      patch({ plan_tier: tier, weekly_token_budget: PLAN_DEFAULT_BUDGET[tier] });
    }
  }

  const dollarBudget = usesDollarBudget(settings.plan_tier);
  const tracking = settings.usage_tracking_enabled;

  return (
    <div className="sheet-inner settings">
      <div className="sheet-header">
        <span className="header-icon">⚙</span>
        <span className="header-title">Settings</span>
        <span className="spacer" />
        <button className="pill-btn" onClick={onClose}>
          Done
        </button>
      </div>
      <div className="sheet-divider" />

      <div className="sheet-body set-scroll">
        {/* Usage tracking */}
        <Section title="Usage tracking">
          <div className="set-row">
            <span className="set-label">Show usage in the notch</span>
            <Toggle
              checked={tracking}
              onChange={(v) => patch({ usage_tracking_enabled: v })}
            />
          </div>

          <div className="set-row">
            <span className="set-label">Your plan</span>
            <select
              className="select"
              value={settings.plan_tier}
              disabled={!tracking}
              onChange={(e) => setPlan(e.target.value as PlanTier)}
            >
              {(Object.keys(PLAN_LABELS) as PlanTier[]).map((t) => (
                <option key={t} value={t}>
                  {PLAN_LABELS[t]}
                </option>
              ))}
            </select>
          </div>

          {dollarBudget ? (
            <div className="set-row">
              <span className="set-label">Daily $ cap</span>
              <div className="stepper">
                <button
                  disabled={!tracking}
                  onClick={() =>
                    patch({ daily_cap_usd: Math.max(1, settings.daily_cap_usd - 5) })
                  }
                >
                  −
                </button>
                <span className="stepper-val">
                  ${settings.daily_cap_usd.toFixed(0)}
                </span>
                <button
                  disabled={!tracking}
                  onClick={() =>
                    patch({ daily_cap_usd: Math.min(500, settings.daily_cap_usd + 5) })
                  }
                >
                  +
                </button>
              </div>
            </div>
          ) : (
            <>
              <div className="set-row">
                <span className="set-label">Weekly budget</span>
                <div className="stepper">
                  <button
                    disabled={!tracking}
                    onClick={() =>
                      patch({
                        weekly_token_budget: Math.max(
                          1_000_000,
                          settings.weekly_token_budget -
                            budgetStep(settings.weekly_token_budget - 1)
                        ),
                      })
                    }
                  >
                    −
                  </button>
                  <span className="stepper-val">
                    {compactTokens(settings.weekly_token_budget)}
                  </span>
                  <button
                    disabled={!tracking}
                    onClick={() =>
                      patch({
                        weekly_token_budget:
                          settings.weekly_token_budget +
                          budgetStep(settings.weekly_token_budget),
                      })
                    }
                  >
                    +
                  </button>
                </div>
              </div>

              <div className="set-stack">
                <div className="set-row">
                  <span className="set-label">Brake fires at</span>
                  <span className="set-value">
                    {Math.round(settings.brake_threshold_percent * 100)}% of budget
                  </span>
                </div>
                <input
                  type="range"
                  className="slider"
                  min={0.5}
                  max={1}
                  step={0.05}
                  disabled={!tracking}
                  value={settings.brake_threshold_percent}
                  onChange={(e) =>
                    patch({ brake_threshold_percent: Number(e.target.value) })
                  }
                />
              </div>
            </>
          )}

          <div className="set-note">
            <span className="note-icon">ⓘ</span>
            <span>
              Token counts are exact, parsed from this PC's Claude Code logs —
              sessions on other devices aren't counted. The budget is your own
              gauge; Anthropic doesn't publish per-plan token limits.
            </span>
          </div>
        </Section>

        {/* Appearance */}
        <Section title="Appearance">
          <div className="set-row">
            <span className="set-label">Working animation</span>
            <select
              className="select"
              value={settings.working_animation}
              onChange={(e) =>
                patch({ working_animation: e.target.value as WorkingAnimation })
              }
            >
              {(Object.keys(WORKING_ANIM_LABELS) as WorkingAnimation[]).map((a) => (
                <option key={a} value={a}>
                  {WORKING_ANIM_LABELS[a]}
                </option>
              ))}
            </select>
          </div>
          <div className="set-help">
            How the notch shows that Claude is working. Spinner cycles the CLI
            dingbats; pulse breathes the chat-logo star; mascot walks in place.
          </div>
        </Section>

        {/* Integration */}
        <Section title="Claude Code integration">
          <div className="set-row">
            <span
              className={`status-chip ${installed ? "ok" : "warn"}`}
            >
              {installed ? "✓ Hooks installed" : "! Hooks not installed"}
            </span>
          </div>
          <div className="set-help">
            {installed
              ? "Notchcode is wired into ~/.claude/settings.json. Reinstall to refresh after a Claude Code update."
              : "Notchcode can't see your Claude Code sessions until the hook entries are added."}
          </div>
          <div className="set-actions">
            {installed ? (
              <>
                <button
                  className="btn primary"
                  disabled={hookBusy}
                  onClick={runInstall}
                >
                  Reinstall
                </button>
                <button className="btn" disabled={hookBusy} onClick={runRemove}>
                  Remove
                </button>
              </>
            ) : (
              <button
                className="btn accent"
                disabled={hookBusy}
                onClick={runInstall}
              >
                {hookBusy ? "Installing…" : "Install hooks"}
              </button>
            )}
          </div>
          {hookErr && <div className="set-error">{hookErr}</div>}
        </Section>

        {/* General */}
        <Section title="General">
          <div className="set-row">
            <span className="set-label">Open at login</span>
            <Toggle checked={autostart} onChange={toggleAutostart} />
          </div>
          <div className="set-help">
            Start Notchcode automatically when you log in to this PC.
          </div>
        </Section>

        {/* About */}
        <Section title="About">
          <div className="about-row">
            <div className="about-text">
              <div className="about-name">Notchcode</div>
              <div className="about-tag">Ambient monitor for Claude Code</div>
              {version && <div className="about-ver">v{version}</div>}
            </div>
            <span className="spacer" />
            <button className="pill-btn" onClick={() => openUrl(GITHUB_URL)}>
              GitHub
            </button>
            <button className="pill-btn" onClick={() => invoke("quit")}>
              Quit
            </button>
          </div>
        </Section>
      </div>
    </div>
  );
}
