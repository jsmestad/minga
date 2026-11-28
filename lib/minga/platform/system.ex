defmodule Minga.Platform.System do
  @moduledoc """
  Production backend for OS-level desktop operations.

  - **macOS:** Uses AppleScriptObjC to call Foundation's native Trash API.
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

  @spec open_url(String.t()) :: :ok | {:error, String.t()}
  def open_url(url) do
    case :os.type() do
      {:unix, :darwin} -> launch_url("open", ["--", url])
      {:unix, _os} -> launch_url("xdg-open", [url])
      _os -> {:error, "Opening links is not supported on this platform"}
    end
  end

  @spec launch_url(String.t(), [String.t()]) :: :ok | {:error, String.t()}
  defp launch_url(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, status} -> {:error, "#{executable} exited with status #{status}"}
    end
  rescue
    ErlangError -> {:error, "#{executable} could not start"}
  end

  @spec trash_macos(String.t()) :: :ok | {:error, String.t()}
  defp trash_macos(path), do: Minga.Platform.MacOSTrash.trash(path)

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
