import SwiftUI

@main
struct UniAppApp: App {
    /// Gates the splash → onboarding transition. Lives at the app root so
    /// the splash runs **once per cold launch**. Background → foreground
    /// returns do NOT replay it (that's an iOS system-level transition,
    /// not a fresh launch — replaying would be noisy and breaks the "first
    /// breath" intent of the splash).
    @State private var hasFinishedSplash: Bool = false

    var body: some Scene {
        WindowGroup {
            Group {
                if hasFinishedSplash {
                    OnboardingView()
                } else {
                    SplashView(onComplete: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            hasFinishedSplash = true
                        }
                    })
                }
            }
            .uniAppEnvironment()
        }
    }
}
