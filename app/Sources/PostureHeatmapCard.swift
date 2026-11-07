import SwiftUI

struct PostureHeatmapCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            PostureHeatmapView(
                heatmap: .build(
                    records: model.postureHistory.records, today: model.postureStats,
                    now: context.date
                ),
                tint: model.postureColors.bad
            )
        }
    }
}
