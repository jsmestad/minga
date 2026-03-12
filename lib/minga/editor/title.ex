defmodule Minga.Editor.Title do
  @moduledoc """
  Formats the terminal window title from the active window content.

  Uses `EditorState.active_content_context/1` to derive display metadata
  from the active window's content type. In agent mode the title shows
  "Agent" instead of `*scratch*`. In buffer mode it shows the filename.

  The title format string supports these placeholders:

  | Placeholder     | Expands to                                    |
  |-----------------|-----------------------------------------------|
  | `{filename}`    | Display name (e.g. `editor.ex` or `Agent`)    |
  | `{filepath}`    | Full file path (empty in agent mode)           |
  | `{directory}`   | Parent directory or project name               |
  | `{dirty}`       | `[+]` if modified, empty string otherwise     |
  | `{readonly}`    | `[-]` if read-only, empty string otherwise    |
  | `{mode}`        | Current editor mode (e.g. `NORMAL`)           |
  | `{bufname}`     | Same as `{filename}` (backward compat)        |
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState

  @typedoc "Editor state (same as Minga.Editor.State.t())."
  @type state :: EditorState.t() | map()

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
  defp build_vars(%EditorState{} = state) do
    ctx = EditorState.active_content_context(state)
    mode_str = state.mode |> to_string() |> String.upcase()

    case ctx.type do
      :agent ->
        [
          {"filename", ctx.display_name},
          {"filepath", ""},
          {"directory", ctx.directory},
          {"dirty", ""},
          {"readonly", ""},
          {"mode", mode_str},
          {"bufname", ctx.display_name}
        ]

      :buffer ->
        filepath = buffer_filepath(state)

        [
          {"filename", ctx.display_name},
          {"filepath", filepath},
          {"directory", ctx.directory},
          {"dirty", if(ctx.dirty, do: "[+] ", else: "")},
          {"readonly", ""},
          {"mode", mode_str},
          {"bufname", ctx.display_name}
        ]
    end
  end

  # Fallback for non-EditorState maps (e.g. tests passing plain maps)
  defp build_vars(%{mode: mode} = state) do
    buf = get_in(state, [:buffers, :active])

    if is_pid(buf) do
      build_vars_from_buffer(buf, mode)
    else
      default_vars(mode)
    end
  end

  defp build_vars(_state) do
    default_vars(:normal)
  end

  @spec build_vars_from_buffer(pid(), atom()) :: [{String.t(), String.t()}]
  defp build_vars_from_buffer(buf, mode) do
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

  @spec default_vars(atom()) :: [{String.t(), String.t()}]
  defp default_vars(mode) do
    [
      {"filename", "*scratch*"},
      {"filepath", ""},
      {"directory", ""},
      {"dirty", ""},
      {"readonly", ""},
      {"mode", mode |> to_string() |> String.upcase()},
      {"bufname", "*scratch*"}
    ]
  end

  @spec buffer_filepath(EditorState.t()) :: String.t()
  defp buffer_filepath(%{buffers: %{active: buf}}) when is_pid(buf) do
    BufferServer.file_path(buf) || ""
  end

  defp buffer_filepath(_), do: ""
end
