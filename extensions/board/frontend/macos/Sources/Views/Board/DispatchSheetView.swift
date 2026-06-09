/// Dispatch sheet modal for creating new agent sessions.
///
/// Displays a centered modal with a multi-line task description field
/// and a vertical model picker. The user enters what the agent should
/// work on, selects a model, and dispatches with Cmd+Return.

import SwiftUI

struct DispatchSheetView: View {
    let state: DispatchSheetState
    let theme: ThemeColors
    let encoder: InputEncoder?

    private let sheetWidth: CGFloat = 480
    private let minTaskHeight: CGFloat = 120
    private let modelRowHeight: CGFloat = 44

    /// Transition animation duration. Respects reduced motion.
    private var animDuration: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
    }

    var body: some View {
        if state.visible {
            ZStack {
                // Dimmed background: click to dismiss
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .onTapGesture {
                        // Send Escape to dismiss
                        encoder?.sendKeyPress(codepoint: 27, modifiers: 0)
                    }

                VStack(spacing: 0) {
                    header
                    Divider().overlay(theme.popupBorder.opacity(0.3))
                    taskField
                    Divider().overlay(theme.popupBorder.opacity(0.3))
                    modelPicker
                    Divider().overlay(theme.popupBorder.opacity(0.3))
                    footer
                }
                .frame(width: sheetWidth)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.popupBg)
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(theme.popupBorder.opacity(0.4), lineWidth: 1)
                )
            }
            .transition(.opacity.animation(.easeInOut(duration: animDuration)))
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Image(systemName: "plus.circle")
                .font(.system(size: 14))
                .foregroundStyle(theme.accent)
            Text("Dispatch New Agent")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.popupFg)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Task Field

    @ViewBuilder
    private var taskField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Task")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.popupFg.opacity(0.6))

            TextEditor(text: Binding(
                get: { state.taskText },
                set: { state.taskText = $0 }
            ))
            .font(.system(size: 13))
            .foregroundStyle(theme.popupFg)
            .scrollContentBackground(.hidden)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.popupBg.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(theme.popupBorder.opacity(0.3), lineWidth: 1)
                    )
            )
            .frame(minHeight: minTaskHeight, maxHeight: 200)
            .overlay(alignment: .topLeading) {
                if state.taskText.isEmpty {
                    Text("What should this agent work on?")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.popupFg.opacity(0.3))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Model Picker

    @ViewBuilder
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.popupFg.opacity(0.6))

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 2) {
                    ForEach(Array(state.models.enumerated()), id: \.offset) { idx, model in
                        modelRow(idx: idx, name: model.name, hint: model.hint)
                    }
                }
            }
            .frame(maxHeight: CGFloat(min(state.models.count, 4)) * modelRowHeight)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func modelRow(idx: Int, name: String, hint: String) -> some View {
        let isSelected = idx == state.selectedModelIndex

        HStack(spacing: 10) {
            // Selection indicator
            Circle()
                .fill(isSelected ? theme.accent : Color.clear)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .strokeBorder(isSelected ? Color.clear : theme.popupFg.opacity(0.3), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? theme.accent : theme.popupFg)

                if !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.popupFg.opacity(0.5))
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? theme.accent.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            state.selectedModelIndex = idx
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()

            keyHint("⎋", label: "cancel")

            if !state.taskText.isEmpty {
                keyHint("⌘⏎", label: "dispatch")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func keyHint(_ key: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.popupFg.opacity(0.45))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.popupFg.opacity(0.08))
                )
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(theme.popupFg.opacity(0.3))
        }
    }
}
