defmodule Minga.Platform do
  @moduledoc """
  OS-level platform operations.

  Delegates to a backend module configured via `:platform_module` in app config.
  Defaults to `Minga.Platform.System` in production, swapped to
  `Minga.Platform.Stub` in tests to avoid OS process spawning during async execution.
  """

  @type trash_result :: :ok | {:error, String.t()}

  @doc """
  Moves the given path to the system trash.

  On macOS, uses AppleScript to ask Finder to trash the item (supports Undo).
  On Linux, uses `gio trash` (freedesktop Trash spec).

  Returns `:ok` on success, or `{:error, reason}` if the trash operation failed
  (e.g., network volume with no trash support).
  """
  @spec trash(String.t()) :: trash_result()
  def trash(path), do: impl().trash(path)

  @doc """
  Permanently deletes the given path from disk.

  For files, uses `File.rm/1`. For directories, uses `File.rm_rf/1`.
  This is the fallback when trash is unavailable.
  """
  @spec permanent_delete(String.t()) :: :ok | {:error, String.t()}
  def permanent_delete(path) do
    if File.dir?(path) do
      case File.rm_rf(path) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, "#{inspect(reason)}"}
      end
    else
      case File.rm(path) do
        :ok -> :ok
        {:error, reason} -> {:error, "#{inspect(reason)}"}
      end
    end
  end

  @spec impl() :: module()
  defp impl, do: Application.get_env(:minga, :platform_module, Minga.Platform.System)
end
