import SwiftUI
import AndroidMoverCore

/// 3.2: клікабельні компоненти шляху замість дефолтного текстового поля. Кожен компонент —
/// кнопка `onNavigate(fullPath)`, роздільник "›". Довгий шлях стискається з середини: перші 1
/// (корінь) + останні 3 компоненти, решта — у "…"-меню. Клік по порожньому місцю рядка (не по
/// самій кнопці) викликає `onEditRequested` — BrowserView перемикає pathBar на TextField.
struct BreadcrumbBar: View {
    let path: String
    let onNavigate: (String) -> Void
    let onEditRequested: () -> Void
    /// nil — без пункту "Додати в обране" в контекстному меню (не показувати, якщо додавання
    /// зараз неможливе, наприклад немає активного пристрою).
    var onAddFavorite: (() -> Void)?

    private struct Crumb: Identifiable {
        let id: String  // повний шлях цього сегмента — унікальний по побудові
        let name: String
    }

    /// Компоненти шляху від кореня до листа, побудовані ЛИШЕ через публічні
    /// unicodeScalars-безпечні примітиви RemotePath (baseName/parent) — жодного власного
    /// розбиття по "/" тут немає, щоб не дублювати (і не ризикувати розсинхронізувати) той
    /// самий фікс комбінуючих символів, що вже є в RemotePath.pathComponents.
    private var crumbs: [Crumb] {
        var chain: [(path: String, name: String)] = []
        var current = RemotePath.normalized(path)
        var guardCount = 0
        while current != "/", guardCount < 64 {
            chain.append((current, RemotePath.baseName(current)))
            current = RemotePath.parent(current)
            guardCount += 1
        }
        chain.append(("/", "/"))
        return chain.reversed().map { Crumb(id: $0.path, name: $0.name) }
    }

    var body: some View {
        HStack(spacing: 4) {
            let all = crumbs
            if all.count <= 4 {
                ForEach(Array(all.enumerated()), id: \.element.id) { index, crumb in
                    crumbButton(crumb, isLast: index == all.count - 1)
                }
            } else {
                crumbButton(all[0], isLast: false)
                overflowMenu(Array(all[1..<(all.count - 3)]))
                ForEach(Array(all.suffix(3).enumerated()), id: \.element.id) { offset, crumb in
                    crumbButton(crumb, isLast: offset == 2)
                }
            }
            // v0.10.2: явна кнопка редагування — клік у порожнє місце рядка лишається, але
            // це невидима зона; олівець видимий, доступний з клавіатури і для VoiceOver.
            Button {
                onEditRequested()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Редагувати шлях (⌘⇧G)")
            .accessibilityLabel("Редагувати шлях")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onEditRequested() }
        .contextMenu {
            if let onAddFavorite {
                Button("Додати в обране") { onAddFavorite() }
            }
        }
    }

    @ViewBuilder
    private func crumbButton(_ crumb: Crumb, isLast: Bool) -> some View {
        Button(crumb.name) { onNavigate(crumb.id) }
            .buttonStyle(.plain)
            .foregroundStyle(isLast ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .fontWeight(isLast ? .medium : .regular)
        if !isLast {
            Text("›").foregroundStyle(.tertiary)
        }
    }

    private func overflowMenu(_ hidden: [Crumb]) -> some View {
        Group {
            Menu("…") {
                ForEach(hidden) { crumb in
                    Button(crumb.name) { onNavigate(crumb.id) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Text("›").foregroundStyle(.tertiary)
        }
    }
}
