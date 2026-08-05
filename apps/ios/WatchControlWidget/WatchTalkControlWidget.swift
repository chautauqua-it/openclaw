import AppIntents
import SwiftUI
import WidgetKit

@available(watchOS 26.0, *)
@main
struct WatchControlWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchTalkControlWidget()
    }
}

@available(watchOS 26.0, *)
struct WatchTalkControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "it.differen.wad.watch.talk") {
            ControlWidgetButton(action: StartWatchTalkIntent()) {
                Label("Parla con Ianua", systemImage: "mic.fill")
            }
        }
        .displayName("Parla con Ianua")
        .description("Apri il microfono Ianua sul polso.")
    }
}
