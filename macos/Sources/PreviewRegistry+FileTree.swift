import SwiftUI

@MainActor
extension PreviewRegistry {

    // MARK: - FileTreeView

    static func fileTreePreview() -> some View {
        let theme = PreviewFixtures.theme()

        return fileTreeBodyPreview()
            .frame(width: 280, height: 600)
            .background(theme.treeBg)
            .environment(theme)
    }

    static func fileTreeBodyPreview() -> some View {
        FileTreeView(
            fileTreeState: fileTreeState(),
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "FileTreeView")
        )
    }

    static func fileTreeState() -> FileTreeState {
        let state = FileTreeState()
        let raw = PreviewFixtures.fileTreeRawEntries()
        state.update(
            version: 1,
            selectedId: "lib/minga/editor.ex",
            focused: true,
            treeWidth: 30,
            rootPath: "/Users/dev/code/minga",
            rawEntries: raw,
            treeState: FileTreeVisibilityState.ready.rawValue
        )
        return state
    }

    // MARK: - FileTreeEmpty

    static func fileTreeEmptyPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = FileTreeState()
        state.update(
            version: 1,
            selectedId: "",
            focused: false,
            treeWidth: 30,
            rootPath: "/Users/dev/code/minga",
            rawEntries: [],
            treeState: FileTreeVisibilityState.empty.rawValue
        )

        return FileTreeView(
            fileTreeState: state,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "FileTreeEmpty")
        )
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
        .environment(theme)
    }

    // MARK: - FileTreeError

    static func fileTreeErrorPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = FileTreeState()
        state.update(
            version: 1,
            selectedId: "",
            focused: false,
            treeWidth: 30,
            rootPath: "/Users/dev/code/minga",
            rawEntries: [],
            treeState: FileTreeVisibilityState.error.rawValue,
            errorReason: "Permission denied: /Users/dev/code/minga/.git/objects"
        )

        return FileTreeView(
            fileTreeState: state,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "FileTreeError")
        )
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
        .environment(theme)
    }

    // MARK: - FileTreeDeep

    static func fileTreeDeepPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = FileTreeState()
        state.update(
            version: 1,
            selectedId: "lib/minga/editor/render_pipeline/stages/syntax_highlight_pass.ex",
            focused: true,
            treeWidth: 30,
            rootPath: "/Users/dev/code/minga",
            rawEntries: fileTreeDeepRawEntries(),
            treeState: FileTreeVisibilityState.ready.rawValue
        )

        return FileTreeView(
            fileTreeState: state,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "FileTreeDeep")
        )
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
        .environment(theme)
    }

    static func fileTreeDeepRawEntries() -> [Wire.FileTreeEntry] {
        [
            PreviewFixtures.wireFileEntry(id: "lib", name: "lib", path: "/Users/dev/code/minga/lib", relPath: "lib", isDir: true, isExpanded: true, depth: 0, icon: ""),
            PreviewFixtures.wireFileEntry(id: "lib/minga", name: "minga", path: "/Users/dev/code/minga/lib/minga", relPath: "lib/minga", isDir: true, isExpanded: true, depth: 1, icon: ""),
            PreviewFixtures.wireFileEntry(id: "lib/minga/editor", name: "editor", path: "/Users/dev/code/minga/lib/minga/editor", relPath: "lib/minga/editor", isDir: true, isExpanded: true, depth: 2, icon: ""),
            PreviewFixtures.wireFileEntry(id: "lib/minga/editor/render_pipeline", name: "render_pipeline", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline", relPath: "lib/minga/editor/render_pipeline", isDir: true, isExpanded: true, depth: 3, icon: ""),
            PreviewFixtures.wireFileEntry(id: "lib/minga/editor/render_pipeline/stages", name: "stages", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline/stages", relPath: "lib/minga/editor/render_pipeline/stages", isDir: true, isExpanded: true, depth: 4, icon: ""),
            PreviewFixtures.wireFileEntry(id: "lib/minga/editor/render_pipeline/stages/syntax_highlight_pass.ex", name: "syntax_highlight_pass.ex", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline/stages/syntax_highlight_pass.ex", relPath: "lib/minga/editor/render_pipeline/stages/syntax_highlight_pass.ex", isDir: false, depth: 5, icon: "", isActive: true, gitStatus: 1),
            PreviewFixtures.wireFileEntry(id: "lib/minga/editor/render_pipeline/stages/diagnostic_underline_pass.ex", name: "diagnostic_underline_pass.ex", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline/stages/diagnostic_underline_pass.ex", relPath: "lib/minga/editor/render_pipeline/stages/diagnostic_underline_pass.ex", isDir: false, depth: 5, icon: "", gitStatus: 1),
            PreviewFixtures.wireFileEntry(id: "lib/minga/editor/render_pipeline/stages/line_number_gutter_renderer.ex", name: "line_number_gutter_renderer.ex", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline/stages/line_number_gutter_renderer.ex", relPath: "lib/minga/editor/render_pipeline/stages/line_number_gutter_renderer.ex", isDir: false, depth: 5, icon: ""),
            PreviewFixtures.wireFileEntry(id: "lib/minga/editor/render_pipeline/stages/selection_overlay_compositor.ex", name: "selection_overlay_compositor.ex", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline/stages/selection_overlay_compositor.ex", relPath: "lib/minga/editor/render_pipeline/stages/selection_overlay_compositor.ex", isDir: false, depth: 5, icon: "", isDirty: true),
            PreviewFixtures.wireFileEntry(id: "lib/minga/editor/render_pipeline/pipeline_coordinator.ex", name: "pipeline_coordinator.ex", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline/pipeline_coordinator.ex", relPath: "lib/minga/editor/render_pipeline/pipeline_coordinator.ex", isDir: false, depth: 4, icon: ""),
            PreviewFixtures.wireFileEntry(id: "lib/minga/editor/render_pipeline/frame_scheduler.ex", name: "frame_scheduler.ex", path: "/Users/dev/code/minga/lib/minga/editor/render_pipeline/frame_scheduler.ex", relPath: "lib/minga/editor/render_pipeline/frame_scheduler.ex", isDir: false, depth: 4, icon: ""),
            PreviewFixtures.wireFileEntry(id: "lib/minga/editor/viewport_calculation_service.ex", name: "viewport_calculation_service.ex", path: "/Users/dev/code/minga/lib/minga/editor/viewport_calculation_service.ex", relPath: "lib/minga/editor/viewport_calculation_service.ex", isDir: false, depth: 3, icon: ""),
            PreviewFixtures.wireFileEntry(id: "lib/minga/buffer", name: "buffer", path: "/Users/dev/code/minga/lib/minga/buffer", relPath: "lib/minga/buffer", isDir: true, isExpanded: true, depth: 2, icon: ""),
            PreviewFixtures.wireFileEntry(id: "lib/minga/buffer/document.ex", name: "document.ex", path: "/Users/dev/code/minga/lib/minga/buffer/document.ex", relPath: "lib/minga/buffer/document.ex", isDir: false, depth: 3, icon: ""),
            PreviewFixtures.wireFileEntry(id: "lib/minga/buffer/process.ex", name: "process.ex", path: "/Users/dev/code/minga/lib/minga/buffer/process.ex", relPath: "lib/minga/buffer/process.ex", isDir: false, depth: 3, icon: "", gitStatus: 1),
            PreviewFixtures.wireFileEntry(id: "test", name: "test", path: "/Users/dev/code/minga/test", relPath: "test", isDir: true, isExpanded: false, depth: 0, icon: "", isLastChild: true),
        ]
    }

    // MARK: - FileTreeRename

    static func fileTreeRenamePreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = fileTreeRenameState()

        return FileTreeView(
            fileTreeState: state,
            encoder: nil,
            usesPreviewEagerLayout: PreviewSnapshotPolicy.shouldUseEagerLayout(for: "FileTreeRename")
        )
        .frame(width: 280, height: 600)
        .background(theme.treeBg)
        .environment(theme)
    }

    static func fileTreeRenameState() -> FileTreeState {
        let state = FileTreeState()
        var raw = PreviewFixtures.fileTreeRawEntries()

        // Replace the editor.ex entry (index 2) with an editing version
        raw[2] = PreviewFixtures.wireFileEntry(
            id: "lib/minga/editor.ex",
            name: "editor.ex",
            path: "/Users/dev/code/minga/lib/minga/editor.ex",
            relPath: "lib/minga/editor.ex",
            isDir: false,
            depth: 2,
            icon: "",
            isActive: true,
            gitStatus: 1,
            isEditing: true,
            editingType: 2,
            editingText: "new_name.ex"
        )

        state.update(
            version: 1,
            selectedId: "lib/minga/editor.ex",
            focused: true,
            treeWidth: 30,
            rootPath: "/Users/dev/code/minga",
            rawEntries: raw,
            treeState: FileTreeVisibilityState.ready.rawValue
        )
        return state
    }
}
