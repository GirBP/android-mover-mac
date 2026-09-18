import SwiftUI

/// Тонкий жовтий банер "телефон відпав" — показується над таблицею в BrowserView, поки
/// `DeviceStore.showDisconnectBanner` каже true (15с грейс-період від `lastSeenReadyAt`),
/// замість миттєвого перемикання detail на OnboardingView. Якщо пристрій повертається в цей
/// час — банер зникає сам, browsing продовжується без переривання.
struct DisconnectBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Телефон відключено — очікую…")
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.18))
        .overlay(alignment: .bottom) { Divider() }
    }
}
