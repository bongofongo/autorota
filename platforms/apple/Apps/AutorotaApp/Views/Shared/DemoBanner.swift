import SwiftUI

/// Persistent checklist banner shown above the tab view while demo mode is
/// active. Mirrors `ReadOnlyBanner`'s slot and styling. Tapping the banner
/// opens the full step checklist; the trailing menu offers skip / restart /
/// exit. The completion card appears automatically when every step is
/// done or skipped.
struct DemoBanner: View {
    @Environment(DemoModeController.self) private var demo
    @State private var showChecklist = false
    @State private var showCompletion = false
    /// Set by the completion card's "Choose Your Plan": exit the demo only
    /// AFTER the sheet has fully dismissed. Exiting during the dismissal
    /// makes ContentView present the onboarding cover mid-transition, which
    /// renders the tier picker without its opaque backdrop.
    @State private var exitAfterCompletionDismiss = false

    var body: some View {
        HStack(spacing: 10) {
            Text("demo.banner.chip")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)

            // Title only — the step instruction lives in the pull-up
            // checklist sheet (tap the banner) to keep the preview compact.
            if let step = demo.currentStep {
                if showsHintNudge {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.pulse)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(LocalizedStringKey(step.titleKey))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("demo.banner.hint")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(LocalizedStringKey(step.titleKey))
                        .font(.subheadline.weight(.semibold))
                }
            } else {
                Text("demo.banner.complete.title")
                    .font(.subheadline.weight(.semibold))
            }

            Spacer(minLength: 8)

            if demo.isComplete {
                // Finished state: a checkmark marks the tour done and
                // reopens the completion card; tapping the banner itself
                // still opens the objectives checklist.
                Button {
                    showCompletion = true
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Demo finished")
                .accessibilityIdentifier("demo.banner.finished")
            } else {
                progressDots

                if demo.currentStep?.isManualAdvance == true {
                    Button("demo.banner.next") {
                        demo.advanceManualStep()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            menu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.14))
        .overlay(Divider(), alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture { showChecklist = true }
        .accessibilityIdentifier("demo.banner")
        .sheet(isPresented: $showChecklist) {
            DemoChecklistSheet()
        }
        .sheet(isPresented: $showCompletion, onDismiss: {
            if exitAfterCompletionDismiss {
                exitAfterCompletionDismiss = false
                demo.exitDemo()
            }
        }) {
            DemoCompletionCard(onChoosePlan: { exitAfterCompletionDismiss = true })
        }
        .onChange(of: demo.isComplete) { _, complete in
            if complete { showCompletion = true }
        }
        .alert(
            "demo.error.title",
            isPresented: Binding(
                get: { demo.lastError != nil },
                set: { if !$0 { demo.lastError = nil } }
            )
        ) {
            Button("onboarding.alert.ok") { demo.lastError = nil }
        } message: {
            Text(demo.lastError ?? "")
        }
    }

    /// Nudge the user toward the hint card when the spotlight can't help:
    /// on iOS that's the guidance-hidden state (wrong tab / skipped dry);
    /// macOS has no spotlight overlay at all, so the nudge always shows
    /// while a step is pending. See `DemoModeController.showsSpotlightHintNudge`
    /// in `Views/Platform/{iOS,macOS}`.
    private var showsHintNudge: Bool {
        demo.showsSpotlightHintNudge
    }

    private var progressDots: some View {
        HStack(spacing: 4) {
            ForEach(demo.steps) { step in
                Circle()
                    .fill(step.state == .pending
                          ? Color.secondary.opacity(0.3)
                          : Color.accentColor)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("demo.banner.progress.a11y \(demo.completedCount) \(demo.steps.count)")
        )
    }

    private var menu: some View {
        Menu {
            if let step = demo.currentStep, !step.isManualAdvance {
                Button {
                    demo.skipCurrentStep()
                } label: {
                    Label("demo.menu.skip_step", systemImage: "forward.end")
                }
            }
            Button {
                demo.restartTour()
            } label: {
                Label("demo.menu.restart", systemImage: "arrow.counterclockwise")
            }
            Divider()
            Button(role: .destructive) {
                demo.exitDemo()
            } label: {
                Label("demo.menu.exit", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("demo.banner.menu")
    }
}

/// Full step list, opened by tapping the banner.
private struct DemoChecklistSheet: View {
    @Environment(DemoModeController.self) private var demo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let path = demo.hintPath, let step = demo.currentStep {
                    hintCard(path: path, step: step)
                }
                Section {
                    ForEach(demo.steps) { step in
                        HStack(spacing: 12) {
                            stateIcon(step.state, isCurrent: step.id == demo.currentStep?.id)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LocalizedStringKey(step.titleKey))
                                    .font(.body.weight(
                                        step.id == demo.currentStep?.id ? .semibold : .regular
                                    ))
                                Text(LocalizedStringKey(step.instructionKey))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("demo.checklist.title")
            .demoChecklistInlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("demo.checklist.done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Expanded guidance for the current step: the next direction as a
    /// headline, then the full route with live done/current/todo markers.
    /// Updates as the user acts, so it can be followed at the medium detent.
    private func hintCard(path: [DemoHintItem], step: DemoStep) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("demo.hint.title")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(LocalizedStringKey(step.titleKey))
                        .font(.headline)
                }

                // The one thing to do next; falls back to the step's own
                // instruction when every direction reads satisfied and the
                // step is just waiting on its completion signal.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(LocalizedStringKey(
                        demo.currentHintItem?.instructionKey ?? step.instructionKey
                    ))
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("demo.hint.how")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(Array(path.enumerated()), id: \.element.id) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            hintItemIcon(item.state)
                            Text("\(index + 1).")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(LocalizedStringKey(item.instructionKey))
                                .font(.caption)
                                .fontWeight(item.state == .current ? .semibold : .regular)
                                .foregroundStyle(item.state == .todo ? .secondary : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityIdentifier("demo.hint.card")
        }
        .listRowBackground(Color.accentColor.opacity(0.08))
    }

    @ViewBuilder
    private func hintItemIcon(_ state: DemoHintItem.State) -> some View {
        switch state {
        case .satisfied:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        case .current:
            Image(systemName: "circle.dotted.circle")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        case .todo:
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: DemoStep.State, isCurrent: Bool) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
        case .skipped:
            Image(systemName: "forward.end.circle")
                .foregroundStyle(.secondary)
        case .pending:
            Image(systemName: isCurrent ? "circle.dotted.circle" : "circle")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
        }
    }
}

/// Congratulations card shown when the tour finishes. "Choose your plan"
/// flags the exit and dismisses; the banner exits the demo in the sheet's
/// onDismiss (after the transition), and ContentView then re-presents
/// onboarding at the tier picker for unlicensed users.
private struct DemoCompletionCard: View {
    let onChoosePlan: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .padding(.top, 28)

            Text("demo.completion.title")
                .font(.title.bold())
                .multilineTextAlignment(.center)

            Text("demo.completion.body")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            VStack(spacing: 10) {
                Button {
                    onChoosePlan()
                    dismiss()
                } label: {
                    Text("demo.completion.choose_plan")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("demo.completion.choosePlan")

                Button {
                    dismiss()
                } label: {
                    Text("demo.completion.keep_exploring")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 12)
        }
        .presentationDetents([.medium])
    }
}
