defmodule MingaEditor.Input.CUA.SpaceTarget do
  @moduledoc """
  Where a CUA space-leader space goes, derived once from the focused surface when SPC arrives.

  Both space-leader paths record this value with the space and retract only from it: `CUA.TUISpaceLeader` types the space itself, and `CUA.SpaceLeader` handles the macOS fallback chord, where the frontend has already sent the space as an ordinary key. A file buffer hidden behind the focused surface is never a target.

  - `{:buffer, pid}`: the focused file window takes the space as text.
  - `{:composer, pid}`: the focused Agent composer takes the space into that prompt buffer (nil before the composer has one).
  - `:overlay`: a picker, prompt, search, completion or other overlay owns the key and its text.
  - `:no_text`: the focused surface takes no text (Agent chat navigation, a focused bottom panel, the file tree, Git status, the empty state).
  """

  alias MingaEditor.BottomPanel
  alias MingaEditor.FocusOwner
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState

  @type t :: {:buffer, pid()} | {:composer, pid() | nil} | :overlay | :no_text

  # FocusOwner surfaces that own their keys below the overlays.
  @surfaces [:editor, :agent, :file_tree, :git_status, :empty_state]

  @doc "Resolves where a space typed now would go, in the order the input handlers claim it."
  @spec resolve(EditorState.t()) :: t()
  def resolve(%EditorState{} = state) do
    if FocusOwner.derive(state).surface in @surfaces,
      do: surface_target(state.workspace, bottom_panel_focused?(state)),
      else: :overlay
  end

  @spec bottom_panel_focused?(EditorState.t()) :: boolean()
  defp bottom_panel_focused?(state) do
    case Runtime.state(state.shell_runtime) do
      %TraditionalState{bottom_panel: panel} -> BottomPanel.focused?(panel)
      _extension_state -> false
    end
  end

  # A focused composer claims keys in the Agent scope, and in the side panel over
  # any scope but the file tree (Input.AgentPanel, Input.Scoped), before a focused
  # bottom panel (Input.BottomPanel) can.
  @spec surface_target(MingaEditor.Session.State.t(), boolean()) :: t()
  defp surface_target(
         %{keymap_scope: scope, agent_ui: %{panel: %{input_focused: true} = panel}},
         _bottom_panel_focused?
       )
       when scope == :agent or (scope != :file_tree and panel.visible),
       do: {:composer, panel.prompt_buffer}

  defp surface_target(%{keymap_scope: :editor, buffers: %{active: buf}}, false) when is_pid(buf),
    do: {:buffer, buf}

  defp surface_target(_workspace, _bottom_panel_focused?), do: :no_text
end
