defmodule MingaEditor.Commands.UI do
  @moduledoc """
  General UI commands: command palette, file finder, theme picker,
  parser restart, and other picker-based commands that don't belong
  to a specific domain.
  """

  use MingaEditor.Commands.Provider

  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Frontend
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias Minga.Parser.Manager, as: ParserManager

  command(:command_palette, "Execute command",
    requires_buffer: false,
    execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.CommandSource) end
  )

  command(:find_file, "Find file in project",
    requires_buffer: false,
    execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.FileSource) end
  )

  command(:find_file_other_window, "Find file in other window",
    requires_buffer: false,
    execute: fn state ->
      state
      |> MingaEditor.Commands.Movement.execute(:split_vertical)
      |> PickerUI.open(MingaEditor.UI.Picker.FileSource)
    end
  )

  command(:theme_picker, "Pick theme",
    requires_buffer: false,
    execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.ThemeSource) end
  )

  command(:set_language, "Set buffer language",
    requires_buffer: false,
    execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.LanguageSource) end
  )

  command(:diagnostics_list, "List buffer diagnostics",
    requires_buffer: true,
    execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.Sources.Diagnostics) end
  )

  command(:filetype_menu, "Show filetype actions",
    requires_buffer: true,
    execute: fn state -> PickerUI.open(state, MingaEditor.UI.Picker.LanguageSource) end
  )

  command(:parser_restart, "Restart tree-sitter parser",
    requires_buffer: false,
    execute: &execute_parser_restart/1
  )

  command(:toggle_bottom_panel, "Toggle bottom panel",
    requires_buffer: false,
    execute: &toggle_bottom_panel/1
  )

  command(:bottom_panel_next_tab, "Bottom panel: next tab",
    requires_buffer: false,
    execute: &bottom_panel_next_tab/1
  )

  command(:bottom_panel_prev_tab, "Bottom panel: previous tab",
    requires_buffer: false,
    execute: &bottom_panel_prev_tab/1
  )

  command(:toggle_beam_observatory, "BEAM observatory",
    requires_buffer: false,
    execute: &toggle_beam_observatory/1
  )

  @spec toggle_bottom_panel(EditorState.t()) :: EditorState.t()
  defp toggle_bottom_panel(state) do
    then(state, fn root ->
      shell_state =
        MingaEditor.Shell.Traditional.State.set_bottom_panel(
          MingaEditor.Shell.Runtime.state(root.shell_runtime),
          MingaEditor.BottomPanel.toggle(state.shell_runtime.state.bottom_panel)
        )

      %{
        root
        | shell_runtime:
            MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
      }
    end)
  end

  @spec bottom_panel_next_tab(EditorState.t()) :: EditorState.t()
  defp bottom_panel_next_tab(state) do
    then(state, fn root ->
      shell_state =
        MingaEditor.Shell.Traditional.State.set_bottom_panel(
          MingaEditor.Shell.Runtime.state(root.shell_runtime),
          MingaEditor.BottomPanel.next_tab(state.shell_runtime.state.bottom_panel)
        )

      %{
        root
        | shell_runtime:
            MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
      }
    end)
  end

  @spec bottom_panel_prev_tab(EditorState.t()) :: EditorState.t()
  defp bottom_panel_prev_tab(state) do
    then(state, fn root ->
      shell_state =
        MingaEditor.Shell.Traditional.State.set_bottom_panel(
          MingaEditor.Shell.Runtime.state(root.shell_runtime),
          MingaEditor.BottomPanel.prev_tab(state.shell_runtime.state.bottom_panel)
        )

      %{
        root
        | shell_runtime:
            MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
      }
    end)
  end

  @spec toggle_beam_observatory(EditorState.t()) :: EditorState.t()
  defp toggle_beam_observatory(state) do
    if observatory_supported?(state) do
      if SidebarWorkflow.observatory_visible?(state),
        do: close_beam_observatory(state),
        else: open_beam_observatory(state)
    else
      state
    end
  end

  @spec open_beam_observatory(EditorState.t()) :: EditorState.t()
  defp open_beam_observatory(state) do
    if observatory_supported?(state) do
      subscribe_observatory()
      token = make_ref()
      timer = Process.send_after(self(), {:observatory_tick, token}, 0)

      state
      |> focus_observatory_sidebar()
      |> SidebarWorkflow.open_observatory({timer, token})
    else
      state
    end
  end

  @spec focus_observatory_sidebar(EditorState.t()) :: EditorState.t()
  defp focus_observatory_sidebar(%EditorState{} = state) do
    state
    |> then(fn state ->
      %{
        state
        | workspace:
            MingaEditor.Session.State.set_file_tree(
              state.workspace,
              (&FileTreeState.unfocus/1).(state.workspace.file_tree)
            )
      }
    end)
    |> then(fn state ->
      %{state | workspace: MingaEditor.Session.State.set_keymap_scope(state.workspace, :editor)}
    end)
  end

  @spec close_beam_observatory(EditorState.t()) :: EditorState.t()
  defp close_beam_observatory(state) do
    unsubscribe_observatory()
    SidebarWorkflow.close_observatory(state)
  end

  @spec subscribe_observatory() :: :ok
  defp subscribe_observatory do
    Minga.SystemObserver.subscribe()
  catch
    :exit, _ -> :ok
  end

  @spec unsubscribe_observatory() :: :ok
  defp unsubscribe_observatory do
    Minga.SystemObserver.unsubscribe()
  catch
    :exit, _ -> :ok
  end

  @spec observatory_supported?(EditorState.t()) :: boolean()
  defp observatory_supported?(state) do
    observatory_shell_supported?(state) and
      Frontend.semantic_ui?(state.frontend.capabilities)
  end

  @spec observatory_shell_supported?(EditorState.t()) :: boolean()
  defp observatory_shell_supported?(%{shell_runtime: %{state: %TraditionalState{}}}), do: true
  defp observatory_shell_supported?(%EditorState{}), do: false

  @spec execute_parser_restart(EditorState.t()) :: EditorState.t()
  defp execute_parser_restart(state) do
    case ParserManager.restart() do
      :ok ->
        state
        |> NoticeWorkflow.publish("Parser restarted")
        |> then(fn state ->
          %{state | parser: MingaEditor.State.Parser.report_status(state.parser, :available)}
        end)

      {:error, :binary_not_found} ->
        state
        |> NoticeWorkflow.publish("Parser restart failed: binary not found")
        |> then(fn state ->
          %{state | parser: MingaEditor.State.Parser.report_status(state.parser, :unavailable)}
        end)
    end
  catch
    :exit, _ ->
      NoticeWorkflow.publish(
        state,
        "Parser restart failed: manager not available"
      )
  end
end
