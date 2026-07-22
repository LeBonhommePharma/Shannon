import SwiftUI
import ShannonCore

@main
struct ShannonPhoneApp: App {
    @State private var model = PhoneModel()

    var body: some Scene {
        WindowGroup {
            HomeView(model: model)
                .preferredColorScheme(nil)   // dark first, light equally clean
                .task {
                    Haptics.prepare()
                    model.start()
                    await model.voice.requestAuthorization()
                }
        }
    }
}
