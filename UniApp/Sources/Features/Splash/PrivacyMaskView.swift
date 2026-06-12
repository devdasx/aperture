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
/// **2026-06-09 — wordmark + mark composition.** The user direction
/// was explicit: *"it should use wordmark app logo in privacy
/// screen, not only app icon."* The mask now shows the disc mark
/// stacked over the "Aperture" wordmark — the same composition the
/// splash screen uses at launch, so the user reads the mask as
/// "Aperture is loading" and the PIN that follows as the next beat
/// in a single coherent sequence.
///
/// Same monochrome register as the splash, deliberately so. No
/// motion, no tagline, no loader; the simpler the surface, the less
/// it competes with the PIN prompt the user is about to read.
///
/// Mounted in the detached lock overlay window (`LockOverlayRoot`
/// in UniAppApp.swift, 2026-06-13) at the topmost `zIndex` — above
/// the main window AND anything presented inside it, so the
/// task-switcher snapshot is shielded even when a sheet or
/// fullScreenCover (import flow, receive sheet) is up. Gated on
/// "scene not active" (mirrored via `AutoLockController.isSceneActive`)
/// `&& PinCodePreference.isPinEnabled() &&
/// PrivacyMaskPreference.isEnabled()` — PIN-disabled users don't
/// need a privacy mask because their wallet was already reachable
/// without authentication; users who explicitly toggled off
/// `PrivacyMaskPreference` opted out of the brand mask entirely.
struct PrivacyMaskView: View {
    var body: some View {
        ZStack {
            UniColors.Background.primary
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image("LogoCircle")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)

                // "Aperture" wordmark — same SF Pro Display 36pt
                // semibold + −1.26 kerning Stack the splash uses,
                // scaled down 0.86× so the wordmark + mark
                // composition reads at one comfortable glance.
                Text("Aperture")
                    .font(.system(size: 36, weight: .semibold, design: .default))
                    .kerning(-1.26)
                    .foregroundStyle(UniColors.Splash.mark)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Aperture"))
    }
}

#Preview {
    PrivacyMaskView()
}
