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
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Effects.ExternalFormat
  alias MingaEditor.LSP.FormatLifecycle
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.ToolPrompts
  alias MingaEditor.Shell.Traditional.ToolPromptWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Feedback
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
    case try_lsp_format(state, buf, nil) do
      {:ok, state} -> state
      :not_available -> state |> try_external_format(buf, nil) |> elem(1)
    end
  end

  def format_buffer(state),
    do: NoticeWorkflow.publish(state, "No buffer to format")

  @spec format_for_save(state(), pid(), BufferManagement.save_continuation()) ::
          {:pending, state()} | {:ready, state()}
  def format_for_save(state, buf, continuation) when is_pid(buf) do
    case try_lsp_format(state, buf, continuation) do
      {:ok, state} -> {:pending, state}
      :not_available -> try_external_format(state, buf, continuation)
    end
  end

  # ── LSP Formatting ────────────────────────────────────────────────────────

  @spec try_lsp_format(state(), pid(), BufferManagement.save_continuation() | nil) ::
          {:ok, state()} | :not_available
  defp try_lsp_format(state, buf, continuation) when is_pid(buf) do
    buf
    |> SyncServer.clients_for_buffer()
    |> Enum.find_value(:not_available, fn client ->
      case formatting_encoding(client) do
        {:ok, encoding} -> {:ok, request_lsp_format(state, buf, client, encoding, continuation)}
        :not_available -> false
      end
    end)
  end

  @spec formatting_encoding(pid()) ::
          {:ok, Minga.LSP.PositionEncoding.encoding()} | :not_available
  defp formatting_encoding(client) do
    case get_in(Client.capabilities(client), ["documentFormattingProvider"]) do
      provider when is_map(provider) or provider == true -> {:ok, Client.encoding(client)}
      _provider -> :not_available
    end
  catch
    :exit, _reason -> :not_available
  end

  @spec request_lsp_format(
          state(),
          pid(),
          pid(),
          Minga.LSP.PositionEncoding.encoding(),
          BufferManagement.save_continuation() | nil
        ) ::
          state()
  defp request_lsp_format(state, buf, client, encoding, continuation) do
    state = cancel_buffer_format(state, buf)
    file_path = Buffer.file_path(buf)
    uri = SyncServer.path_to_uri(file_path)
    tab_width = Buffer.get_option(buf, :tab_width) || 2
    insert_spaces = Buffer.get_option(buf, :indent_with) != :tabs

    params = %{
      "textDocument" => %{"uri" => uri},
      "options" => %{"tabSize" => tab_width, "insertSpaces" => insert_spaces}
    }

    version =
      case continuation do
        {:save_after_format, ^buf, requested_version, _action} -> requested_version
        nil -> Buffer.version(buf)
      end

    ref = Client.request(client, "textDocument/formatting", params)
    operation = FormatLifecycle.arm(client, ref, buf, version, encoding, continuation)
    %{state | lsp: (&LSPState.track_format(&1, operation)).(state.lsp)}
  end

  @spec cancel_pending_format(state()) :: {:canceled, state()} | :none
  def cancel_pending_format(state) do
    case LSPState.newest_format(state.lsp) do
      nil ->
        :none

      operation ->
        state =
          %{state | lsp: (&LSPState.drop_format(&1, operation.ref)).(state.lsp)}

        FormatLifecycle.cancel(operation)
        state = continue_canceled_format(state, operation)
        {:canceled, state}
    end
  end

  @spec apply_lsp_edits(pid(), [map()], non_neg_integer(), Minga.LSP.PositionEncoding.encoding()) ::
          {:ok, non_neg_integer()} | {:error, format_commit_error()}
  def apply_lsp_edits(_buf, [], expected_version, _encoding), do: {:ok, expected_version}

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
        state =
          %{state | lsp: (&LSPState.drop_format(&1, operation.ref)).(state.lsp)}

        FormatLifecycle.cancel(operation)
        continue_canceled_format(state, operation)
    end
  end

  defp continue_canceled_format(state, %{continuation: nil}), do: state

  defp continue_canceled_format(state, operation),
    do: BufferManagement.continue_after_format(state, operation.continuation, :canceled)

  # ── External Formatter ────────────────────────────────────────────────────

  @spec try_external_format(state(), pid(), BufferManagement.save_continuation() | nil) ::
          {:pending | :ready, state()}
  defp try_external_format(state, buf, continuation) do
    filetype = Buffer.filetype(buf)
    file_path = Buffer.file_path(buf)
    spec = Minga.Editing.resolve_formatter(filetype, file_path)

    case spec do
      nil ->
        state =
          if continuation,
            do: state,
            else: NoticeWorkflow.publish(state, "No formatter configured for #{filetype}")

        {:ready, state}

      _ ->
        command = spec |> String.split() |> List.first()

        if System.find_executable(command) do
          format_and_replace(state, buf, spec, continuation)
        else
          {:ready, maybe_prompt_formatter_install(state, command)}
        end
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  defp format_and_replace(state, buf, spec, continuation) do
    {state, operation_id} = start_external_format_operation(state, buf)
    schedule_external_format(state, buf, spec, operation_id, continuation)
  end

  defp start_external_format_operation(state, buf) do
    resource = "buffer:" <> inspect(buf)

    {operation_feedback, operation} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        :external_format,
        resource,
        "Formatting…"
      )

    state = %{
      state
      | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)
    }

    {state, operation.id}
  end

  @spec schedule_external_format(
          state(),
          pid(),
          Minga.Editing.Formatter.formatter_spec(),
          pos_integer(),
          BufferManagement.save_continuation() | nil
        ) ::
          {:pending | :ready, state()}
  defp schedule_external_format(
         %{effect_scheduler: nil} = state,
         _buf,
         _spec,
         operation_id,
         _continuation
       ) do
    state = %{
      state
      | feedback:
          Feedback.accept_operation_feedback(
            state.feedback,
            OperationFeedback.finish(
              state.feedback.operation_feedback,
              operation_id,
              :error,
              "Formatter scheduler unavailable"
            )
          )
    }

    {:ready, state}
  end

  defp schedule_external_format(state, buf, spec, operation_id, continuation) do
    request = ExternalFormat.request(buf, spec, operation_id, continuation)

    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _request_id, _disposition} ->
        {:pending, state}

      {:error, reason} ->
        state = %{
          state
          | feedback:
              Feedback.accept_operation_feedback(
                state.feedback,
                OperationFeedback.finish(
                  state.feedback.operation_feedback,
                  operation_id,
                  :error,
                  "Format not scheduled: #{reason}"
                )
              )
        }

        {:ready, state}
    end
  end

  @spec commit_formatted_content(
          pid(),
          non_neg_integer(),
          String.t(),
          Minga.Buffer.State.edit_source()
        ) :: {:ok, non_neg_integer()} | {:error, :read_only | :stale}
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
        NoticeWorkflow.publish(state, "Formatter not found: #{command}")

      recipe ->
        if ToolPromptWorkflow.skip?(state, recipe.name) do
          NoticeWorkflow.publish(state, "Formatter not found: #{command}")
        else
          queue_and_show_prompt(state, recipe.name)
        end
    end
  end

  @spec queue_and_show_prompt(state(), atom()) :: state()
  defp queue_and_show_prompt(%{workspace: %{editing: %{mode: :normal}}} = state, tool_name) do
    state = ToolPromptWorkflow.enqueue(state, tool_name)
    prompts = ToolPromptWorkflow.prompts(state)

    ms = %ToolConfirmState{
      pending: ToolPrompts.queue(prompts),
      declined: ToolPrompts.declined(prompts)
    }

    %{
      state
      | workspace: MingaEditor.Session.State.transition_mode(state.workspace, :tool_confirm, ms)
    }
  end

  defp queue_and_show_prompt(state, tool_name), do: ToolPromptWorkflow.enqueue(state, tool_name)

  command(:format_buffer, "Format buffer", requires_buffer: true, execute: &format_buffer/1)
end
