import MingaUI
import SwiftUI

@MainActor
extension PreviewRegistry {

    // MARK: - GitStatusView

    static func gitStatusPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = gitStatusState()
        state.commitMessage = "feat(macos): polish preview snapshots"

        return GitStatusView(
            state: state,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "GitStatusView")
        )
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
        .environment(theme)
    }

    static func gitStatusState() -> GitStatusState {
        let state = GitStatusState()
        state.update(
            repoState: .normal,
            branchName: "feat/preview-host",
            ahead: 2,
            behind: 0,
            syncing: false,
            entries: PreviewFixtures.gitStatusEntries(),
            toast: nil,
            entryBasePath: "/Users/dev/code/minga",
            lastCommitMessage: "feat(editor): add preview host target",
            stashCount: 1
        )
        return state
    }

    // MARK: - GitStatusClean

    static func gitStatusCleanPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = GitStatusState()
        state.update(
            repoState: .normal,
            branchName: "main",
            ahead: 0,
            behind: 0,
            syncing: false,
            entries: [],
            toast: nil,
            entryBasePath: "/Users/dev/code/minga",
            lastCommitMessage: "chore: bump dependency versions",
            stashCount: 0
        )

        return GitStatusView(
            state: state,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "GitStatusClean")
        )
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
        .environment(theme)
    }

    // MARK: - GitStatusConflict

    static func gitStatusConflictPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = GitStatusState()
        state.update(
            repoState: .normal,
            branchName: "feat/agent-refactor",
            ahead: 3,
            behind: 5,
            syncing: false,
            entries: gitStatusConflictEntries(),
            toast: nil,
            entryBasePath: "/Users/dev/code/minga",
            lastCommitMessage: "feat(agent): restructure session manager",
            stashCount: 0
        )
        state.commitMessage = ""

        return GitStatusView(
            state: state,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "GitStatusConflict")
        )
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
        .environment(theme)
    }

    static func gitStatusConflictEntries() -> [GitStatusEntry] {
        [
            GitStatusEntry(pathHash: 1, section: .conflicted, status: .conflicted, path: "lib/minga/editor.ex"),
            GitStatusEntry(pathHash: 2, section: .conflicted, status: .conflicted, path: "lib/minga/buffer/document.ex"),
            GitStatusEntry(pathHash: 3, section: .conflicted, status: .conflicted, path: "lib/minga/agent/session_manager.ex"),
            GitStatusEntry(pathHash: 4, section: .staged, status: .modified, path: "mix.exs"),
            GitStatusEntry(pathHash: 5, section: .staged, status: .modified, path: "mix.lock"),
            GitStatusEntry(pathHash: 6, section: .changed, status: .modified, path: "lib/minga/buffer/process.ex"),
            GitStatusEntry(pathHash: 7, section: .changed, status: .modified, path: "test/minga/editor_test.exs"),
        ]
    }

    // MARK: - GitStatusDense

    static func gitStatusDensePreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = GitStatusState()
        state.update(
            repoState: .normal,
            branchName: "feat/full-stack-overhaul",
            ahead: 12,
            behind: 0,
            syncing: false,
            entries: gitStatusDenseEntries(),
            toast: nil,
            entryBasePath: "/Users/dev/code/minga",
            lastCommitMessage: "wip: large refactor across multiple subsystems",
            stashCount: 3
        )
        state.commitMessage = "feat(editor): comprehensive render pipeline overhaul"

        return GitStatusView(
            state: state,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "GitStatusDense")
        )
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
        .environment(theme)
    }

    static func gitStatusDenseEntries() -> [GitStatusEntry] {
        [
            GitStatusEntry(pathHash: 1, section: .staged, status: .modified, path: "lib/minga/editor/render_pipeline/stages/syntax_highlight_pass.ex"),
            GitStatusEntry(pathHash: 2, section: .staged, status: .modified, path: "lib/minga/editor/render_pipeline/stages/diagnostic_underline_pass.ex"),
            GitStatusEntry(pathHash: 3, section: .staged, status: .added, path: "lib/minga/editor/render_pipeline/stages/selection_overlay_compositor.ex"),
            GitStatusEntry(pathHash: 4, section: .staged, status: .added, path: "lib/minga/editor/render_pipeline/pipeline_coordinator.ex"),
            GitStatusEntry(pathHash: 5, section: .staged, status: .deleted, path: "lib/minga/editor/old_render_pipeline.ex"),
            GitStatusEntry(pathHash: 6, section: .staged, status: .renamed, path: "lib/minga/editor/viewport_calculation_service.ex"),
            GitStatusEntry(pathHash: 7, section: .changed, status: .modified, path: "lib/minga/buffer/document.ex"),
            GitStatusEntry(pathHash: 8, section: .changed, status: .modified, path: "lib/minga/buffer/process.ex"),
            GitStatusEntry(pathHash: 9, section: .changed, status: .modified, path: "lib/minga/agent/session_manager.ex"),
            GitStatusEntry(pathHash: 10, section: .changed, status: .modified, path: "macos/Sources/Views/PreviewRegistry.swift"),
            GitStatusEntry(pathHash: 11, section: .changed, status: .modified, path: "macos/Sources/Views/PreviewSnapshotPolicy.swift"),
            GitStatusEntry(pathHash: 12, section: .changed, status: .modified, path: "test/minga/editor/render_pipeline_test.exs"),
            GitStatusEntry(pathHash: 13, section: .changed, status: .modified, path: "test/minga/buffer/document_test.exs"),
            GitStatusEntry(pathHash: 14, section: .untracked, status: .untracked, path: "lib/minga/editor/render_pipeline/frame_scheduler.ex"),
            GitStatusEntry(pathHash: 15, section: .untracked, status: .untracked, path: "lib/minga/editor/render_pipeline/stages/line_number_gutter_renderer.ex"),
            GitStatusEntry(pathHash: 16, section: .untracked, status: .untracked, path: "docs/architecture/render_pipeline_design.md"),
            GitStatusEntry(pathHash: 17, section: .untracked, status: .untracked, path: "test/minga/editor/render_pipeline/stages/syntax_highlight_pass_test.exs"),
            GitStatusEntry(pathHash: 18, section: .untracked, status: .untracked, path: "zig/tests/fixtures/render_pipeline_integration_snapshot.bin"),
        ]
    }
}
