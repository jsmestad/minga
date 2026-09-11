defmodule Minga.Platform.MacOSTrash do
  @moduledoc false

  @type command_runner ::
          (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @trash_script """
  use framework "Foundation"

  on run argv
    set fileURL to current application's NSURL's fileURLWithPath:(item 1 of argv)
    set {didTrash, trashedURL, trashError} to current application's NSFileManager's defaultManager()'s trashItemAtURL:fileURL resultingItemURL:(reference) |error|:(reference)

    if didTrash as boolean then
      return trashedURL's |path|() as text
    else
      error (trashError's localizedDescription() as text)
    end if
  end run
  """

  @spec trash(String.t()) :: :ok | {:error, String.t()}
  def trash(path) when is_binary(path), do: trash(path, &System.cmd/3)

  @doc false
  @spec trash(String.t(), command_runner()) :: :ok | {:error, String.t()}
  def trash(path, command_runner) when is_binary(path) and is_function(command_runner, 3) do
    case command_runner.("osascript", ["-e", @trash_script, "--", path], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, String.trim(output)}
    end
  rescue
    error in ErlangError -> {:error, "osascript failed: #{Exception.message(error)}"}
  end
end
