import SwiftUI
import AutorotaKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

private struct OnboardingPage: Identifiable {
    enum Mockup { case schedule, availability, generate, export }

    let id = UUID()
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let mockup: Mockup
    /// Asset-catalog name for the hero screenshot. When the named image is
    /// present in `Assets.xcassets`, it renders as the slide's hero. When
    /// absent, the legacy animated mockup stands in as a placeholder so the
    /// slide is never blank. Drop a PNG with this exact name to ship real
    /// screenshots — no code change required.
    let screenshotAsset: String
}

private let pages: [OnboardingPage] = [
    OnboardingPage(
        title: "onboarding.page.schedule.title",
        subtitle: "onboarding.page.schedule.body",
        mockup: .schedule,
        screenshotAsset: "onboarding-schedule"
    ),
    OnboardingPage(
        title: "onboarding.page.availability.title",
        subtitle: "onboarding.page.availability.body",
        mockup: .availability,
        screenshotAsset: "onboarding-availability"
    ),
    OnboardingPage(
        title: "onboarding.page.generate.title",
        subtitle: "onboarding.page.generate.body",
        mockup: .generate,
        screenshotAsset: "onboarding-generate"
    ),
    OnboardingPage(
        title: "onboarding.page.export.title",
        subtitle: "onboarding.page.export.body",
        mockup: .export,
        screenshotAsset: "onboarding-export"
    ),
]

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0

    private var isLastPage: Bool { currentPage == pages.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if !isLastPage {
                    Button("onboarding.button.skip") { currentPage = pages.count }
                        .font(.title3)
                        .padding()
                }
            }

            #if os(iOS)
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    slide(for: page)
                        .tag(index)
                }
                TierPickView(isPresented: $isPresented).tag(pages.count)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            #else
            Group {
                if currentPage < pages.count {
                    slide(for: pages[currentPage])
                } else {
                    TierPickView(isPresented: $isPresented)
                }
            }

            Spacer()

            HStack(spacing: 16) {
                if currentPage > 0 {
                    Button("onboarding.button.previous") { withAnimation { currentPage -= 1 } }
                        .font(.title3)
                }
                Spacer()
                pageIndicator
                Spacer()
                if !isLastPage {
                    Button("onboarding.button.next") { withAnimation { currentPage += 1 } }
                        .font(.title3)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            #endif
        }
        #if os(macOS)
        .frame(width: 640, height: 540)
        #endif
    }

    @ViewBuilder
    private func slide(for page: OnboardingPage) -> some View {
        CarouselSlide(title: page.title, subtitle: page.subtitle) {
            hybridMockup(for: page)
        }
    }

    /// Hero screenshot (when the asset is present) plus a small always-on
    /// animated decoration. Falls back to the full legacy mockup when no
    /// PNG has been dropped into the asset catalog yet.
    @ViewBuilder
    private func hybridMockup(for page: OnboardingPage) -> some View {
        ZStack(alignment: .topTrailing) {
            if assetExists(page.screenshotAsset) {
                Image(page.screenshotAsset)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(.tint.opacity(0.25), lineWidth: 1)
                    )
            } else {
                mockup(for: page.mockup)
            }
            LiveDecoration()
                .padding(10)
        }
    }

    @ViewBuilder
    private func mockup(for kind: OnboardingPage.Mockup) -> some View {
        switch kind {
        case .schedule: ScheduleMockup()
        case .availability: AvailabilityMockup()
        case .generate: AutoGenerateMockup()
        case .export: ExportMockup()
        }
    }

    private func assetExists(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(named: name) != nil
        #else
        return NSImage(named: name) != nil
        #endif
    }

    #if os(macOS)
    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0...pages.count, id: \.self) { index in
                Circle()
                    .fill(index == currentPage ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }
    #endif
}

// MARK: - Carousel slide chrome

private struct CarouselSlide<Mockup: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let mockup: () -> Mockup

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)

            mockup()
                .frame(maxWidth: 360, maxHeight: 360)
                .padding(.horizontal, 24)

            VStack(spacing: 12) {
                Text(title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }

            Spacer(minLength: 12)
        }
        .padding(.vertical, 16)
    }
}

// MARK: - Animated mockups
//
// Each mockup loops continuously via TimelineView so the slide feels alive
// without needing asset videos. The mockups are pure SwiftUI primitives and
// never read or write any real data.

private struct ScheduleMockup: View {
    private let weekdays = ["M", "T", "W", "T", "F", "S", "S"]
    private let employees = ["Alice", "Bob", "Cara", "Dan", "Eve"]

