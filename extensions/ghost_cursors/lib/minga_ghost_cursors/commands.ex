defmodule MingaGhostCursors.Commands do
  @moduledoc """
  Command implementations for the ghost cursors extension.
  """

  alias Minga.Buffer
  alias MingaEditor.Extension.EditorAPI

  @spec follow(MingaEditor.Extension.EditorAPI.state()) :: MingaEditor.Extension.EditorAPI.state()
  def follow(state) do
    case MingaGhostCursors.Tracker.last_updated() do
      nil ->
        EditorAPI.set_status(state, "No agent currently editing")

      {{buffer_pid, _session_pid}, {line, col}} ->
        case safe_file_path(buffer_pid) do
          path when is_binary(path) ->
            EditorAPI.navigate_to(state, path, line, col)

          nil ->
            EditorAPI.set_status(state, "No agent currently editing")
        end
    end
  end

  @spec safe_file_path(pid()) :: String.t() | nil
  defp safe_file_path(buffer_pid) do
    Buffer.file_path(buffer_pid)
  catch
    :exit, _ -> nil
  end
end
