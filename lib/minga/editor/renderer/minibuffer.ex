defmodule Minga.Editor.Renderer.Minibuffer do
  @moduledoc """
  Minibuffer (bottom status line) rendering: search prompt, command input,
  status messages, and the empty-state fallback.

  Accepts a map with focused fields (mode, mode_state, theme, status_msg,
  diagnostic_hint) instead of the full EditorState. The pipeline's Chrome
  stage constructs this map.

  Returns `DisplayList.draw()` tuples.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Diagnostics
  alias Minga.Editor.DisplayList
  alias Minga.Editor.State, as: EditorState
  alias Minga.Face
  alias Minga.LSP.SyncServer

  @typedoc """
  Focused input for minibuffer rendering.

  The map should contain:
  - `:mode` — current editor mode
  - `:mode_state` — mode-specific state (search input, command input, etc.)
  - `:theme` — theme struct with `.minibuffer` colors
  - `:status_msg` — status message string or nil
  - `:diagnostic_hint` — pre-fetched diagnostic string or nil
  - `:buffers` — `%{active: pid | nil}` (only used for legacy path)
  """
  @type input :: map()

  @doc "Renders the minibuffer at `row` with a max width of `cols`."
  @spec render(input(), non_neg_integer(), pos_integer()) :: DisplayList.draw()
  def render(%EditorState{workspace: %{vim: %{mode: :search, mode_state: ms}}, theme: theme}, row, cols) do
    prefix = if ms.direction == :forward, do: "/", else: "?"
    search_text = prefix <> ms.input
    mb = theme.minibuffer

    DisplayList.draw(
      row,
      0,
      String.pad_trailing(search_text, cols),
      Face.new(fg: mb.fg, bg: mb.bg)
    )
  end

  def render(%EditorState{workspace: %{vim: %{mode: :search_prompt, mode_state: ms}}, theme: theme}, row, cols) do
    prompt_text = "Search: " <> ms.input
    mb = theme.minibuffer

    DisplayList.draw(
      row,
      0,
      String.pad_trailing(prompt_text, cols),
      Face.new(fg: mb.fg, bg: mb.bg)
    )
  end

  def render(%EditorState{workspace: %{vim: %{mode: :substitute_confirm, mode_state: ms}}, theme: theme}, row, cols) do
    current = ms.current + 1
    total = length(ms.matches)
    prompt = "replace with #{ms.replacement}? [y/n/a/q] (#{current} of #{total})"
    mb = theme.minibuffer

    DisplayList.draw(
      row,
      0,
      String.pad_trailing(prompt, cols),
      Face.new(fg: mb.fg, bg: mb.bg)
    )
  end

  def render(%EditorState{workspace: %{vim: %{mode: :extension_confirm, mode_state: ms}}, theme: theme}, row, cols) do
    prompt = Minga.Mode.display(:extension_confirm, ms)
    mb = theme.minibuffer

    DisplayList.draw(
      row,
      0,
      String.pad_trailing(prompt, cols),
      Face.new(fg: mb.fg, bg: mb.bg)
    )
  end

  def render(%EditorState{workspace: %{vim: %{mode: :tool_confirm, mode_state: ms}}, theme: theme}, row, cols) do
    prompt = Minga.Mode.display(:tool_confirm, ms)
    mb = theme.minibuffer

    DisplayList.draw(
      row,
      0,
      String.pad_trailing(prompt, cols),
      Face.new(fg: mb.fg, bg: mb.bg)
    )
  end

  def render(%EditorState{workspace: %{vim: %{mode: :command, mode_state: ms}}, theme: theme}, row, cols) do
    cmd_text = ":" <> ms.input
    mb = theme.minibuffer

    DisplayList.draw(
      row,
      0,
      String.pad_trailing(cmd_text, cols),
      Face.new(fg: mb.fg, bg: mb.bg)
    )
  end

  def render(%EditorState{workspace: %{vim: %{mode: :eval, mode_state: ms}}, theme: theme}, row, cols) do
    eval_text = "Eval: " <> ms.input
    mb = theme.minibuffer

    DisplayList.draw(
      row,
      0,
      String.pad_trailing(eval_text, cols),
      Face.new(fg: mb.fg, bg: mb.bg)
    )
  end

  def render(
        %{
          mode: :normal,
          mode_state: %{pending_describe_key: true, describe_key_keys: keys},
          theme: theme
        },
        row,
        cols
      ) do
    prompt =
      case keys do
        [] -> "Press key to describe:"
        _ -> "Press key to describe: " <> (keys |> Enum.reverse() |> Enum.join(" ")) <> " …"
      end

    mb = theme.minibuffer

    DisplayList.draw(
      row,
      0,
      String.pad_trailing(prompt, cols),
      Face.new(fg: mb.fg, bg: mb.bg)
    )
  end

  def render(%{status_msg: msg, theme: theme}, row, cols) when is_binary(msg) do
    mb = theme.minibuffer

    DisplayList.draw(
      row,
      0,
      String.pad_trailing(msg, cols),
      Face.new(fg: mb.warning_fg, bg: mb.bg)
    )
  end

  # Pre-fetched diagnostic hint (preferred: no GenServer calls during render)
  def render(%{diagnostic_hint: hint, theme: theme}, row, cols)
      when is_binary(hint) do
    mb = theme.minibuffer

    DisplayList.draw(
      row,
      0,
      String.pad_trailing(hint, cols),
      Face.new(fg: mb.dim_fg, bg: mb.bg)
    )
  end

  # Legacy path: fetches diagnostic from buffer (for backward compatibility)
  def render(%EditorState{workspace: %{buffers: %{active: buf}}, theme: theme} = state, row, cols)
      when is_pid(buf) and state.workspace.vim.mode in [:normal, :insert, :replace] do
    mb = theme.minibuffer

    case cursor_line_diagnostic(buf) do
      nil ->
        render_blank(row, cols, mb)

      msg ->
        DisplayList.draw(
          row,
          0,
          String.pad_trailing(msg, cols),
          Face.new(fg: mb.dim_fg, bg: mb.bg)
        )
    end
  end

  def render(%{theme: theme}, row, cols), do: render_blank(row, cols, theme.minibuffer)
  def render(_state, row, cols), do: render_blank_default(row, cols)

  @spec render_blank(non_neg_integer(), pos_integer(), map()) :: DisplayList.draw()
  defp render_blank(row, cols, mb) do
    DisplayList.draw(
      row,
      0,
      String.duplicate(" ", cols),
      Face.new(fg: mb.dim_fg, bg: mb.bg)
    )
  end

  @spec render_blank_default(non_neg_integer(), pos_integer()) :: DisplayList.draw()
  defp render_blank_default(row, cols) do
    DisplayList.draw(
      row,
      0,
      String.duplicate(" ", cols),
      Face.new(fg: 0x888888, bg: 0x000000)
    )
  end

  @spec cursor_line_diagnostic(pid()) :: String.t() | nil
  defp cursor_line_diagnostic(buf) do
    file_path = BufferServer.file_path(buf)

    case file_path do
      nil ->
        nil

      path ->
        uri = SyncServer.path_to_uri(path)
        {cursor_line, _col} = BufferServer.cursor(buf)
        first_on_line(uri, cursor_line)
    end
  end

  @spec first_on_line(String.t(), non_neg_integer()) :: String.t() | nil
  defp first_on_line(uri, line) do
    uri
    |> Diagnostics.for_uri()
    |> Enum.find(fn d -> d.range.start_line == line end)
    |> case do
      nil -> nil
      diag -> format_hint(diag)
    end
  end

  @spec format_hint(Diagnostics.Diagnostic.t()) :: String.t()
  defp format_hint(diag) do
    icon = severity_icon(diag.severity)
    source = if diag.source, do: " [#{diag.source}]", else: ""
    "#{icon} #{diag.message}#{source}"
  end

  @spec severity_icon(Diagnostics.Diagnostic.severity()) :: String.t()
  defp severity_icon(:error), do: "✖"
  defp severity_icon(:warning), do: "⚠"
  defp severity_icon(:info), do: "ℹ"
  defp severity_icon(:hint), do: "💡"
end
