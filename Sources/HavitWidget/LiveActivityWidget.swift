import ActivityKit
import Shared
import SwiftUI
import WidgetKit

@main
struct HavitWidget: WidgetBundle {
    var body: some Widget { FocusLiveActivity() }
}

struct FocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "timer").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ESTUDIO").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(timerInterval: context.attributes.startedAt...context.state.timerEnd, countsDown: true)
                        .font(.system(.title2, design: .rounded, weight: .bold).monospacedDigit())
                }
                Spacer()
                Label("\(context.state.pendingTasks) pendientes", systemImage: "checklist")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }
            .padding()
            .foregroundStyle(.white)
            .widgetURL(URL(string: "havit://study"))
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Image(systemName: "timer").font(.title3).foregroundStyle(.orange)
                        Text("ESTUDIO").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    }
                    .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.attributes.startedAt...context.state.timerEnd, countsDown: true)
                        .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        Image(systemName: "checklist").foregroundStyle(.orange)
                        Text("\(context.state.pendingTasks) tareas pendientes").fontWeight(.semibold)
                        Spacer(minLength: 4)
                        Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(.orange)
            } compactTrailing: {
                Text(timerInterval: context.attributes.startedAt...context.state.timerEnd, countsDown: true)
                    .font(.system(.caption2, design: .rounded, weight: .bold).monospacedDigit())
                    .frame(width: 38)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(.orange)
            }
            .widgetURL(URL(string: "havit://study"))
            .keylineTint(.orange)
        }
    }
}
