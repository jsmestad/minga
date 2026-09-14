defmodule MingaEditor.PresentationTarget do
  @moduledoc "Semantic editor target carried by every native frame."

  alias Minga.Buffer
  alias MingaEditor.NativeIPC.OperationReceipt.Target
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Window

  @enforce_keys [:token, :window_id, :focus_required]
  defstruct [:token, :window_id, :focus_required]

  @type t :: %__MODULE__{
          token: non_neg_integer(),
          window_id: Window.id(),
          focus_required: boolean()
        }

  @doc "Derives the active file target represented by an editor state."
  @spec from_editor_state(EditorState.t()) :: t() | nil
  def from_editor_state(%EditorState{workspace: workspace}) do
    case SessionState.active_window_struct(workspace) do
      %Window{id: window_id, content: {:buffer, buffer}} -> from_buffer(buffer, window_id)
      _other -> nil
    end
  end

  @spec from_buffer(pid(), Window.id()) :: t() | nil
  defp from_buffer(buffer, window_id) do
    case Buffer.file_path(buffer) do
      path when is_binary(path) ->
        %__MODULE__{
          token: Target.token_for_path(Path.expand(path)),
          window_id: window_id,
          focus_required: true
        }

      nil ->
        nil
    end
  end
end
