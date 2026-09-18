import SwiftUI

/// 3.1: тулбар BrowserView — «Оновити», «Історія», «Нова тека», перемикач прихованих файлів
/// (3.5). Кнопка згортання sidebar — системна, NavigationSplitView додає її сама.
/// Винесено в окремий файл (не in-line в body), щоб BrowserView.swift лишався ≤400 рядків —
/// той самий тип, просто інший файл (як 2.8 розбило ADBClient/TransferEngine по файлах).
/// 3.6: кожна кнопка тут icon-only — `.accessibilityLabel` дублює `.help`, бо VoiceOver
/// покладатись на tooltip-текст не може.
extension BrowserView {
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button {
                Task { await state.browser.refreshList() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Оновити список")
            .accessibilityLabel("Оновити список")
        }
        ToolbarItem {
            Button {
                showingHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .help("Історія операцій")
            .accessibilityLabel("Історія операцій")
        }
        ToolbarItem {
            Button {
                state.files.newFolderName = ""
                state.files.showingNewFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("Нова тека на телефоні")
            .accessibilityLabel("Нова тека на телефоні")
        }
        ToolbarItem {
            Button {
                state.browser.showHidden.toggle()
            } label: {
                Image(systemName: state.browser.showHidden ? "eye" : "eye.slash")
            }
            .help(state.browser.showHidden ? "Сховати приховані файли" : "Показати приховані файли")
            .accessibilityLabel(state.browser.showHidden ? "Сховати приховані файли" : "Показати приховані файли")
        }
    }
}
