import SwiftUI

/// 3.C: alert-и FileActions (перейменувати/нова тека/помилка дії), винесені з BrowserView.swift
/// окремим extension-файлом — інакше той ліз за 400-рядкову межу (той самий підхід, що 3.1
/// застосувала до toolbarContent у BrowserView+Toolbar.swift). `state` у BrowserView не
/// `private`, тож доступний тут напряму.
extension BrowserView {
    @ViewBuilder
    func attachFileActionAlerts<Content: View>(to content: Content) -> some View {
        content
            .alert(
                "Перейменувати",
                isPresented: Binding(
                    get: { state.files.renamingEntry != nil },
                    set: { if !$0 { state.files.renamingEntry = nil } }
                )
            ) {
                TextField("Нове ім'я", text: $state.files.renameText)
                Button("Перейменувати") { state.files.confirmRename() }
                Button("Скасувати", role: .cancel) { state.files.renamingEntry = nil }
            } message: {
                Text(state.files.renamingEntry.map { "«\($0.name)»" } ?? "")
            }
            .alert("Нова тека", isPresented: $state.files.showingNewFolder) {
                TextField("Ім'я теки", text: $state.files.newFolderName)
                Button("Створити") { state.files.confirmNewFolder() }
                Button("Скасувати", role: .cancel) { state.files.newFolderName = "" }
            } message: {
                Text("Буде створено в «\(state.browser.currentPath)».")
            }
            .alert(
                "Не вдалося виконати дію",
                isPresented: Binding(
                    get: { state.files.actionError != nil },
                    set: { if !$0 { state.files.actionError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(state.files.actionError ?? "")
            }
    }
}
