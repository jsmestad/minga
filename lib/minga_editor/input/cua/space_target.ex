defmodule MingaEditor.Input.CUA.SpaceTarget do
  @moduledoc """
  Where a CUA space-leader space goes, derived once from the focused surface when SPC arrives.

  Both space-leader paths record this value with the space and retract only from it: `CUA.TUISpaceLeader` types the space itself, and `CUA.SpaceLeader` handles the macOS fallback chord, where the frontend has already sent the space as an ordinary key. A file buffer hidden behind the focused surface is never a target.

  - `{:buffer, pid}`: the focused file window takes the space as text.
  - `{:composer, pid}`: the focused Agent composer takes the space into that prompt buffer (nil before the composer has one).
  - `:overlay`: a picker, prompt, search, completion or other overlay owns the key and its text.
  - `:no_text`: the focused surface takes no text (Agent chat navigation, a focused bottom panel, a focused sidebar such as the BEAM Observatory, the file tree, Git status, the empty state).
  """

  alias MingaEditor.BottomPanel
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FocusOwner
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState

  @type t :: {:buffer, pid()} | {:composer, pid() | nil} | :overlay | :no_text

  @typedoc "A recorded space: its target and the position it was typed at, or nil when no text buffer took it."
  @type held :: {t(), Minga.Buffer.position() | nil}

  # FocusOwner surfaces that own their keys below the overlays.
  @surfaces [:editor, :agent, :file_tree, :git_status, :empty_state, :queue, :tasks]

  @doc """
  Resolves where a space typed now would go.

  The clauses follow the claim order of `MingaEditor.Input` surface handlers, so a change to that order must change this function too.
  """
  @spec resolve(EditorState.t()) :: t()
  def resolve(%EditorState{workspace: workspace} = state) do
    surface = FocusOwner.derive(state).surface

    cond do
      surface not in @surfaces -> :overlay
      # Input.TasksDrawer (priority 15) takes keys ahead of every other surface and types no text.
      surface == :tasks -> :no_text
      surface == :queue -> :no_text
      side_panel_composer?(workspace) -> {:composer, workspace.agent_ui.panel.prompt_buffer}
      generic_sidebar_focused?(state) -> :no_text
      surface == :empty_state -> :no_text
      agent_composer?(workspace) -> {:composer, workspace.agent_ui.panel.prompt_buffer}
      bottom_panel_focused?(state) -> :no_text
      true -> file_target(workspace)
    end
  end

  # Input.AgentPanel (priority 40) claims keys for a focused side panel composer over any scope but the file tree.
  @spec side_panel_composer?(MingaEditor.Session.State.t()) :: boolean()
  defp side_panel_composer?(%{keymap_scope: scope, agent_ui: %{panel: panel}}),
    do: scope != :file_tree and panel.visible and panel.input_focused

  # Input.Sidebar (priority 45) claims every key for a focused left sidebar without its own input handler,
  # such as the BEAM Observatory, and hands it to the sidebar's action handler.
  @spec generic_sidebar_focused?(EditorState.t()) :: boolean()
  defp generic_sidebar_focused?(%EditorState{extension_surfaces: %{sidebar_registry: registry}}) do
    case Sidebar.active_left(registry) do
      %{focused?: true, input_handler: handler} -> handler in [nil, MingaEditor.Input.Sidebar]
      _no_focused_sidebar -> false
    end
  end

  # Input.Scoped (priority 100) claims keys for a focused composer in the Agent scope.
  @spec agent_composer?(MingaEditor.Session.State.t()) :: boolean()
  defp agent_composer?(%{keymap_scope: scope, agent_ui: %{panel: panel}}),
    do: scope == :agent and panel.input_focused

  # Input.BottomPanel (priority 125) swallows keys while the panel has focus.
  @spec bottom_panel_focused?(EditorState.t()) :: boolean()
  defp bottom_panel_focused?(state) do
    case Runtime.state(state.shell_runtime) do
      %TraditionalState{bottom_panel: panel} -> BottomPanel.focused?(panel)
      _extension_state -> false
    end
  end

  # The mode FSM types into the active buffer only when the file window has focus.
  @spec file_target(MingaEditor.Session.State.t()) :: t()
  defp file_target(%{keymap_scope: :editor, buffers: %{active: buf}}) when is_pid(buf),
    do: {:buffer, buf}

  defp file_target(_workspace), do: :no_text
end
