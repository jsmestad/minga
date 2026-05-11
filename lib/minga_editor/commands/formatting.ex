defmodule MingaEditor.Commands.Formatting do
  @moduledoc """
  Buffer formatting command.

  Supports formatting via LSP (if available) or external formatters.
  Attempts LSP formatting first if the language server is ready and supports formatting.
  Falls back to configured external formatters if LSP is unavailable.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias MingaEditor.State, as: EditorState
  alias Minga.Mode.ToolConfirmState
  alias Minga.Tool.Recipe.Registry, as: RecipeRegistry
  alias Minga.LSP.Client
  alias Minga.LSP.SyncServer

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @spec format_buffer(state()) :: state()
  def format_buffer(%{workspace: %{buffers: %{active: buf}}} = state) when is_pid(buf) do
    case try_lsp_format(state, buf) do
      {:ok, state} ->
        state

      :not_available ->
        try_external_format(state, buf)
    end
  end

  def format_buffer(state), do: EditorState.set_status(state, "No buffer to format")

  # ── LSP Formatting ────────────────────────────────────────────────────────

  @spec try_lsp_format(state(), pid()) :: {:ok, state()} | :not_available
  defp try_lsp_format(state, buf) when is_pid(buf) do
    clients = SyncServer.clients_for_buffer(buf)

    case Enum.find(clients, &supports_formatting?/1) do
      nil ->
        :not_available

      client ->
        {:ok, request_lsp_format(state, buf, client)}
    end
  end

  @spec supports_formatting?(pid()) :: boolean()
  defp supports_formatting?(client) do
    caps = Client.capabilities(client)

    get_in(caps, ["documentFormattingProvider"]) == true or
      get_in(caps, ["textDocument", "formatting", "provider"]) == true
  end

  @spec request_lsp_format(state(), pid(), pid()) :: state()
  defp request_lsp_format(state, buf, client) do
    file_path = Buffer.file_path(buf)
    uri = SyncServer.path_to_uri(file_path)

    ref = Client.request_formatting(client, uri)

    receive do
      {:lsp_response, ^ref, {:ok, edits}} ->
        apply_lsp_edits(buf, edits)
        EditorState.set_status(state, "Formatted (LSP)")

      {:lsp_response, ^ref, {:error, reason}} ->
        Minga.Log.warning(:editor, "LSP formatting error: #{inspect(reason)}")
        EditorState.set_status(state, "Format error: LSP request failed")
    after
      5000 ->
        EditorState.set_status(state, "Format error: LSP request timeout")
    end
  end

  @spec apply_lsp_edits(pid(), [map()]) :: :ok
  defp apply_lsp_edits(buf, edits) when is_pid(buf) and is_list(edits) do
    if edits != [] do
      {cursor_line, cursor_col} = Buffer.cursor(buf)
      content = Buffer.content(buf)

      new_content =
        Enum.reduce(Enum.reverse(edits), content, fn edit, acc ->
          range = Map.get(edit, "range", %{})
          new_text = Map.get(edit, "newText", "")
          start_line = get_in(range, ["start", "line"]) || 0
          start_col = get_in(range, ["start", "character"]) || 0
          end_line = get_in(range, ["end", "line"]) || 0
          end_col = get_in(range, ["end", "character"]) || 0

          apply_single_edit(acc, start_line, start_col, end_line, end_col, new_text)
        end)

      Buffer.replace_content(buf, new_content)
      line_count = Buffer.line_count(buf)
      safe_line = min(cursor_line, max(line_count - 1, 0))
      Buffer.move_to(buf, {safe_line, cursor_col})
      MingaEditor.log_to_messages("Formatted (LSP)")
    end

    :ok
  end

  @spec apply_single_edit(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) :: String.t()
  defp apply_single_edit(content, start_line, start_col, end_line, end_col, new_text) do
    lines = String.split(content, "\n")

    case Enum.at(lines, start_line) do
      nil ->
        content

      start_text ->
        case Enum.at(lines, end_line) do
          nil ->
            content

          end_text ->
            before = String.slice(start_text, 0, start_col)
            after_end = String.slice(end_text, end_col..-1)
            replacement = before <> new_text <> after_end

            {before_lines, rest} = Enum.split(lines, start_line)
            {_removed, after_lines} = Enum.split(rest, end_line - start_line + 1)

            new_lines = before_lines ++ [replacement] ++ after_lines
            Enum.join(new_lines, "\n")
        end
    end
  end

  # ── External Formatter ────────────────────────────────────────────────────

  @spec try_external_format(state(), pid()) :: state()
  defp try_external_format(state, buf) do
    filetype = Buffer.filetype(buf)
    file_path = Buffer.file_path(buf)
    spec = Minga.Editing.resolve_formatter(filetype, file_path)

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

  # ── Private helpers ───────────────────────────────────────────────────────

  @spec format_and_replace(state(), pid(), Minga.Editing.Formatter.formatter_spec()) :: state()
  defp format_and_replace(state, buf, spec) do
    content = Buffer.content(buf)
    buf_name = Buffer.file_path(buf) |> Path.basename()

    case Minga.Editing.format(content, spec) do
      {:ok, formatted} ->
        {cursor_line, cursor_col} = Buffer.cursor(buf)
        Buffer.replace_content(buf, formatted)
        line_count = Buffer.line_count(buf)
        safe_line = min(cursor_line, max(line_count - 1, 0))
        Buffer.move_to(buf, {safe_line, cursor_col})
        MingaEditor.log_to_messages("Formatted: #{buf_name}")
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
  defp queue_and_show_prompt(%{workspace: %{editing: %{mode: :normal}}} = state, tool_name) do
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
