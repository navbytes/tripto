// Motion vocabulary — hand-written companion to the generated Tokens.swift
// (same convention as PaletteExtras.swift; gen_tokens.py never touches this).
// Frozen API per PLAN-signature-layer.md §D2 — packages consume, don't extend.

import SwiftUI

/// One spring family for the whole app. New animation call sites MUST use
/// `Motion.*`; existing ad-hoc animations migrate only inside files a work
/// package already owns.
public enum Motion {
    /// Chips, toggles, stamps — quick acknowledgments.
    public static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.90)
    /// Hero flight, card/stub travel — the signature tier.
    public static let standard = Animation.spring(response: 0.38, dampingFraction: 0.85)
    /// Large-area settles, staggered reveals, art intros.
    public static let gentle = Animation.spring(response: 0.55, dampingFraction: 0.92)
    /// Legacy fade tier (matches the tab underline's existing 0.18 easeInOut).
    public static let fade = Animation.easeInOut(duration: 0.18)

    /// Reduce-motion policy in one place: returns nil under RM so
    /// `withAnimation(Motion.m(.standard, reduceMotion: rm))` applies the
    /// state change instantly instead of animating it.
    public static func m(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// Semantic haptic map (SwiftUI SensoryFeedback). Policy: haptics stay ON
/// under Reduce Motion — RM is a visual setting; haptics are the non-visual
/// feedback channel.
public enum Haptics {
    /// Committed saves (existing app convention).
    public static let success: SensoryFeedback = .success
    /// Destructive confirms (existing app convention).
    public static let warning: SensoryFeedback = .warning
    /// Copy-tap first beat, press acknowledgment.
    public static let touch: SensoryFeedback = .impact(weight: .light)
    /// Tear progress, discovery nudge.
    public static let tick: SensoryFeedback = .selection
    /// Flight lands, stub detaches.
    public static let settle: SensoryFeedback = .impact(weight: .medium)
}
