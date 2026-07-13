defmodule MingaEditor.Commands.Formatting do
  @moduledoc """
  Buffer formatting command.

  Supports formatting via LSP (if available) or external formatters.
  Attempts LSP formatting first if the language server is ready and supports formatting.
  Falls back to configured external formatters if LSP is unavailable.
  """

  use MingaEditor.Commands.Provider

  alias Minga.Buffer
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Effects.ExternalFormat
  alias MingaEditor.State, as: EditorState
  alias Minga.Mode.ToolConfirmState
  alias Minga.Tool.Recipe.Registry, as: RecipeRegistry
  alias Minga.LSP.Client
  alias Minga.LSP.SyncServer

  @typedoc "Internal editor state."
  @type state :: EditorState.t()
  @type format_commit_error :: :not_alive | :read_only | :stale

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

    match?(%{}, get_in(caps, ["documentFormattingProvider"])) or
      get_in(caps, ["documentFormattingProvider"]) == true
  end

  @lsp_format_timeout 5_000
  @lsp_format_spinner_delay 100
  @lsp_format_cancel_delay 1_000

  @spec request_lsp_format(state(), pid(), pid()) :: state()
  defp request_lsp_format(state, buf, client) do
    state = cancel_pending_format(state)

    file_path = Buffer.file_path(buf)
    uri = SyncServer.path_to_uri(file_path)
    tab_width = Buffer.get_option(buf, :tab_width) || 2
    insert_spaces = Buffer.get_option(buf, :indent_with) != :tabs

    params = %{
      "textDocument" => %{"uri" => uri},
      "options" => %{"tabSize" => tab_width, "insertSpaces" => insert_spaces}
    }

    version = Buffer.version(buf)
    ref = Client.request(client, "textDocument/formatting", params)
    Process.send_after(self(), {:lsp_format_spinner, ref}, @lsp_format_spinner_delay)
    Process.send_after(self(), {:lsp_format_cancellable, ref}, @lsp_format_cancel_delay)
    Process.send_after(self(), {:lsp_format_timeout, ref}, @lsp_format_timeout)
    EditorState.put_lsp_pending(state, ref, {:format, buf, version})
  end

  @spec cancel_pending_format(state()) :: state()
  defp cancel_pending_format(state) do
    case find_pending_format(state) do
      nil -> state
      {ref, _kind} -> EditorState.delete_lsp_pending(state, ref)
    end
  end

  @doc "Finds the active pending LSP formatting request, if one exists."
  @spec find_pending_format(state()) :: {reference(), tuple()} | nil
  def find_pending_format(state) do
    Enum.find(state.workspace.lsp_pending, fn
      {_ref, {:format, _buf, _version}} -> true
      _ -> false
    end)
  end

  @doc "Applies LSP text edits only when the buffer still has `expected_version`."
  @spec apply_lsp_edits(pid(), [map()], non_neg_integer()) ::
          :ok | {:error, format_commit_error()}
  def apply_lsp_edits(_buf, [], _expected_version), do: :ok

  def apply_lsp_edits(buf, edits, expected_version)
      when is_pid(buf) and is_list(edits) and is_integer(expected_version) and
             expected_version >= 0 do
    safely_commit(fn ->
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

      commit_formatted_content(buf, expected_version, new_content, :lsp)
    end)
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
            after_end = String.slice(end_text, end_col..-1//1)
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
  defp format_and_replace(%{effect_scheduler: nil} = state, _buf, _spec) do
    EditorState.set_status(state, "Formatter scheduler unavailable")
  end

  defp format_and_replace(state, buf, spec) do
    request = ExternalFormat.request(buf, spec)

    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _request_id, _disposition} ->
        EditorState.set_status(state, "Formatting…")

      {:error, reason} ->
        EditorState.set_status(state, "Format not scheduled: #{reason}")
    end
  end

  @spec commit_formatted_content(
          pid(),
          non_neg_integer(),
          String.t(),
          Minga.Buffer.State.edit_source()
        ) :: :ok | {:error, :read_only | :stale}
  defp commit_formatted_content(buf, expected_version, content, source) do
    Buffer.replace_content_if_version(buf, expected_version, content, source)
  end

  @spec safely_commit((-> term())) :: term()
  defp safely_commit(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :not_alive}
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
    queue = Enum.concat(state.shell_runtime.state.tool_prompt_queue, [tool_name])
    state = EditorState.set_tool_prompt_queue(state, queue)
    ms = %ToolConfirmState{pending: queue, declined: state.shell_runtime.state.tool_declined}
    EditorState.transition_mode(state, :tool_confirm, ms)
  end

  defp queue_and_show_prompt(state, tool_name) do
    EditorState.set_tool_prompt_queue(
      state,
      Enum.concat(state.shell_runtime.state.tool_prompt_queue, [tool_name])
    )
  end

  command(:format_buffer, "Format buffer", requires_buffer: true, execute: &format_buffer/1)
end
