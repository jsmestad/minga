defmodule Minga.Platform.System do
  @moduledoc """
  Production platform backend. Shells out to OS-specific commands for
  trash operations.

  - **macOS:** Uses `osascript` to ask Finder to trash the item. This moves
    the item to `~/.Trash` with Undo support in Finder.
  - **Linux:** Uses `gio trash` (GNOME/freedesktop) which follows the
    freedesktop Trash spec (`~/.local/share/Trash/`).
  """

  @spec trash(String.t()) :: :ok | {:error, String.t()}
  def trash(path) do
    case :os.type() do
      {:unix, :darwin} -> trash_macos(path)
      {:unix, _} -> trash_linux(path)
      {:win32, _} -> {:error, "Windows trash not supported"}
    end
  end

  @spec trash_macos(String.t()) :: :ok | {:error, String.t()}
  defp trash_macos(path) do
    # Escape single quotes in the path for AppleScript
    escaped = String.replace(path, "'", "'\\''")

    script =
      ~s|tell application "Finder" to delete (POSIX file "#{escaped}" as alias)|

    case System.cmd("osascript", ["-e", script], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, String.trim(output)}
    end
  end

  @spec trash_linux(String.t()) :: :ok | {:error, String.t()}
  defp trash_linux(path) do
    case System.cmd("gio", ["trash", path], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, _} ->
        # gio not available, try trash-cli as fallback
        case System.cmd("trash-put", [path], stderr_to_stdout: true) do
          {_, 0} -> :ok
          _ -> {:error, "gio trash failed: #{String.trim(output)}"}
        end
    end
  rescue
    e in ErlangError -> {:error, "trash command not found: #{inspect(e)}"}
  end
end
