import SwiftUI
import OSLog

// MARK: - Unified process screen (design_handoff_aperture_process_screens)
//
// **Single source of truth.** Wallet setup, factory reset, and remove-wallet
// share this chrome. Colors: UniColors only (Cloud / Midnight / Dark). Timing:
// per-step minimum dwell so the arc never skips even when work finishes early.

/// Content + tone for one process run.
struct ProcessLyricsConfiguration: Sendable, Equatable {
    struct Step: Sendable, Equatable, Identifiable {
        var id: Int { index }
        let index: Int
        let title: String
        let subtitle: String
        let systemImage: String
    }

    let steps: [Step]
    let completionTitle: String
    let completionSubtitle: String
    let primaryButtonTitle: String
    let footnote: String
    let footnoteSystemImage: String
    /// When true, working accent is reset danger; arc resolves to primary ink on done.
    let isDestructive: Bool
    /// Minimum on-screen time per step (handoff 1× segment durations).
    let minStepDurations: [Duration]
    let logCategory: String

    var stepCount: Int { steps.count }

    func minDuration(for index: Int, reduceMotion: Bool) -> Duration {
        let full: Duration
        if index >= 0, index < minStepDurations.count {
            full = minStepDurations[index]
        } else {
            full = .milliseconds(1_800)
        }
        return reduceMotion ? full / 2 : full
    }

    func withLogCategory(_ category: String) -> ProcessLyricsConfiguration {
        ProcessLyricsConfiguration(
            steps: steps,
            completionTitle: completionTitle,
            completionSubtitle: completionSubtitle,
            primaryButtonTitle: primaryButtonTitle,
            footnote: footnote,
            footnoteSystemImage: footnoteSystemImage,
            isDestructive: isDestructive,
            minStepDurations: minStepDurations,
            logCategory: category
        )
    }
}

// MARK: - Presets

extension ProcessLyricsConfiguration {
    /// Wallet create / import — handoff segment times 2100 / 2500 / 1900 / 1600ms.
    static func walletSetup(mode: WalletSetupProcessMode) -> ProcessLyricsConfiguration {
        let steps: [Step]
        switch mode {
        case .create:
            steps = [
                Step(index: 0, title: String.apertureLocalized("Deriving Keys"),
                     subtitle: String.apertureLocalized("Generating your addresses from the recovery phrase."),
                     systemImage: "key"),
                Step(index: 1, title: String.apertureLocalized("Encrypting"),
                     subtitle: String.apertureLocalized("Sealing your keys with device-bound encryption."),
                     systemImage: "lock"),
                Step(index: 2, title: String.apertureLocalized("Securing Wallet"),
                     subtitle: String.apertureLocalized("Writing your encrypted wallet to this iPhone."),
                     systemImage: "iphone"),
                Step(index: 3, title: String.apertureLocalized("Almost Ready"),
                     subtitle: String.apertureLocalized("Setting your wallet as active."),
                     systemImage: "sparkle")
            ]
        case .importWallet:
            steps = [
                Step(index: 0, title: String.apertureLocalized("Deriving Keys"),
                     subtitle: String.apertureLocalized("Computing addresses from your key material."),
                     systemImage: "key"),
                Step(index: 1, title: String.apertureLocalized("Encrypting"),
                     subtitle: String.apertureLocalized("Sealing your keys with device-bound encryption."),
                     systemImage: "lock"),
                Step(index: 2, title: String.apertureLocalized("Securing Wallet"),
                     subtitle: String.apertureLocalized("Writing your encrypted wallet to this iPhone."),
                     systemImage: "iphone"),
                Step(index: 3, title: String.apertureLocalized("Almost Ready"),
                     subtitle: String.apertureLocalized("Setting your wallet as active."),
                     systemImage: "sparkle")
            ]
        case .watchOnly:
            steps = [
                Step(index: 0, title: String.apertureLocalized("Checking Details"),
                     subtitle: String.apertureLocalized("Validating the addresses you entered."),
                     systemImage: "key"),
                Step(index: 1, title: String.apertureLocalized("Mapping Chains"),
                     subtitle: String.apertureLocalized("Preparing watch-only records on this device."),
                     systemImage: "lock"),
                Step(index: 2, title: String.apertureLocalized("Securing Wallet"),
                     subtitle: String.apertureLocalized("Writing your watch-only wallet to this iPhone."),
                     systemImage: "iphone"),
                Step(index: 3, title: String.apertureLocalized("Almost Ready"),
                     subtitle: String.apertureLocalized("Setting your wallet as active."),
                     systemImage: "sparkle")
            ]
        }

        let completionTitle = String.apertureLocalized("Wallet Ready")
        let completionSubtitle: String
        switch mode {
        case .create, .importWallet:
            completionSubtitle = String.apertureLocalized("Everything is set. Your keys never leave this device.")
        case .watchOnly:
            completionSubtitle = String.apertureLocalized("Your watch-only wallet is ready on this device.")
        }

        return ProcessLyricsConfiguration(
            steps: steps,
            completionTitle: completionTitle,
            completionSubtitle: completionSubtitle,
            primaryButtonTitle: String.apertureLocalized("Open Wallet"),
            footnote: String.apertureLocalized("Your recovery phrase never leaves this iPhone."),
            footnoteSystemImage: "lock.fill",
            isDestructive: false,
            // Faster setup — still readable, not flashy.
            minStepDurations: [
                .milliseconds(850),
                .milliseconds(1_000),
                .milliseconds(800),
                .milliseconds(700)
            ],
            logCategory: "wallet-setup-process"
        )
    }

