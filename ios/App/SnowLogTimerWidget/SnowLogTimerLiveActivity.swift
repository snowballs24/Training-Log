import ActivityKit
import SwiftUI
import WidgetKit

struct SnowLogTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SnowLogTimerAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.008, green: 0.024, blue: 0.09))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: context.attributes.workoutURL))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    snowLogMark
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedText(context: context)
                        .font(.title3.monospacedDigit().bold())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("Rest timer")
                        Spacer()
                        Text("Target \(formattedTarget(context.state))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            } compactLeading: {
                Image(systemName: "figure.strengthtraining.traditional")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                elapsedText(context: context)
                    .font(.caption2.monospacedDigit().bold())
                    .frame(width: 44)
            } minimal: {
                Image(systemName: "timer")
                    .foregroundStyle(.cyan)
            }
            .widgetURL(URL(string: context.attributes.workoutURL))
            .keylineTint(.cyan)
        }
    }

    private func lockScreenView(context: ActivityViewContext<SnowLogTimerAttributes>) -> some View {
        HStack(spacing: 14) {
            snowLogMark
            VStack(alignment: .leading, spacing: 3) {
                Text("SNOWLOG REST")
                    .font(.caption.bold())
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                elapsedText(context: context)
                    .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("TARGET")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Text(formattedTarget(context.state))
                    .font(.headline.monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .padding()
    }

    private var snowLogMark: some View {
        Image(systemName: "figure.strengthtraining.traditional")
            .font(.title2.bold())
            .foregroundStyle(.cyan)
            .frame(width: 38, height: 38)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func elapsedText(context: ActivityViewContext<SnowLogTimerAttributes>) -> some View {
        // The system-owned timer text keeps counting while SnowLog is suspended.
        // A periodic view refresh lets its emphasis cross the setpoint locally,
        // without requiring the app to wake up and update the Live Activity.
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(timerInterval: context.state.startDate...Date.distantFuture, countsDown: false)
                .foregroundStyle(timeline.date >= context.state.setpointDate ? Color.red : Color.white)
        }
    }

    private func formattedTarget(_ state: SnowLogTimerAttributes.ContentState) -> String {
        let seconds = max(0, Int(state.setpointDate.timeIntervalSince(state.startDate)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
