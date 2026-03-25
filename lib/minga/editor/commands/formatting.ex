defmodule Minga.Editor.Commands.Formatting do
  @moduledoc """
  Buffer formatting command.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Formatter
  alias Minga.Mode.ToolConfirmState
  alias Minga.Tool.Recipe.Registry, as: RecipeRegistry

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @spec format_buffer(state()) :: state()
  def format_buffer(%{workspace: %{buffers: %{active: buf}}} = state) when is_pid(buf) do
    filetype = BufferServer.filetype(buf)
    file_path = BufferServer.file_path(buf)
    spec = Formatter.resolve_formatter(filetype, file_path)

    case spec do
      nil ->
        EditorState.set_status(state, "No formatter configured for #{filetype}")

      _ ->
        command = spec |> String.split() |> List.first()

        if System.find_executable(command) do
          format_and_replace(state, buf, spec)
        else
          maybe_prompt_formatter_install(state, command)
        end
    end
  end

  def format_buffer(state), do: EditorState.set_status(state, "No buffer to format")

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
        EditorState.set_status(state, "Formatted")

      {:error, msg} ->
        Minga.Log.warning(:editor, "Formatter failed: #{buf_name} (#{msg})")
        EditorState.set_status(state, "Format error: #{msg}")
    end
  end

  # When the formatter binary is missing and a tool recipe exists for it,
  # queue a tool install prompt. Since this runs inside the Editor process,
  # we modify state directly instead of broadcasting an event.
  @spec maybe_prompt_formatter_install(state(), String.t()) :: state()
  defp maybe_prompt_formatter_install(state, command) do
    case RecipeRegistry.for_command(command) do
      nil ->
        EditorState.set_status(state, "Formatter not found: #{command}")

      recipe ->
        if EditorState.skip_tool_prompt?(state, recipe.name) do
          EditorState.set_status(state, "Formatter not found: #{command}")
        else
          queue_and_show_prompt(state, recipe.name)
        end
    end
  end

  @spec queue_and_show_prompt(state(), atom()) :: state()
  defp queue_and_show_prompt(%{workspace: %{vim: %{mode: :normal}}} = state, tool_name) do
    queue = state.shell_state.tool_prompt_queue ++ [tool_name]
    state = EditorState.update_shell_state(state, &%{&1 | tool_prompt_queue: queue})
    ms = %ToolConfirmState{pending: queue, declined: state.shell_state.tool_declined}
    EditorState.transition_mode(state, :tool_confirm, ms)
  end

  defp queue_and_show_prompt(state, tool_name) do
    EditorState.update_shell_state(
      state,
      &%{&1 | tool_prompt_queue: state.shell_state.tool_prompt_queue ++ [tool_name]}
    )
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
