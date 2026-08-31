import Foundation
import WhoopStore

/// Memoizes `Repository.widgetAnchor` across the high-frequency live-heart-rate path.
///
/// The anchor changes only when repository data changes or either day key rolls. The memo is owned by
/// the main-actor repository, is not observable, and retains no history beyond the selected row.
struct WidgetAnchorMemo {
    private var cached: (seq: Int, logicalKey: String, localKey: String, row: DailyMetric?)?

    mutating func resolve(
        days: [DailyMetric],
        seq: Int,
        logicalKey: String,
        localKey: String,
        compute: ([DailyMetric], String, String) -> DailyMetric?
    ) -> DailyMetric? {
        if let cached,
           cached.seq == seq,
           cached.logicalKey == logicalKey,
           cached.localKey == localKey {
            return cached.row
        }
        let row = compute(days, logicalKey, localKey)
        cached = (seq, logicalKey, localKey, row)
        return row
    }
}
