import SwiftUI

/// Opaque privacy overlay rendered the moment the app loses active
/// scene focus — and held in place until the foreground reveal
/// settles. Two responsibilities:
///
/// 1. **iOS task-switcher snapshot.** When iOS backgrounds the app
///    it captures a snapshot of the current frame for the multitask
///    switcher. Without a mask, the user's wallet home (balances,
///    addresses, transactions) is visible to anyone who can see
///    the device's app-switcher. Banking apps, password managers,
///    and Apple's own Wallet do exactly this — a brand mark on a
///    solid background while inactive.
/// 2. **Foreground reveal bridge.** When the app returns to active,
///    `AutoLockController` evaluates whether to flip `isLocked` —
///    and the lock surface needs a render pass to mount on top of
///    everything. The privacy mask covers that one-or-two-frame
///    gap so the user never sees their home screen flash before
///    the PIN screen arrives.
///
/// Same monochrome register as the splash, deliberately so — the
/// user reads the mask as "Aperture is loading" and the lock that
/// follows as the next beat in a single coherent sequence, not as
/// an interruption. No motion, no text, no loader; the simpler
/// the surface, the less it competes with the PIN prompt the user
/// is about to read.
///
/// Mounted in `AppRoot`'s ZStack (highest `zIndex` of the chrome
/// stack so it covers any presentation: sheets, full-screen
/// covers, the lock view itself). Gated on `scenePhase != .active
/// && PinCodePreference.isPinEnabled()` — PIN-disabled users
/// don't need a privacy mask because their wallet was already
/// reachable without authentication; adding a mask only for them
/// would be theatre.
struct PrivacyMaskView: View {
    var body: some View {
        ZStack {
            UniColors.Background.primary
                .ignoresSafeArea()

            Image("LogoCircle")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Aperture"))
    }
}

#Preview {
    PrivacyMaskView()
}
