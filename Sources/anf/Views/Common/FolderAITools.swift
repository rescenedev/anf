import AppKit

/// On-device AI actions shared by the right-click menus and the menu bar, so
/// they're reachable even when a packed list view leaves no empty space to
/// right-click.
@MainActor
enum FolderAITools {

    /// Summarize one file in a floating panel.
    static func summarizeFile(_ url: URL, name: String) {
        guard ensureLLM() else { return }
        SummaryPanel.show(title: name, key: url.path) { await SummaryService.summarize(url: url) }
    }

    /// Summarize a whole folder in a floating panel.
    static func summarizeFolder(_ url: URL, name: String) {
        guard ensureLLM() else { return }
        SummaryPanel.show(title: name, key: "folder:" + url.path) {
            await SummaryService.summarizeFolder(url: url)
        }
    }

    /// Open a Q&A panel for a file or a folder.
    static func ask(url: URL, name: String, isFolder: Bool) {
        guard ensureLLM() else { return }
        AskPanel.show(title: name, key: (isFolder ? "askfolder:" : "ask:") + url.path,
                      url: url, isFolder: isFolder)
    }

    /// AI-suggest names for specific files, reviewed in a panel.
    static func suggestNames(_ urls: [URL], title: String, model: BrowserModel) {
        guard ensureLLM() else { return }
        RenamePanel.show(title: L("Suggest Name — \(title)", "AI 이름 제안 — \(title)"),
                         urls: urls) { model.reload() }
    }

    /// Tidy screenshots = move loose captures into Screenshots/<month>. Scans &
    /// moves off the main thread, confirms the plan first. No LLM needed.
    static func tidyScreenshots(folder: URL, model: BrowserModel) {
        Task {
            let plan = await Task.detached(priority: .userInitiated) {
                ScreenshotOrganizer.plan(in: folder)
            }.value
            guard plan.total > 0 else {
                alert(L("No screenshots found", "스크린샷을 찾지 못했어요"),
                      L("Nothing here looks like a screenshot.",
                        "이 폴더에는 스크린샷으로 보이는 파일이 없어요."))
                return
            }
            let breakdown = plan.groups.prefix(8)
                .map { "  \($0.month) · \($0.urls.count)" }
                .joined(separator: "\n")
            let more = plan.groups.count > 8 ? "\n  …" : ""

            let a = NSAlert()
            a.messageText = L("Tidy \(plan.total) screenshots", "스크린샷 \(plan.total)장 정리")
            a.informativeText = L(
                "Move into \(plan.destName)/<month>:\n\(breakdown)\(more)",
                "\(plan.destName)/<월> 폴더로 이동합니다:\n\(breakdown)\(more)")
            a.addButton(withTitle: L("Move", "이동"))
            a.addButton(withTitle: L("Cancel", "취소"))
            guard a.runModal() == .alertFirstButtonReturn else { return }

            let result = await Task.detached(priority: .userInitiated) {
                ScreenshotOrganizer.move(plan, into: folder)
            }.value
            model.reload()
            if result.failed > 0 {
                alert(L("Moved \(result.moved), \(result.failed) failed",
                        "\(result.moved)장 이동, \(result.failed)장 실패"), "")
            }
        }
    }

    /// AI auto-tag: suggest topic tags for specific files, reviewed in a panel.
    static func autoTag(_ urls: [URL], title: String, model: BrowserModel) {
        guard ensureLLM() else { return }
        TagPanel.show(title: L("Auto-Tag — \(title)", "자동 태그 — \(title)"), urls: urls) { model.reload() }
    }