    /// Factory reset — longer paced steps (heavier feel).
    static var factoryReset: ProcessLyricsConfiguration {
        ProcessLyricsConfiguration(
            steps: [
                Step(index: 0, title: String.apertureLocalized("Erasing Wallets"),
                     subtitle: String.apertureLocalized("Removing wallet records, balances, and history."),
                     systemImage: "trash"),
                Step(index: 1, title: String.apertureLocalized("Clearing Records"),
                     subtitle: String.apertureLocalized("Deleting security records and synced app data."),
                     systemImage: "doc.on.doc"),
                Step(index: 2, title: String.apertureLocalized("Wiping Keys"),
                     subtitle: String.apertureLocalized("Destroying seeds, recovery phrases, and private keys."),
                     systemImage: "key.slash"),
                Step(index: 3, title: String.apertureLocalized("Finishing Up"),
                     subtitle: String.apertureLocalized("Removing your passcode and app keys."),
                     systemImage: "circle.grid.2x2")
            ],
            completionTitle: String.apertureLocalized("Reset Complete"),
            completionSubtitle: String.apertureLocalized("Aperture has been erased from this device."),
            primaryButtonTitle: String.apertureLocalized("Done"),
            footnote: String.apertureLocalized("Erased data cannot be recovered."),
            footnoteSystemImage: "exclamationmark.circle",
            isDestructive: true,
            // Slower reset — deliberate pace for destructive work.
            minStepDurations: [
                .milliseconds(2_800),
                .milliseconds(2_600),
                .milliseconds(3_200),
                .milliseconds(2_400)
            ],
            logCategory: "reset-aperture-process"
        )
    }

    /// Remove a single wallet — destructive accent; paced like setup.
    static func removeWallet(walletName: String) -> ProcessLyricsConfiguration {
        ProcessLyricsConfiguration(
            steps: [
                Step(index: 0, title: String.apertureLocalized("Removing Addresses"),
                     subtitle: String.apertureLocalized("Clearing this wallet’s addresses on every network."),
                     systemImage: "number"),
                Step(index: 1, title: String.apertureLocalized("Clearing History"),
                     subtitle: String.apertureLocalized("Deleting transaction and chart history on this iPhone."),
                     systemImage: "chart.line.uptrend.xyaxis"),
                Step(index: 2, title: String.apertureLocalized("Wiping Keys"),
                     subtitle: String.apertureLocalized("Erasing encrypted keys for this wallet from the database."),
                     systemImage: "key.slash"),
                Step(index: 3, title: String.apertureLocalized("Finishing Up"),
                     subtitle: String.apertureLocalized("Updating your active wallet and cleaning up."),
                     systemImage: "sparkle")
            ],
            completionTitle: String.apertureLocalized("Wallet Removed"),
            completionSubtitle: String(
                format: String.apertureLocalized("%@ is no longer on this iPhone."),
                walletName
            ),
            primaryButtonTitle: String.apertureLocalized("Done"),
            footnote: String.apertureLocalized("Other wallets on this iPhone are untouched."),
            footnoteSystemImage: "checkmark.shield",
            isDestructive: true,
            minStepDurations: [
                .milliseconds(1_100),
                .milliseconds(1_200),
                .milliseconds(1_400),
                .milliseconds(1_000)
            ],
            logCategory: "remove-wallet-process"
        )
    }
}

