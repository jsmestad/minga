defmodule Minga.Editor.Title do
  @moduledoc """
  Formats the terminal window title from the active buffer state.

  The title format string supports these placeholders:

  | Placeholder     | Expands to                                    |
  |-----------------|-----------------------------------------------|
  | `{filename}`    | Buffer filename (e.g. `editor.ex`)            |
  | `{filepath}`    | Full file path (e.g. `/home/user/project/...`)|
  | `{directory}`   | Parent directory name (e.g. `minga`)          |
  | `{dirty}`       | `[+]` if modified, empty string otherwise     |
  | `{readonly}`    | `[-]` if read-only, empty string otherwise    |
  | `{mode}`        | Current editor mode (e.g. `NORMAL`)           |
  | `{bufname}`     | Buffer display name (filename or `*scratch*`) |
  """

  alias Minga.Buffer.Server, as: BufferServer

  @typedoc "Editor state (same as Minga.Editor.State.t())."
  @type state :: map()

  @doc """
  Formats the terminal title from the current editor state and format string.
  """
  @spec format(state(), String.t()) :: String.t()
  def format(state, format_str) when is_binary(format_str) do
    vars = build_vars(state)

    Enum.reduce(vars, format_str, fn {key, value}, acc ->
      String.replace(acc, "{#{key}}", value)
    end)
  end

  @spec build_vars(state()) :: [{String.t(), String.t()}]
  defp build_vars(%{buffers: %{active: buf}, mode: mode}) when is_pid(buf) do
    path = BufferServer.file_path(buf)
    dirty = BufferServer.dirty?(buf)
    name = BufferServer.buffer_name(buf)

    filename = if path, do: Path.basename(path), else: name || "*scratch*"
    directory = if path, do: path |> Path.dirname() |> Path.basename(), else: ""
    filepath = path || ""
    bufname = name || filename

    [
      {"filename", filename},
      {"filepath", filepath},
      {"directory", directory},
      {"dirty", if(dirty, do: "[+] ", else: "")},
      {"readonly", ""},
      {"mode", mode |> to_string() |> String.upcase()},
      {"bufname", bufname}
    ]
  end

  defp build_vars(_state) do
    [
      {"filename", "*scratch*"},
      {"filepath", ""},
      {"directory", ""},
      {"dirty", ""},
      {"readonly", ""},
      {"mode", "NORMAL"},
      {"bufname", "*scratch*"}
    ]
  end
end
