defmodule MingaEditor.RenderPipeline.FrameIntent do
  @moduledoc "Explicit allowlisted top-level Editor-to-Renderer frame boundary."

  alias MingaEditor.RenderPipeline.Input

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

  @doc "Copies only the reviewed top-level semantic fields from pipeline input."
  @spec from_input(Input.t()) :: t()
  def from_input(%Input{} = input) do
    %__MODULE__{
      port_manager: input.port_manager,
      theme: input.theme,
      capabilities: input.capabilities,
      shell_id: input.shell_id,
      shell: input.shell,
      shell_identity: input.shell_identity,
      shell_state: input.shell_state,
      message_store: input.message_store,
      notifications: input.notifications,
      sidebar_registry: input.sidebar_registry,
      face_override_registries: input.face_override_registries,
      editing_model: input.editing_model,
      backend: input.backend,
      layout: input.layout,
      focus_tree: input.focus_tree,
      diff_views: input.diff_views,
      git_syncing: input.git_syncing,
      status_bar_data: input.status_bar_data,
      highlighting: input.highlighting,
      semantic_tokens: input.semantic_tokens,
      terminal_viewport: input.terminal_viewport,
      last_input_seq: input.last_input_seq,
      force_keyframe?: input.force_keyframe?,
      line_spacing: input.line_spacing,
      cursor_animate: input.cursor_animate,
      gui_config_state: input.gui_config_state
    }
  end

  @doc "Forces recovery materialization without exposing renderer cache state."
  @spec force_keyframe(t()) :: t()
  def force_keyframe(%__MODULE__{} = frame), do: %{frame | force_keyframe?: true}
end
