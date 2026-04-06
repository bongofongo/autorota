import SwiftUI

private struct OnboardingPage: Identifiable {
    let id = UUID()
    let systemImage: String
    let title: String
    let description: String
}

private let pages: [OnboardingPage] = [
    OnboardingPage(
        systemImage: "cup.and.saucer.fill",
        title: "Welcome to Autorota",
        description: "The simple way to schedule shifts for your cafe. Set up your team, define your shifts, and generate weekly rotas in minutes."
    ),
    OnboardingPage(
        systemImage: "person.2.fill",
        title: "Your Team",
        description: "Add your employees in the Employees tab. Give them roles, set their hourly rates, and mark which days they can work."
    ),
    OnboardingPage(
        systemImage: "clock.fill",
        title: "Shift Templates",
        description: "Create reusable shift templates with start times, end times, and required roles. Templates save you time each week."
    ),
    OnboardingPage(
        systemImage: "calendar",
        title: "Your Rota",
        description: "View and manage your weekly schedule in the Rota tab. Generate rotas automatically, then adjust as needed."
    ),
]

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0

    private var isLastPage: Bool {
        currentPage == pages.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if !isLastPage {
                    Button("Skip") { isPresented = false }
                        .font(.title3)
                        .padding()
                }
            }

            #if os(iOS)
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    pageContent(systemImage: page.systemImage, title: page.title, description: page.description)
                        .tag(index)
                }
                finalPage.tag(pages.count)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            #else
            Group {
                if currentPage < pages.count {
                    let page = pages[currentPage]
                    pageContent(systemImage: page.systemImage, title: page.title, description: page.description)
                } else {
                    finalPage
                }
            }

            Spacer()

            HStack(spacing: 16) {
                if currentPage > 0 {
                    Button("Previous") { withAnimation { currentPage -= 1 } }
                        .font(.title3)
                }
                Spacer()
                pageIndicator
                Spacer()
                if isLastPage {
                    Button("Get Started") { isPresented = false }
                        .font(.title3.bold())
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Button("Next") { withAnimation { currentPage += 1 } }
                        .font(.title3)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            #endif
        }
        #if os(macOS)
        .frame(width: 600, height: 450)
        #endif
    }

    private func pageContent(systemImage: String, title: String, description: String) -> some View {
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
            Spacer()
        }
    }

    private var finalPage: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("You're All Set")
                .font(.largeTitle.bold())
            Text("Head to the Employees tab to add your first team member, then create shift templates and generate your rota.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            #if os(iOS)
            Button(action: { isPresented = false }) {
                Text("Get Started")
                    .font(.title3.bold())
                    .frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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
}
