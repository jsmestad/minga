defmodule MingaEditor.Commands.Formatting do
  @moduledoc """
  Buffer formatting command.

  Supports formatting via LSP (if available) or external formatters.
  Attempts LSP formatting first if the language server is ready and supports formatting.
  Falls back to configured external formatters if LSP is unavailable.
  """

  use MingaEditor.Commands.Provider

  alias Minga.Buffer
  alias Minga.LSP.TextEdit
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Effects.ExternalFormat
  alias MingaEditor.LSP.FormatLifecycle
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.State.OperationFeedback
  alias Minga.Mode.ToolConfirmState
  alias Minga.Tool.Recipe.Registry, as: RecipeRegistry
  alias Minga.LSP.Client
  alias Minga.LSP.SyncServer

  @typedoc "Internal editor state."
  @type state :: EditorState.t()
  @type format_commit_error :: :invalid_edits | :not_alive | :read_only | :stale

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
    buf
    |> SyncServer.clients_for_buffer()
    |> Enum.find_value(:not_available, fn client ->
      case formatting_encoding(client) do
        {:ok, encoding} -> {:ok, request_lsp_format(state, buf, client, encoding)}
        :not_available -> false
      end
    end)
  end

  @spec formatting_encoding(pid()) ::
          {:ok, Minga.LSP.PositionEncoding.encoding()} | :not_available
  defp formatting_encoding(client) do
    capabilities = Client.capabilities(client)
    provider = get_in(capabilities, ["documentFormattingProvider"])

    if match?(%{}, provider) or provider == true do
      {:ok, Client.encoding(client)}
    else
      :not_available
    end
  catch
    :exit, _reason -> :not_available
  end

  @spec request_lsp_format(state(), pid(), pid(), Minga.LSP.PositionEncoding.encoding()) ::
          state()
  defp request_lsp_format(state, buf, client, encoding) do
    state = cancel_buffer_format(state, buf)
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
    operation = FormatLifecycle.arm(client, ref, buf, version, encoding)
    EditorState.update_lsp(state, &LSPState.track_format(&1, operation))
  end

  @doc "Cancels the newest active LSP formatting request, if one exists."
  @spec cancel_pending_format(state()) :: {:canceled, state()} | :none
  def cancel_pending_format(state) do
    case LSPState.newest_format(state.lsp) do
      nil ->
        :none

      operation ->
        state = EditorState.update_lsp(state, &LSPState.drop_format(&1, operation.ref))
        FormatLifecycle.cancel(operation)
        {:canceled, state}
    end
  end

  @doc "Applies LSP text edits only when the buffer still has `expected_version`."
  @spec apply_lsp_edits(pid(), [map()], non_neg_integer(), Minga.LSP.PositionEncoding.encoding()) ::
          :ok | {:error, format_commit_error()}
  def apply_lsp_edits(_buf, [], _expected_version, _encoding), do: :ok

  def apply_lsp_edits(buf, edits, expected_version, encoding)
      when is_pid(buf) and is_list(edits) and is_integer(expected_version) and
             expected_version >= 0 and encoding in [:utf8, :utf16, :utf32] do
    safely_commit(fn ->
      content = Buffer.content(buf)

      case TextEdit.apply(content, edits, encoding) do
        {:ok, new_content} -> commit_formatted_content(buf, expected_version, new_content, :lsp)
        {:error, _reason} -> {:error, :invalid_edits}
      end
    end)
  end

  @spec cancel_buffer_format(state(), pid()) :: state()
  defp cancel_buffer_format(state, buffer) do
    case LSPState.format_for_buffer(state.lsp, buffer) do
      nil ->
        state

      operation ->
        state = EditorState.update_lsp(state, &LSPState.drop_format(&1, operation.ref))
        FormatLifecycle.cancel(operation)
        state
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
    resource = "buffer:" <> inspect(buf)

    {state, operation} =
      OperationFeedback.start_in(state, :external_format, resource, "Formatting…")

    schedule_external_format(state, buf, spec, operation.id)
  end

  @spec schedule_external_format(
          state(),
          pid(),
          Minga.Editing.Formatter.formatter_spec(),
          pos_integer()
        ) ::
          state()
  defp schedule_external_format(%{effect_scheduler: nil} = state, _buf, _spec, operation_id) do
    OperationFeedback.finish_in(
      state,
      operation_id,
      :error,
      "Formatter scheduler unavailable"
    )
  end

  defp schedule_external_format(state, buf, spec, operation_id) do
    request = ExternalFormat.request(buf, spec, operation_id)

    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _request_id, _disposition} ->
        state

      {:error, reason} ->
        OperationFeedback.finish_in(
          state,
          operation_id,
          :error,
          "Format not scheduled: #{reason}"
        )
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
