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
                Text(LocalizedStringKey(step.titleKey))
                    .font(.subheadline.weight(.semibold))
            } else {
                Text("demo.banner.complete.title")
                    .font(.subheadline.weight(.semibold))
            }

            Spacer(minLength: 8)

            progressDots

            if demo.currentStep?.isManualAdvance == true {
                Button("demo.banner.next") {
                    demo.advanceManualStep()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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
        .sheet(isPresented: $showCompletion) {
            DemoCompletionCard()
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
                .font(.body)
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
            .navigationTitle("demo.checklist.title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("demo.checklist.done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
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
/// exits the demo; ContentView then re-presents onboarding at the tier
/// picker for unlicensed users.
private struct DemoCompletionCard: View {
    @Environment(DemoModeController.self) private var demo
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
                    dismiss()
                    demo.exitDemo()
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
