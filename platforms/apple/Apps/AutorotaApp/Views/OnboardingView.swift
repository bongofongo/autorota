import SwiftUI
import AutorotaKit

private struct OnboardingPage: Identifiable {
    let id = UUID()
    let systemImage: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey
}

private let pages: [OnboardingPage] = [
    OnboardingPage(
        systemImage: "cup.and.saucer.fill",
        title: "onboarding.page.welcome.title",
        description: "onboarding.page.welcome.body"
    ),
    OnboardingPage(
        systemImage: "person.2.fill",
        title: "onboarding.page.team.title",
        description: "onboarding.page.team.body"
    ),
    OnboardingPage(
        systemImage: "clock.fill",
        title: "onboarding.page.shifts.title",
        description: "onboarding.page.shifts.body"
    ),
    OnboardingPage(
        systemImage: "calendar",
        title: "onboarding.page.rota.title",
        description: "onboarding.page.rota.body"
    ),
]

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @Environment(EmployeeUIBridge.self) private var employeeBridge
    @State private var currentPage = 0
    @State private var sampleLoadState: SampleLoadState = .idle
    @State private var sampleErrorMessage: String?

    private enum SampleLoadState: Equatable {
        case idle
        case loading
        case loaded
    }

    private var isLastPage: Bool {
        currentPage == pages.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if !isLastPage {
                    Button("onboarding.button.skip") { isPresented = false }
                        .font(.title3)
                        .padding()
                }
            }

            #if os(iOS)
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    pageContent(
                        systemImage: page.systemImage,
                        title: page.title,
                        description: page.description,
                        showsSampleData: index == 0
                    )
                    .tag(index)
                }
                finalPage.tag(pages.count)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            #else
            Group {
                if currentPage < pages.count {
                    let page = pages[currentPage]
                    pageContent(
                        systemImage: page.systemImage,
                        title: page.title,
                        description: page.description,
                        showsSampleData: currentPage == 0
                    )
                } else {
                    finalPage
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
                if isLastPage {
                    Button("onboarding.button.get_started") { isPresented = false }
                        .font(.title3.bold())
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Button("onboarding.button.next") { withAnimation { currentPage += 1 } }
                        .font(.title3)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            #endif
        }
        #if os(macOS)
        .frame(width: 600, height: 480)
        #endif
        .alert(
            "onboarding.sample.error.title",
            isPresented: Binding(
                get: { sampleErrorMessage != nil },
                set: { if !$0 { sampleErrorMessage = nil } }
            )
        ) {
            Button("onboarding.alert.ok") { sampleErrorMessage = nil }
        } message: {
            Text(sampleErrorMessage ?? "")
        }
    }

    private func pageContent(
        systemImage: String,
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        showsSampleData: Bool
    ) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text(title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(description)
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            if showsSampleData {
                sampleDataControl
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var sampleDataControl: some View {
        switch sampleLoadState {
        case .idle:
            Button {
                Task { await loadSampleData() }
            } label: {
                Label("onboarding.sample.load", systemImage: "tray.and.arrow.down")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.bordered)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("onboarding.sample.loading")
                    .foregroundStyle(.secondary)
            }
        case .loaded:
            Label("onboarding.sample.loaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.body.weight(.medium))
        }
    }

    private var finalPage: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("onboarding.page.ready.title")
                .font(.largeTitle.bold())
            Text("onboarding.page.ready.body")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            Button {
                employeeBridge.requestNewEmployeeSheet = true
                isPresented = false
            } label: {
                Text("onboarding.cta.add_first_employee")
                    .font(.title3.bold())
                    .frame(maxWidth: 320)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            #if os(iOS)
            Button("onboarding.button.get_started") { isPresented = false }
                .font(.body)
                .padding(.top, 4)
            #endif
            Spacer()
        }
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

    @MainActor
    private func loadSampleData() async {
        sampleLoadState = .loading
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try seedSampleData(overwrite: false)
            }.value
            sampleLoadState = .loaded
        } catch let error as FfiError {
            sampleLoadState = .idle
            sampleErrorMessage = localizeFfiError(error)
        } catch {
            sampleLoadState = .idle
            sampleErrorMessage = error.localizedDescription
        }
    }

    private func localizeFfiError(_ error: FfiError) -> String {
        let code: ErrorCode
        switch error {
        case .Db(let c, _), .NotFound(let c, _), .InvalidArgument(let c, _):
            code = c
        }
        return localizeError(code: code, localeId: Locale.current.identifier)
    }
}
