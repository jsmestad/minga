defmodule MingaGhostCursors.Commands do
  @moduledoc """
  Command implementations for the ghost cursors extension.
  """

  alias Minga.Buffer
  alias Minga.Extension.Overlay
  alias MingaEditor.Extension.EditorAPI

  @extension_name :minga_ghost_cursors

  @spec follow(MingaEditor.Extension.EditorAPI.state()) :: MingaEditor.Extension.EditorAPI.state()
  def follow(state) do
    case find_most_recent_agent_overlay() do
      {:ok, path, {line, col}} ->
        EditorAPI.navigate_to(state, path, line, col)

      :none ->
        EditorAPI.set_status(state, "No agent currently editing")
    end
  end

  @spec find_most_recent_agent_overlay() :: {:ok, String.t(), {non_neg_integer(), non_neg_integer()}} | :none
  defp find_most_recent_agent_overlay do
    overlays =
      Overlay.all()
      |> Enum.filter(fn overlay -> overlay.extension == @extension_name end)

    case overlays do
      [] ->
        :none

      entries ->
        overlay = List.last(entries)
        {buffer_pid, _session_pid} = overlay.overlay_id

        case safe_file_path(buffer_pid) do
          path when is_binary(path) -> {:ok, path, overlay.position}
          nil -> :none
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
