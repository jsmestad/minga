defmodule MingaEditor.Title do
  @moduledoc """
  Formats the terminal window title from the active window content.

  Derives display metadata from the active window and process-backed buffer
  in this workflow boundary. In agent mode the title shows
  "Agent" instead of the buffer name. In buffer mode it shows the filename.

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

  alias Minga.Buffer
  alias MingaEditor.State, as: EditorState

  @typedoc "Editor state (same as MingaEditor.State.t())."
  @type state :: EditorState.t() | map()

  @typep buffer_title_metadata :: %{
           path: String.t() | nil,
           name: String.t() | nil,
           dirty: boolean()
         }

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

  @doc """
  Formats the window title for GUI mode.

  Uses a clean format: `filename.ext — ProjectName` or `● filename.ext — ProjectName`
  when dirty. Special buffers strip `*` markers. Agent view shows `Agent — ProjectName`.
  """
  @spec format_gui(state()) :: String.t()
  def format_gui(state) do
    ctx = build_content_context(state)
    project = ctx.directory

    case ctx.type do
      :agent ->
        if project != "", do: "Agent — #{project}", else: "Agent — Minga"

      :buffer ->
        # Strip * from special buffer names (e.g., "*Messages*" → "Messages")
        name = String.replace(ctx.display_name, "*", "")
        dirty_prefix = if ctx.dirty, do: "● ", else: ""

        if project != "" do
          "#{dirty_prefix}#{name} — #{project}"
        else
          "#{dirty_prefix}#{name} — Minga"
        end
    end
  end

  @spec build_content_context(state()) :: map()
  defp build_content_context(%EditorState{} = state) do
    case MingaEditor.Session.State.active_window_struct(state.workspace) do
      %MingaEditor.Window{content: {:agent_chat, _session}} ->
        %{
          type: :agent,
          display_name: "Agent",
          filepath: "",
          directory: project_directory(),
          dirty: false
        }

      _window ->
        buffer_content_context(state.workspace.buffers.active)
    end
  end

  defp build_content_context(%{workspace: %{buffers: %{active: buf}}} = _state)
       when is_pid(buf) do
    buffer_content_context(buf)
  end

  defp build_content_context(_state) do
    buffer_context_fallback()
  end

  @spec buffer_context_fallback() :: map()
  defp buffer_context_fallback do
    %{type: :buffer, display_name: "[no file]", filepath: "", directory: "", dirty: false}
  end

  @spec read_buffer_title_metadata(pid()) :: {:ok, buffer_title_metadata()} | :dead_buffer
  defp read_buffer_title_metadata(buf) do
    {:ok,
     %{path: Buffer.file_path(buf), name: Buffer.buffer_name(buf), dirty: Buffer.dirty?(buf)}}
  catch
    :exit, {:noproc, {GenServer, :call, [^buf, _request, _timeout]}} -> :dead_buffer
  end

  @spec buffer_content_context(pid() | nil) :: map()
  defp buffer_content_context(buffer) when is_pid(buffer) do
    case read_buffer_title_metadata(buffer) do
      {:ok, metadata} ->
        path = metadata.path

        %{
          type: :buffer,
          display_name: if(path, do: Path.basename(path), else: metadata.name || "[no file]"),
          filepath: path || "",
          directory: if(path, do: path |> Path.dirname() |> Path.basename(), else: ""),
          dirty: metadata.dirty
        }

      :dead_buffer ->
        buffer_context_fallback()
    end
  end

  defp buffer_content_context(_buffer) do
    buffer_context_fallback()
  end

  @spec project_directory() :: String.t()
  defp project_directory do
    case Minga.Project.root() do
      nil -> ""
      root -> Path.basename(root)
    end
  catch
    :exit, _reason -> ""
  end

  @spec build_vars(state()) :: [{String.t(), String.t()}]
  defp build_vars(%EditorState{} = state) do
    ctx = build_content_context(state)
    mode_str = state |> Minga.Editing.mode() |> to_string() |> String.upcase()

    case ctx.type do
      :agent ->
        [
          {"filename", ctx.display_name},
          {"filepath", ctx.filepath},
          {"directory", ctx.directory},
          {"dirty", ""},
          {"readonly", ""},
          {"mode", mode_str},
          {"bufname", ctx.display_name}
        ]

      :buffer ->
        filepath = ctx.filepath

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
  defp build_vars(%{workspace: %{editing: %{mode: mode}}} = state) do
    buf = state.workspace.buffers.active

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
    case read_buffer_title_metadata(buf) do
      {:ok, metadata} ->
        path = metadata.path
        filename = if path, do: Path.basename(path), else: metadata.name || "[no file]"
        directory = if path, do: path |> Path.dirname() |> Path.basename(), else: ""
        filepath = path || ""
        bufname = metadata.name || filename

        [
          {"filename", filename},
          {"filepath", filepath},
          {"directory", directory},
          {"dirty", if(metadata.dirty, do: "[+] ", else: "")},
          {"readonly", ""},
          {"mode", mode |> to_string() |> String.upcase()},
          {"bufname", bufname}
        ]

      :dead_buffer ->
        default_vars(mode)
    end
  end

  @spec default_vars(atom()) :: [{String.t(), String.t()}]
  defp default_vars(mode) do
    [
      {"filename", "[no file]"},
      {"filepath", ""},
      {"directory", ""},
      {"dirty", ""},
      {"readonly", ""},
      {"mode", mode |> to_string() |> String.upcase()},
      {"bufname", "[no file]"}
    ]
  end
end