// MARK: - Screen

/// Process UI: UniColors canvas, progress ring + glyphs, crossfading copy,
/// morphing dots, completion check, delayed primary button, footnote.
/// Each step has a **minimum dwell** so the sequence never flashes when work is fast.
struct ProcessLyricsScreen: View {
    let configuration: ProcessLyricsConfiguration
    let perform: (@escaping @MainActor (Int, Double) async -> Void) async throws -> Void
    let onPrimary: () -> Void
    var onSpecialError: ((Error) -> Bool)? = nil
    var mapFailureMessage: ((Error) -> String)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: Int = 0
    @State private var progress: Double = 0
    @State private var done = false
    @State private var showButton = false
    @State private var phase: Phase = .running
    @State private var didStart = false
    @State private var showPulse = false
    @State private var ringScale: CGFloat = 1
    @State private var stepEnteredAt: ContinuousClock.Instant = .now
    /// Highest step index real work has reached (may be ahead of paced UI).
    @State private var workStep: Int = 0
    @State private var workFraction: Double = 0
    @State private var workFinished = false
    @State private var workError: Error?

    private var log: Logger {
        Logger(subsystem: "com.thuglife.aperture", category: configuration.logCategory)
    }

    private enum Phase: Equatable {
        case running
        case finished
        case failed(String)
    }

    private let ringSize: CGFloat = 112
    private let ringRadius: CGFloat = 50
    private let ringStroke: CGFloat = 3
    private let hPad: CGFloat = 30

    private var workingAccent: Color {
        configuration.isDestructive ? UniColors.Reset.danger : UniColors.Text.primary
    }

    private var arcColor: Color {
        if done {
            return UniColors.Text.primary
        }
        return workingAccent
    }

    private var displayStep: Int {
        if done { return configuration.stepCount }
        return min(step, max(configuration.stepCount - 1, 0))
    }

    var body: some View {
        ZStack {
            UniColors.Background.primary.ignoresSafeArea()

            // Footer pinned to bottom; ring + copy + dots centered in leftover space.
            VStack(spacing: 0) {
                Spacer(minLength: 16)

                VStack(spacing: 0) {
                    progressRing
                        .frame(width: ringSize, height: ringSize)

                    Spacer().frame(height: 36)

                    stepCopyBlock
                        .frame(height: 98)
                        .frame(maxWidth: .infinity)

                    stepDots
                        .padding(.top, 2)
                        .opacity(done ? 0 : 1)
                        .animation(standardEase, value: done)
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 16)

                buttonZone
                    .frame(height: 52)

                footnote
                    .padding(.top, 20)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, hPad)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(UniColors.Background.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .interactiveDismissDisabled(phase == .running)
        .task {
            guard !didStart else { return }
            didStart = true
            await run()
        }
    }

    // MARK: - Ring

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(UniColors.Separator.regular.opacity(0.55), lineWidth: ringStroke)
                .frame(width: ringRadius * 2, height: ringRadius * 2)

            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(arcColor, style: StrokeStyle(lineWidth: ringStroke, lineCap: .round))
                .frame(width: ringRadius * 2, height: ringRadius * 2)
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: progress)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: done)