    /// AI auto-tag every taggable file in a folder.
    static func autoTagFolder(folder: URL, model: BrowserModel) {
        guard ensureLLM() else { return }
        Task {
            let urls = await Task.detached(priority: .userInitiated) {
                ContentOrganizer.candidates(in: folder)   // readable docs + images
            }.value
            guard !urls.isEmpty else {
                alert(L("Nothing to tag", "태그할 파일이 없어요"),
                      L("No readable files to tag here.", "이 폴더에는 태그할 수 있는 파일이 없어요."))
                return
            }
            let capped = urls.count > ContentOrganizer.maxFiles
            let use = capped ? Array(urls.prefix(ContentOrganizer.maxFiles)) : urls
            if capped {
                alert(L("Large folder", "파일이 많아요"),
                      L("Tagging the first \(use.count) of \(urls.count) files.",
                        "\(urls.count)개 중 처음 \(use.count)개만 태그합니다."))
            }
            TagPanel.show(title: L("Auto-Tag — \(folder.lastPathComponent)",
                                   "자동 태그 — \(folder.lastPathComponent)"),
                          urls: use) { model.reload() }
        }
    }

    /// Organize a folder by file KIND (Images/Documents/Archives/…). Instant,
    /// no LLM. Confirms the plan first.
    static func organizeByKind(folder: URL, model: BrowserModel) {
        Task {
            let plan = await Task.detached(priority: .userInitiated) {
                FolderOrganizer.plan(in: folder, korean: L10n.isKorean)
            }.value
            guard plan.total > 0 else {
                alert(L("Nothing to organize", "정리할 파일이 없어요"),
                      L("No loose files to sort by kind here.",
                        "이 폴더에는 종류별로 정리할 파일이 없어요."))
                return
            }
            let breakdown = plan.groups.prefix(10)
                .map { "  \($0.folder) · \($0.urls.count)" }
                .joined(separator: "\n")
            let a = NSAlert()
            a.messageText = L("Organize \(plan.total) files by kind", "파일 \(plan.total)개를 종류별로 정리")
            a.informativeText = L("Move into subfolders:\n\(breakdown)",
                                  "다음 하위 폴더로 이동합니다:\n\(breakdown)")
            a.addButton(withTitle: L("Move", "이동"))
            a.addButton(withTitle: L("Cancel", "취소"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
            let result = await Task.detached(priority: .userInitiated) {
                FolderOrganizer.move(plan, into: folder)
            }.value
            model.reload()
            if result.failed > 0 {
                alert(L("Moved \(result.moved), \(result.failed) failed",
                        "\(result.moved)개 이동, \(result.failed)개 실패"), "")
            }
        }
    }

    /// Organize a folder by CONTENT/topic using the on-device LLM ("내용별").
    /// Opens a progress panel that classifies each file, then moves on confirm.
    static func organizeByContent(folder: URL, model: BrowserModel) {
        guard ensureLLM() else { return }
        Task {
            let all = await Task.detached(priority: .userInitiated) {
                ContentOrganizer.candidates(in: folder)
            }.value
            guard !all.isEmpty else {
                alert(L("Nothing to organize", "정리할 파일이 없어요"),
                      L("No readable files to sort by content here.",
                        "이 폴더에는 내용으로 분류할 파일이 없어요."))
                return
            }
            let capped = all.count > ContentOrganizer.maxFiles
            let urls = capped ? Array(all.prefix(ContentOrganizer.maxFiles)) : all
            if capped {
                alert(L("Large folder", "파일이 많아요"),
                      L("Classifying the first \(urls.count) of \(all.count) files.",
                        "\(all.count)개 중 처음 \(urls.count)개만 분류합니다."))
            }
            OrganizePanel.show(
                title: L("Organize by Content — \(folder.lastPathComponent)",
                         "내용별 정리 — \(folder.lastPathComponent)"),
                folder: folder, urls: urls) { model.reload() }
        }
    }

    /// True if the on-device LLM is ready; otherwise show its hint.
    private static func ensureLLM() -> Bool {
        if LocalLLM.isAvailable { return true }
        alert(L("On-device AI unavailable", "온디바이스 AI를 쓸 수 없어요"),
              LocalLLM.unavailableHint(LocalLLM.status))
        return false
    }

    private static func alert(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        if !info.isEmpty { a.informativeText = info }
        a.runModal()
    }
}
