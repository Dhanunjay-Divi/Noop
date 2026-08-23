import Foundation
import SwiftUI

// MARK: - Editable Key-Metrics layout (#251)
//
// The Today screen's "Key Metrics" grid has ten available tiles. This lets the user pin three to five in
// their preferred order. A fresh install starts with NOOP's three core daily signals — Recovery, Effort,
// and Sleep — while every other metric follows them in the complete catalog. Persistence is display-only:
// no metric is computed or stored differently.
//
// Stored as a single comma-joined string of metric keys in @AppStorage (UserDefaults), the same
// mechanism every other macOS NOOP preference uses. The Android side mirrors this exactly in
// KeyMetricPrefs.kt (SharedPreferences "today.keyMetrics"). Unknown keys are dropped on read and any
// known key missing from the saved list is treated as unpinned and remains visible after the priority set.

/// One of the Today screen's Key-Metric tiles. The rawValue is the stable persisted identifier — keep it
/// byte-identical to the Android `KeyMetric` enum so a backup/restore reads the same layout on either OS.
enum KeyMetric: String, CaseIterable, Identifiable {
    case charge
    case effort
    case rest
    case hrv
    case restingHr
    case bloodOxygen
    case respiratory
    case steps
    case weight
    case calories

    var id: String { rawValue }

    /// Whether the metric has a truthful, fixed progress scale. Raw physiology is deliberately false:
    /// HRV/heart rate/respiration/SpO₂ are readings to compare with a personal baseline, not goals where
    /// a fuller bar means healthier. Steps and calories also stay false until the user owns an explicit
    /// goal rather than NOOP silently assuming 10,000 steps or 800 kcal.
    var isBoundedProgress: Bool {
        switch self {
        case .charge, .effort, .rest: return true
        case .hrv, .restingHr, .bloodOxygen, .respiratory, .steps, .weight, .calories: return false
        }
    }

    /// The tile's display label — matches the `StatTile(label:)` text rendered on the grid.
    var title: String {
        switch self {
        case .charge:      return String(localized: "Recovery")
        case .effort:      return String(localized: "Effort")
        case .rest:        return String(localized: "Sleep")
        case .hrv:         return "HRV"
        case .restingHr:   return String(localized: "Resting HR")
        case .bloodOxygen: return String(localized: "Blood Oxygen")
        case .respiratory: return String(localized: "Respiratory")
        case .steps:       return String(localized: "Steps")
        case .weight:      return String(localized: "Weight")
        case .calories:    return String(localized: "Calories")
        }
    }

    /// Canonical semantic glyph for this metric. Keeping it beside the name mapping prevents the
    /// Liquid and classic dashboards from drifting into different icon languages.
    var icon: String {
        switch self {
        case .charge:      return "bolt.heart.fill"
        case .effort:      return "flame.fill"
        case .rest:        return "moon.stars.fill"
        case .hrv:         return "waveform.path.ecg"
        case .restingHr:   return "heart.fill"
        case .bloodOxygen: return "drop.fill"
        case .respiratory: return "lungs.fill"
        case .steps:       return "figure.walk"
        case .weight:      return "scalemass.fill"
        case .calories:    return "flame.circle.fill"
        }
    }

    /// Canonical catalog order. This includes every choice and is also used to order unselected options.
    static let defaultOrder: [KeyMetric] = [
        .charge, .effort, .rest, .hrv, .restingHr,
        .bloodOxygen, .respiratory, .steps, .weight, .calories,
    ]

    /// NOOP's useful fresh-install starting point. Users can replace or extend it up to five metrics.
    static let defaultSelection: [KeyMetric] = [.charge, .effort, .rest]
}

/// Display-only persistence for the Key-Metrics layout. Holds an ORDERED list of pinned tiles; a tile not
/// in the list remains visible after them. Mirrors @AppStorage("today.keyMetrics") + the Android side.
enum KeyMetricPrefs {
    /// UserDefaults key — a comma-joined list of `KeyMetric` rawValues in display order.
    static let layoutKey = "today.keyMetrics"
    static let minimumSelectionCount = 3
    static let maximumSelectionCount = 5

    /// Encode a valid ordered pin set. This boundary also protects callers other than the editor from
    /// persisting duplicates, an empty dashboard, or more tiles than the Today surface supports.
    static func encode(_ metrics: [KeyMetric]) -> String {
        normalized(metrics).map(\.rawValue).joined(separator: ",")
    }

    /// Decode the stored string into an ordered pin set. Empty, unset, or all-unknown data yields the
    /// three core defaults. Older app versions allowed more than five; preserving their first five makes
    /// that migration deterministic and keeps the user's strongest ordering signal.
    static func decodeEnabled(_ raw: String) -> [KeyMetric] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return KeyMetric.defaultSelection }
        var seen = Set<KeyMetric>()
        var result: [KeyMetric] = []
        for token in trimmed.split(separator: ",") {
            let rawValue = String(token).trimmingCharacters(in: .whitespaces)
            if let m = KeyMetric(rawValue: rawValue), seen.insert(m).inserted {
                result.append(m)
                if result.count == maximumSelectionCount { break }
            }
        }
        return normalized(result)
    }

    /// Ordered dedupe + bounds shared by encoding and tests. A short or empty request is completed from
    /// the three product defaults first, then the canonical catalog. This migrates older one/two-tile
    /// preferences without discarding the user's chosen order.
    static func normalized(_ metrics: [KeyMetric]) -> [KeyMetric] {
        var seen = Set<KeyMetric>()
        var selected = Array(metrics.filter { seen.insert($0).inserted }
            .prefix(maximumSelectionCount))
        for fallback in KeyMetric.defaultSelection + KeyMetric.defaultOrder
        where selected.count < minimumSelectionCount && seen.insert(fallback).inserted {
            selected.append(fallback)
        }
        return selected
    }

    /// The full dashboard catalog with the user's pinned metrics first. Resolving this display order never
    /// changes or expands the saved three-to-five pin set.
    static func catalogOrder(startingWith metrics: [KeyMetric]) -> [KeyMetric] {
        let selected = normalized(metrics)
        let selectedSet = Set(selected)
        return selected + KeyMetric.defaultOrder.filter { !selectedSet.contains($0) }
    }
}
