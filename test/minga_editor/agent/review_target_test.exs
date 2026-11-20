defmodule MingaEditor.Agent.ReviewTargetTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.ReviewTarget
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Target
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  test "rendered Review actions survive navigation and frozen writes without choosing another file" do
    state = reviewing_state()
    offer = state |> Context.from_editor_state() |> ReviewTarget.capture()
    target = activation(offer, :back_to_chat)
    preview = state.workspace.agent_ui.view.preview

    for updated <- [
          state,
          update_preview(state, Preview.scroll_down(preview, 5)),
          update_preview(state, Preview.refresh_after_write(preview, "other.ex")),
          update_preview(state, Preview.refresh_after_write(preview, "selected.ex"))
        ] do
      assert {:ok, {:review, %ReviewTarget{path: "selected.ex"}}} =
               Target.resolve(updated, target)
    end

    assert {:error, :target_mismatch} = Target.resolve(state, activation(offer, :review_file))

    stale = update_preview(state, Preview.refresh_after_write(preview, "selected.ex"))

    assert {:ok, {:review, %ReviewTarget{path: "selected.ex", freshness: :stale}}} =
             Target.resolve(stale, activation(offer, :review_file))
  end

  test "old controls cannot act after presentation, session, pane or selected-source replacement" do
    state = reviewing_state()
    target = state |> ReviewTarget.capture() |> activation(:back_to_chat)
    ui = state.workspace.agent_ui
    runtime = state.shell_runtime
    tab_bar = Runtime.traditional_tab_bar(runtime)
    {other_tab_bar, group} = TabBar.add_workspace(tab_bar, "Other")
    other_tab_bar = TabBar.move_tab_to_workspace(other_tab_bar, 1, group.id)

    next_entry =
      Entry.with_generation(Runtime.entry(runtime), Runtime.entry(runtime).generation + 1)

    replacement = Window.new_agent_chat(1, 24, 80)
    windows = Windows.replace_window(state.workspace.windows, 1, replacement)

    source_replaced =
      update_preview(
        state,
        Preview.set_diff(ui.view.preview, DiffReview.new("selected.ex", "before", "after"))
      )

    chat = %{
      state
      | workspace: SessionState.set_agent_ui(state.workspace, UIState.set_focus(ui, :chat))
    }

    for replaced <- [
          chat,
          source_replaced,
          %{state | shell_runtime: Runtime.set_tab_session(runtime, 1, self())},
          %{state | shell_runtime: Runtime.new(next_entry, Runtime.state(runtime))},
          %{
            state
            | shell_runtime:
                Runtime.new(
                  Runtime.entry(runtime),
                  ShellState.install_tab_bar(Runtime.state(runtime), other_tab_bar)
                )
          },
          %{
            state
            | workspace: SessionState.set_agent_ui(%{state.workspace | windows: windows}, ui)
          }
        ] do
      assert {:error, :target_mismatch} = Target.resolve(replaced, target)
    end
  end

  defp activation(offer, intent) do
    %Target{
      surface: :review,
      intent: intent,
      generation: offer.generation,
      item_id: offer.item_id
    }
  end

  defp update_preview(state, preview) do
    ui = UIState.replace_preview(state.workspace.agent_ui, preview)
    %{state | workspace: SessionState.set_agent_ui(state.workspace, ui)}
  end

  defp reviewing_state do
    {tab_bar, group} =
      Tab.new_agent(1, "Agent") |> TabBar.new(__DIR__) |> TabBar.add_workspace("Agent")

    tab_bar = TabBar.move_tab_to_workspace(tab_bar, 1, group.id)
    window = Window.new_agent_chat(1, 24, 80)

    ui =
      UIState.new()
      |> UIState.replace_preview(
        Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "before", "after"))
      )
      |> UIState.set_focus(:file_viewer)

    workspace = %SessionState{
      keymap_scope: :agent,
      windows: %Windows{tree: WindowTree.new(1), map: %{1 => window}, active: 1, next_id: 2}
    }

    %EditorState{
      workspace: SessionState.set_agent_ui(workspace, ui),
      shell_runtime:
        Runtime.new(Runtime.default_entry(), ShellState.install_tab_bar(%ShellState{}, tab_bar))
    }
  end
end
