defmodule MingaEditor.RenderPipeline.Intent do
  @moduledoc """
  Cache-free Editor-to-Renderer frame intent.

  Pipeline and workspace fields use explicit allowlisted boundary structs;
  windows use `WindowIntent`. No `Input`, editor `Window`, renderer cache,
  resident store, font registry, or acknowledgement state crosses the boundary.
  """

  alias MingaEditor.RenderPipeline.FrameIntent
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.WindowIntent
  alias MingaEditor.RenderPipeline.WorkspaceIntent
  alias MingaEditor.State, as: EditorState

  @enforce_keys [:frame, :workspace, :windows, :window_layout, :buffer_versions, :revision]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          frame: FrameIntent.t(),
          workspace: WorkspaceIntent.t(),
          windows: %{optional(MingaEditor.Window.id()) => WindowIntent.t()},
          window_layout: %{tree: term(), active: pos_integer(), next_id: pos_integer()},
          buffer_versions: %{optional(pid()) => non_neg_integer()},
          revision: non_neg_integer()
        }

  @spec from_editor_state(EditorState.t(), non_neg_integer()) :: t()
  def from_editor_state(%EditorState{} = state, revision \\ 0),
    do: state |> Input.from_editor_state() |> from_input(revision)

  @spec from_input(Input.t(), non_neg_integer()) :: t()
  def from_input(%Input{} = input, revision \\ 0) do
    windows = input.workspace.windows
    carriers = Map.new(windows.map, fn {id, window} -> {id, WindowIntent.from_window(window)} end)

    %__MODULE__{
      frame: FrameIntent.from_input(input),
      workspace: WorkspaceIntent.from_workspace(input.workspace),
      windows: carriers,
      window_layout: %{tree: windows.tree, active: windows.active, next_id: windows.next_id},
      buffer_versions: buffer_versions(carriers),
      revision: revision
    }
  end

  @doc "Marks semantic frame state for a recovery keyframe without adding cache state."
  @spec force_keyframe(t()) :: t()
  def force_keyframe(%__MODULE__{} = intent),
    do: %{intent | frame: FrameIntent.force_keyframe(intent.frame)}

  @spec buffer_versions(map()) :: map()
  defp buffer_versions(windows) do
    Enum.reduce(windows, %{}, fn
      {_id, %WindowIntent{buffer: buffer}}, acc when is_pid(buffer) ->
        Map.put_new_lazy(acc, buffer, fn -> safe_version(buffer) end)

      _, acc ->
        acc
    end)
  end

  defp safe_version(buffer) do
    Minga.Buffer.version(buffer)
  catch
    :exit, _ -> 0
  end
end
