defmodule Minga.Editor.Commands.Formatting do
  @moduledoc """
  Buffer formatting command.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Formatter

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @spec format_buffer(state()) :: state()
  def format_buffer(%{buffers: %{active: buf}} = state) when is_pid(buf) do
    filetype = BufferServer.filetype(buf)
    file_path = BufferServer.file_path(buf)
    spec = Formatter.resolve_formatter(filetype, file_path)

    case spec do
      nil ->
        %{state | status_msg: "No formatter configured for #{filetype}"}

      _ ->
        format_and_replace(state, buf, spec)
    end
  end

  def format_buffer(state), do: %{state | status_msg: "No buffer to format"}

  # ── Private helpers ───────────────────────────────────────────────────────

  @spec format_and_replace(state(), pid(), Formatter.formatter_spec()) :: state()
  defp format_and_replace(state, buf, spec) do
    content = BufferServer.content(buf)
    buf_name = BufferServer.file_path(buf) |> Path.basename()

    case Formatter.format(content, spec) do
      {:ok, formatted} ->
        {cursor_line, cursor_col} = BufferServer.cursor(buf)
        BufferServer.replace_content(buf, formatted)
        line_count = BufferServer.line_count(buf)
        safe_line = min(cursor_line, max(line_count - 1, 0))
        BufferServer.move_to(buf, {safe_line, cursor_col})
        Minga.Editor.log_to_messages("Formatted: #{buf_name}")
        %{state | status_msg: "Formatted"}

      {:error, msg} ->
        Minga.Log.warning(:editor, "Formatter failed: #{buf_name} (#{msg})")
        %{state | status_msg: "Format error: #{msg}"}
    end
  end

  @impl Minga.Command.Provider
  def __commands__ do
    [
      %Minga.Command{
        name: :format_buffer,
        description: "Format buffer",
        requires_buffer: true,
        execute: &format_buffer/1
      }
    ]
  end
end
