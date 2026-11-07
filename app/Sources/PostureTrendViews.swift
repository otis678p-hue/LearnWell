import SwiftUI

struct PostureTrendCard: View {
    @ObservedObject var model: AppModel
    @AppStorage("notch.posture.trendRange") private var storedRange = PostureTrendRange.week.rawValue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            PostureTrendView(
                records: model.postureHistory.records, today: model.postureStats,
                range: Binding(
                    get: { PostureTrendRange(rawValue: storedRange) ?? .week },
                    set: { storedRange = $0.rawValue }
                ),
                goodColor: model.postureColors.good, badColor: model.postureColors.bad,
                now: context.date
            )
        }
    }
}
