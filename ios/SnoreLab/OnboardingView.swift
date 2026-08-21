import SwiftUI

/// First-run onboarding (plan M6): how it works + the mic indicator, the
/// partner caveat, and the privacy/medical disclaimers — shown once, before
/// the first session can start.
struct OnboardingView: View {
    let onDone: () -> Void
    @State private var page = 0

    var body: some View {
        VStack {
            TabView(selection: $page) {
                pageView(
                    symbol: "moon.zzz.fill", tint: .indigo,
                    title: "Sleep. It listens.",
                    body: "Put your phone on the nightstand, plugged in, and tap Start. Overnight, Snore Laboratory listens for snoring and builds your morning report — when it happened, how loud it was, with short clips you can play back.\n\nYour phone's orange microphone indicator stays on all night. That's iOS telling you the mic is live — it's supposed to be there.")
                    .tag(0)
                pageView(
                    symbol: "person.2.fill", tint: .teal,
                    title: "One mic, one room",
                    body: "The microphone hears the whole room. Snore Laboratory can't tell who — or what — is snoring: a partner, a pet, or a rumbling fan can end up in your report.\n\nFor the cleanest nights, place the phone on your side of the bed, microphone toward you.")
                    .tag(1)
                pageView(
                    symbol: "lock.shield.fill", tint: .green,
                    title: "Private, and not a diagnosis",
                    body: "Everything stays on this phone: no accounts, no cloud, zero network calls. Only short clips of detected snoring are ever saved — never full-night audio — and audio is excluded from backups.\n\n\(medicalDisclaimer)")
                    .tag(2)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < 2 {
                    withAnimation { page += 1 }
                } else {
                    onDone()
                }
            } label: {
                Text(page < 2 ? "Continue" : "Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .interactiveDismissDisabled()
    }

    private func pageView(symbol: String, tint: Color, title: String,
                          body: String) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 64))
                .foregroundStyle(tint)
            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}
