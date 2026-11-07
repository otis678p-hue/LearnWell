import SwiftUI

@main
enum PostureDetectionMain {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 2, arguments[1] == "--posture-selftest" {
            exit(PostureSelfTest.run())
        }
        if arguments.count >= 3, arguments[1] == "--posture-capture" {
            exit(PostureProbe.capture(path: arguments[2]))
        }
        if arguments.count >= 2, arguments[1] == "--posture-probe" {
            let seconds = arguments.count >= 3 ? Double(arguments[2]) ?? 8 : 8
            let exposure = arguments.count >= 4 ? Double(arguments[3]) : nil
            exit(PostureProbe.run(seconds: seconds, exposure: exposure))
        }
        PostureDetectionApp.main()
    }
}

struct PostureDetectionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("notch.appLanguage") private var appLanguageRawValue =
        AppLanguage.defaultLanguage.rawValue

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRawValue) ?? AppLanguage.defaultLanguage
    }

    var body: some Scene {
        Settings {
            SettingsRootView(model: appDelegate.model, onPaneChange: { _ in })
        }
        .environment(\.locale, appLanguage.locale)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.model.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .windowArrangement) {
                Button("Show Settings") {
                    appDelegate.model.openSettings()
                }

                Button("Show Notch Panel") {
                    appDelegate.showNotchPanel()
                }

            }
        }
    }
}
