import ActivityKit
import Foundation

struct SnowLogTimerAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let startDate: Date
        let setpointDate: Date
    }

    let workoutURL: String
}
