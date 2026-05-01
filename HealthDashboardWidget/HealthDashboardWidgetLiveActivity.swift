//
//  HealthDashboardWidgetLiveActivity.swift
//  HealthDashboardWidget
//
//  Created by Mark Calabrese on 1/21/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct HealthDashboardWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct HealthDashboardWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HealthDashboardWidgetAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension HealthDashboardWidgetAttributes {
    fileprivate static var preview: HealthDashboardWidgetAttributes {
        HealthDashboardWidgetAttributes(name: "World")
    }
}

extension HealthDashboardWidgetAttributes.ContentState {
    fileprivate static var smiley: HealthDashboardWidgetAttributes.ContentState {
        HealthDashboardWidgetAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: HealthDashboardWidgetAttributes.ContentState {
         HealthDashboardWidgetAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: HealthDashboardWidgetAttributes.preview) {
   HealthDashboardWidgetLiveActivity()
} contentStates: {
    HealthDashboardWidgetAttributes.ContentState.smiley
    HealthDashboardWidgetAttributes.ContentState.starEyes
}