    var body: some View {
        TimelineView(.animation) { ctx in
            let phase = phase(at: ctx.date)
            grid(phase: phase)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.tint.opacity(0.25), lineWidth: 1)
        )
    }

    private func phase(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        return (t.truncatingRemainder(dividingBy: 3.5)) / 3.5
    }

    @ViewBuilder
    private func grid(phase: Double) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text("")
                    .frame(width: 56)
                ForEach(weekdays.indices, id: \.self) { i in
                    Text(weekdays[i])
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(employees.indices, id: \.self) { row in
                let visible = phase * Double(employees.count) > Double(row)
                HStack(spacing: 4) {
                    Text(employees[row])
                        .font(.caption.weight(.medium))
                        .frame(width: 56, alignment: .leading)
                        .lineLimit(1)
                    ForEach(0..<7, id: \.self) { col in
                        cell(row: row, col: col, visible: visible)
                    }
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func cell(row: Int, col: Int, visible: Bool) -> some View {
        let filled = (row + col * 3) % 7 < 4
        RoundedRectangle(cornerRadius: 4)
            .fill(filled ? Color.accentColor.opacity(visible ? 0.6 : 0) : Color.secondary.opacity(visible ? 0.12 : 0))
            .frame(height: 18)
            .animation(.easeOut(duration: 0.3), value: visible)
    }
}

private struct AvailabilityMockup: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let phase = Int((ctx.date.timeIntervalSinceReferenceDate * 2).truncatingRemainder(dividingBy: 3))
            grid(phase: phase)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.tint.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func grid(phase: Int) -> some View {
        VStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<8, id: \.self) { col in
                        cell(row: row, col: col, phase: phase)
                    }
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func cell(row: Int, col: Int, phase: Int) -> some View {
        let v = (row * 8 + col + phase * 5) % 7
        let color: Color = {
            switch v % 3 {
            case 0: return .green.opacity(0.7)
            case 1: return .yellow.opacity(0.55)
            default: return .red.opacity(0.45)
            }
        }()
        RoundedRectangle(cornerRadius: 5)
            .fill(color)
            .frame(width: 28, height: 22)
            .animation(.easeInOut(duration: 0.4), value: phase)
    }
}

private struct AutoGenerateMockup: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let phase = (ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.0)) / 4.0
            stack(phase: phase)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.tint.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func stack(phase: Double) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.tint)
                Text("Generate")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                ProgressView(value: phase)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(width: 80)
            }
            ForEach(0..<5, id: \.self) { row in
                let visible = phase * 5 > Double(row)
                HStack(spacing: 8) {
                    Circle()
                        .fill(.tint.opacity(visible ? 0.8 : 0.15))
                        .frame(width: 10, height: 10)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.tint.opacity(visible ? 0.25 : 0.08))
                        .frame(height: 18)
                        .overlay(alignment: .leading) {
                            if visible {
                                Text(rowLabel(row))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 8)
                            }
                        }
                }
                .animation(.easeOut(duration: 0.35), value: visible)
            }
        }
        .padding(20)
    }

    private func rowLabel(_ i: Int) -> String {
        ["Mon · Opening", "Tue · Midday", "Wed · Close", "Thu · Kitchen", "Fri · Lead"][i]
    }
}

private struct ExportMockup: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5.0)
            page(phase: phase)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.tint.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func page(phase: Double) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(.tint)
                Text("Schedule · Apr 20–26")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.tint)
                    .scaleEffect(1 + 0.08 * sin(phase * .pi))
            }
            .padding(.bottom, 4)
            VStack(spacing: 5) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(width: 50, height: 12)
                        ForEach(0..<7, id: \.self) { col in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(barColor(row: row, col: col))
                                .frame(height: 12)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                ForEach(["PDF", "CSV", "JSON"], id: \.self) { tag in
                    Text(tag)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                }
            }
            .padding(.top, 4)
        }
        .padding(18)
    }

    private func barColor(row: Int, col: Int) -> Color {
        if row == 0 { return Color.secondary.opacity(0.25) }
        return ((row + col) % 4 == 0) ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.12)
    }
}

/// Tiny pulsing dot rendered on top of every onboarding hero so a static
/// screenshot still feels alive. Sized small enough to never compete with
/// the underlying art.
private struct LiveDecoration: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            dot(at: ctx.date)
        }
    }

    private func dot(at date: Date) -> some View {
        let phase = sin(date.timeIntervalSinceReferenceDate * 2.0)
        return Circle()
            .fill(Color.accentColor)
            .frame(width: 10, height: 10)
            .scaleEffect(1.0 + 0.25 * phase)
            .opacity(0.7 + 0.3 * phase)
            .shadow(color: Color.accentColor.opacity(0.4), radius: 4)
    }
}
