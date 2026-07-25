defmodule MingaEditor.RenderPipeline.FrameIntent do
  @moduledoc "Explicit allowlisted top-level Editor-to-Renderer frame boundary."

  alias MingaEditor.EffectScheduler
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.StatusBar.Data, as: StatusBarData

  @fields [
    :port_manager,
    :theme,
    :capabilities,
    :shell_id,
    :shell,
    :shell_identity,
    :shell_state,
    :message_store,
    :notifications,
    :sidebar_registry,
    :face_override_registries,
    :editing_model,
    :backend,
    :layout,
    :focus_tree,
    :diff_views,
    :git_syncing,
    :status_bar_data,
    :highlighting,
    :semantic_tokens,
    :terminal_viewport,
    :last_input_seq,
    :force_keyframe?,
    :line_spacing,
    :cursor_animate,
    :gui_config_state
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          port_manager: GenServer.server() | nil,
          theme: term(),
          capabilities: term(),
          shell_id: atom(),
          shell: module(),
          shell_identity: term(),
          shell_state: term(),
          message_store: term(),
          notifications: term(),
          sidebar_registry: term(),
          face_override_registries: map(),
          editing_model: atom(),
          backend: atom(),
          layout: term(),
          focus_tree: term(),
          diff_views: map(),
          git_syncing: boolean(),
          status_bar_data: term(),
          highlighting: MingaEditor.State.Highlighting.t(),
          semantic_tokens: %{pid() => MingaEditor.State.LSP.semantic_layer()},
          terminal_viewport: term(),
          last_input_seq: non_neg_integer(),
          force_keyframe?: boolean(),
          line_spacing: number() | nil,
          cursor_animate: boolean() | nil,
          gui_config_state: term()
        }

  @spec from_editor_state(EditorState.t()) :: t()
  def from_editor_state(%EditorState{} = state) do
    %__MODULE__{
      port_manager: state.frontend.port_manager,
      theme: state.appearance.theme,
      capabilities: state.frontend.capabilities,
      shell_id: Runtime.id(state.shell_runtime),
      shell: Runtime.module(state.shell_runtime),
      shell_identity: Runtime.identity(state.shell_runtime),
      shell_state: Runtime.state(state.shell_runtime),
      message_store: state.render.message_store,
      notifications: state.feedback.notifications,
      sidebar_registry: state.extension_surfaces.sidebar_registry,
      face_override_registries: state.parser.face_override_registries,
      editing_model: state.interaction.editing_model,
      backend: state.frontend.backend,
      layout: state.render.layout,
      focus_tree: state.render.focus_tree,
      diff_views: state.git.diff_views,
      git_syncing: EffectScheduler.active_activity?(state.effect_scheduler, :git_syncing),
      status_bar_data: safe_status_bar_data(state),
      highlighting: state.parser.highlighting,
      semantic_tokens: state.lsp.semantic_tokens,
      terminal_viewport: state.frontend.terminal_viewport,
      last_input_seq: state.frontend.last_input_seq,
      force_keyframe?: false,
      line_spacing:
        Minga.Config.Options.get(state.interaction.options_server, :line_spacing) || 1.0,
      cursor_animate: Minga.Config.Options.get(state.interaction.options_server, :cursor_animate),
      gui_config_state: state.appearance.gui_config_state
    }
  end

  @spec force_keyframe(t()) :: t()
  def force_keyframe(%__MODULE__{} = frame), do: %{frame | force_keyframe?: true}

  @spec safe_status_bar_data(EditorState.t()) :: StatusBarData.t() | nil
  defp safe_status_bar_data(%EditorState{} = state) do
    StatusBarData.from_state(state)
  catch
    :exit, _ -> nil
  end
end
