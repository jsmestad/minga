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
    case find_active_agent_overlay() do
      {:ok, path, {line, col}} ->
        EditorAPI.navigate_to(state, path, line, col)

      :none ->
        EditorAPI.set_status(state, "No agent currently editing")
    end
  end

  @spec find_active_agent_overlay() :: {:ok, String.t(), {non_neg_integer(), non_neg_integer()}} | :none
  defp find_active_agent_overlay do
    case MingaGhostCursors.Tracker.last_updated() do
      nil ->
        :none

      {buffer_pid, _session_pid} = overlay_key ->
        case find_overlay(overlay_key) do
          nil -> :none
          overlay -> resolve_path(buffer_pid, overlay)
        end
    end
  end

  @spec find_overlay(MingaGhostCursors.Tracker.overlay_key()) :: Minga.Extension.Overlay.entry() | nil
  defp find_overlay(overlay_key) do
    Overlay.all()
    |> Enum.find(fn overlay ->
      overlay.extension == @extension_name and overlay.overlay_id == overlay_key
    end)
  end

  @spec resolve_path(pid(), Minga.Extension.Overlay.entry()) :: {:ok, String.t(), {non_neg_integer(), non_neg_integer()}} | :none
  defp resolve_path(buffer_pid, overlay) do
    case safe_file_path(buffer_pid) do
      path when is_binary(path) -> {:ok, path, overlay.position}
      nil -> :none
    end
  end

  @spec safe_file_path(pid()) :: String.t() | nil
  defp safe_file_path(buffer_pid) do
    Buffer.file_path(buffer_pid)
  catch
    :exit, _ -> nil
  end
end