            if showPulse {
                Circle()
                    .stroke(UniColors.Text.primary.opacity(0.45), lineWidth: 1.5)
                    .frame(width: ringRadius * 2, height: ringRadius * 2)
                    .scaleEffect(showPulse ? 1.5 : 1)
                    .opacity(0)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.95),
                        value: showPulse
                    )
            }

            ZStack {
                ForEach(configuration.steps) { s in
                    Image(systemName: s.systemImage)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(UniColors.Text.primary.opacity(0.92))
                        .symbolRenderingMode(.monochrome)
                        .opacity(!done && displayStep == s.index ? 1 : 0)
                        .scaleEffect(!done && displayStep == s.index ? 1 : 0.86)
                        .animation(standardEase, value: displayStep)
                        .animation(standardEase, value: done)
                }

                Image(systemName: "checkmark")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(UniColors.Text.primary)
                    .opacity(done ? 1 : 0)
                    .scaleEffect(done ? 1 : 0.86)
                    .animation(
                        reduceMotion
                            ? .easeOut(duration: 0.2)
                            : .timingCurve(0.65, 0, 0.35, 1, duration: 0.5).delay(0.16),
                        value: done
                    )
            }
            .frame(width: 34, height: 34)
        }
        .scaleEffect(ringScale)
    }

    // MARK: - Copy

    private var stepCopyBlock: some View {
        ZStack {
            ForEach(0...configuration.stepCount, id: \.self) { i in
                let active = displayStep == i
                let (title, subtitle) = copy(for: i)
                VStack(spacing: 9) {
                    Text(title)
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.45)
                        .foregroundStyle(UniColors.Text.primary)
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(.system(size: 15, weight: .regular))
                        .tracking(-0.1)
                        .foregroundStyle(UniColors.Text.secondary)
                        .lineSpacing(4)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .padding(.horizontal, 8)
                .opacity(active ? 1 : 0)
                .offset(y: reduceMotion ? 0 : (active ? 0 : (displayStep > i ? -10 : 10)))
                .animation(standardEase, value: displayStep)
            }

            if case .failed(let message) = phase {
                Text(verbatim: message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(UniColors.Feedback.Error.foreground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func copy(for index: Int) -> (String, String) {
        if index >= configuration.stepCount {
            return (configuration.completionTitle, configuration.completionSubtitle)
        }
        let s = configuration.steps[index]
        return (s.title, s.subtitle)
    }

    // MARK: - Dots

    private var stepDots: some View {
        HStack(spacing: 7) {
            ForEach(0..<configuration.stepCount, id: \.self) { i in
                let active = !done && step == i
                let completed = i < step || done
                Capsule(style: .continuous)
                    .fill(dotColor(active: active, completed: completed))
                    .frame(width: active ? 20 : 6, height: 6)
                    .animation(standardEase, value: step)
                    .animation(standardEase, value: done)
            }
        }
        .frame(height: 6)
    }

    private func dotColor(active: Bool, completed: Bool) -> Color {
        if active {
            return workingAccent.opacity(configuration.isDestructive ? 1 : 0.95)
        }
        if completed {
            return UniColors.Text.primary.opacity(0.45)
        }
        return UniColors.Text.primary.opacity(0.18)
    }

    // MARK: - Button + footnote

    private var buttonZone: some View {
        ZStack {
            if case .failed = phase {
                UniButton(title: "Try Again", variant: .primary) {
                    Task { await run() }
                }
            } else {
                UniButton(
                    title: LocalizedStringKey(configuration.primaryButtonTitle),
                    variant: .primary
                ) {
                    onPrimary()
                }
                .opacity(showButton ? 1 : 0)
                .offset(y: reduceMotion ? 0 : (showButton ? 0 : 14))
                .allowsHitTesting(showButton)
                .animation(entranceEase, value: showButton)
            }
        }
    }

    private var footnote: some View {
        HStack(spacing: 6) {
            Image(systemName: configuration.footnoteSystemImage)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(UniColors.Text.tertiary)
            Text(configuration.footnote)
                .font(.system(size: 12, weight: .regular))
                .tracking(0.05)
                .foregroundStyle(UniColors.Text.tertiary)
        }
    }

    // MARK: - Motion

    private var standardEase: Animation {
        reduceMotion
            ? .easeOut(duration: 0.2)
            : .timingCurve(0.4, 0, 0.2, 1, duration: 0.48)
    }

    private var entranceEase: Animation {
        reduceMotion
            ? .easeOut(duration: 0.25)
            : .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.56)
    }

    // MARK: - Run (work + paced UI)

    private func run() async {
        phase = .running
        step = 0
        progress = 0
        done = false
        showButton = false
        showPulse = false
        ringScale = 1
        workStep = 0
        workFraction = 0
        workFinished = false
        workError = nil
        stepEnteredAt = .now

        try? await Task.sleep(for: .milliseconds(reduceMotion ? 80 : 280))

        // Real work in parallel; UI is paced by min step durations.
        let work = Task { @MainActor in
            do {
                try await perform { index, fraction in
                    workStep = max(workStep, min(index, configuration.stepCount - 1))
                    workFraction = max(workFraction, min(max(fraction, 0), 1))
                }
                workFinished = true
                workFraction = max(workFraction, 1)
            } catch {
                workError = error
                workFinished = true
            }
        }

        // Pace through each of the 4 steps with guaranteed dwell time.
        let n = max(configuration.stepCount, 1)
        for i in 0..<n {
            // Real haptic on every step start (including the first).
            playStepHaptic()
            if i > 0 {
                withAnimation(standardEase) {
                    step = i
                }
            }
            stepEnteredAt = .now

            // Segment targets: ease toward end of this segment (never backwards).
            let segmentStart = Double(i) / Double(n)
            let segmentEnd = Double(i + 1) / Double(n)
            setProgress(max(progress, segmentStart + 0.02))

            let minDwell = configuration.minDuration(for: i, reduceMotion: reduceMotion)
            let started = ContinuousClock.now

            // Poll until min dwell elapsed AND (work has reached this step end or finished).
            while true {
                if let err = workError {
                    work.cancel()
                    await handleFailure(err)
                    return
                }

                let elapsed = started.duration(to: .now)
                let workAhead = workFinished || workStep > i || workFraction >= segmentEnd - 0.001
                let dwellMet = elapsed >= minDwell
                let visual: Double
                if workFinished {
                    visual = segmentEnd
                } else {
                    // Soft climb within the segment while the min dwell ticks.
                    let climb = segmentStart + (segmentEnd - segmentStart)
                        * min(0.92, max(0.08, progressFraction(elapsed: elapsed, total: minDwell)))
                    visual = max(progress, min(segmentEnd, max(climb, workFraction)))
                }
                setProgress(visual)

                if dwellMet && (workAhead || workFinished) {
                    setProgress(max(progress, segmentEnd))
                    break
                }
                try? await Task.sleep(for: .milliseconds(32))
            }
        }

        _ = await work.result
        if let err = workError {
            await handleFailure(err)
            return
        }

        setProgress(1)
        try? await Task.sleep(for: .milliseconds(200))
        await completeSuccessfully()
    }

    private func progressFraction(elapsed: Duration, total: Duration) -> Double {
        let e = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let t = Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18
        guard t > 0 else { return 1 }
        return min(1, max(0, e / t))
    }

    private func handleFailure(_ error: Error) async {
        if onSpecialError?(error) == true { return }
        log.error("Process failed: \(String(describing: error), privacy: .public)")
        let message = mapFailureMessage?(error)
            ?? String(format: String.apertureLocalized("Something went wrong: %@. Tap Try Again."), error.localizedDescription)
        withAnimation(.easeOut(duration: 0.25)) {
            phase = .failed(message)
            showButton = true
        }
        UniHaptic.play(.warning)
    }

    private func setProgress(_ value: Double) {
        let next = max(progress, min(1, value))
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.35)) {
            progress = next
        }
    }

    /// Light impact tick — maps to a real `UIImpactFeedbackGenerator` path
    /// through UniHapticEngine (respects Settings → Haptics).
    private func playStepHaptic() {
        UniHaptic.play(.contextualImpact(.tap))
    }

    private func completeSuccessfully() async {
        UniHaptic.play(.success)
        withAnimation(standardEase) {
            done = true
            step = configuration.stepCount
            progress = 1
            phase = .finished
        }
        if !reduceMotion {
            showPulse = true
            withAnimation(.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.35).delay(0.08)) {
                ringScale = 1.045
            }
            try? await Task.sleep(for: .milliseconds(320))
            withAnimation(.easeOut(duration: 0.35)) {
                ringScale = 1
            }
        }
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 400))
        withAnimation(entranceEase) {
            showButton = true
        }
    }
}

#Preview("Wallet setup") {
    ProcessLyricsScreen(
        configuration: .walletSetup(mode: .create),
        perform: { report in
            // Fast work — UI still paces full step times.
            for i in 0..<4 {
                await report(i, Double(i + 1) / 4)
                try? await Task.sleep(for: .milliseconds(80))
            }
        },
        onPrimary: {}
    )
}

#Preview("Factory reset") {
    ProcessLyricsScreen(
        configuration: .factoryReset,
        perform: { report in
            for i in 0..<4 {
                await report(i, Double(i + 1) / 4)
                try? await Task.sleep(for: .milliseconds(50))
            }
        },
        onPrimary: {}
    )
}
