defmodule MingaEditor.UI.Picker.CodeActionSource do
  @moduledoc """
  Picker source for LSP code actions.

  Displays available code actions (quickfixes, refactorings, source actions)
  and applies the selected action's workspace edit or executes its command.

  The caller opens the picker with a context map containing an `:actions`
  key (the raw LSP code action response array).
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.LspActions
  alias Minga.Log
  alias Minga.LSP.Client
  alias Minga.LSP.DocumentContext
  alias Minga.LSP.SyncServer
  alias MingaEditor.Effects.LspCodeActionResolve
  alias MingaEditor.EffectScheduler
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Code Actions"

  @impl true
  @spec layout() :: :centered
  def layout, do: :centered

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{picker_ui: %{context: %{actions: actions} = picker_context}})
      when is_list(actions) do
    document_context = Map.get(picker_context, :document_context)
    generation = Map.get(picker_context, :workspace_generation)

    actions
    |> Enum.with_index()
    |> Enum.map(fn {action, index} ->
      title = action["title"] || "Untitled action"
      kind = action["kind"]
      kind_label = if kind, do: " [#{format_kind(kind)}]", else: ""

      is_preferred = action["isPreferred"] == true
      preferred_label = if is_preferred, do: " ★", else: ""

      %Item{
        id: {index, action, document_context, generation},
        label: "#{title}#{kind_label}#{preferred_label}",
        description: kind || ""
      }
    end)
  end

  def candidates(_state), do: []

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {_index, action, context, generation}}, state) do
    apply_code_action(state, action, context, generation)
  end

  def on_select(%Item{id: {_index, action, context}}, state) do
    apply_code_action(state, action, context, nil)
  end

  def on_select(%Item{id: {_index, action}}, state),
    do: apply_code_action(state, action, nil, nil)

  # ── Private ────────────────────────────────────────────────────────────────

  @spec apply_code_action(
          EditorState.t(),
          map(),
          DocumentContext.t() | nil,
          MingaEditor.State.LSP.workspace_generation() | nil
        ) :: EditorState.t()
  defp apply_code_action(state, action, context, generation) do
    case validate_context(state, context, generation) do
      :ok -> continue_or_schedule(state, action, context, generation)
      {:error, reason} -> reject_action(state, reason)
    end
  end

  @spec continue_or_schedule(
          EditorState.t(),
          map(),
          DocumentContext.t() | nil,
          MingaEditor.State.LSP.workspace_generation() | nil
        ) :: EditorState.t()
  defp continue_or_schedule(state, %{"data" => nil} = action, context, generation),
    do: apply_resolved_action(state, action, context, generation)

  defp continue_or_schedule(
         state,
         %{"data" => _data, "edit" => nil} = action,
         context,
         generation
       ) do
    schedule_resolve(state, action, context, generation)
  end

  defp continue_or_schedule(state, %{"data" => _data} = action, context, generation)
       when not is_map_key(action, "edit") do
    schedule_resolve(state, action, context, generation)
  end

  defp continue_or_schedule(state, action, context, generation),
    do: apply_resolved_action(state, action, context, generation)

  @spec schedule_resolve(
          EditorState.t(),
          map(),
          DocumentContext.t() | nil,
          MingaEditor.State.LSP.workspace_generation() | nil
        ) :: EditorState.t()
  defp schedule_resolve(state, _action, nil, _generation),
    do: reject_action(state, :missing_document_context)

  defp schedule_resolve(state, _action, _context, nil),
    do: reject_action(state, :missing_workspace_generation)

  defp schedule_resolve(%{effect_scheduler: nil} = state, _action, _context, _generation),
    do: resolve_failed(state, :scheduler_unavailable)

  defp schedule_resolve(state, action, %DocumentContext{} = context, generation) do
    request = LspCodeActionResolve.request(action, context, generation)

    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _request_id, _disposition} -> state
      {:error, reason} -> resolve_failed(state, reason)
    end
  catch
    :exit, reason -> resolve_failed(state, {:scheduler_unavailable, reason})
  end

  @doc "Continues a resolved code action after revalidating its producing document context."
  @spec apply_resolved_action(
          EditorState.t(),
          map(),
          DocumentContext.t() | nil,
          MingaEditor.State.LSP.workspace_generation() | nil
        ) :: EditorState.t()
  def apply_resolved_action(state, action, context, generation) do
    with :ok <- validate_context(state, context, generation),
         {:ok, state} <- apply_action_edit(state, action, context) do
      maybe_execute_command(state, action, context)
    else
      {:edit_error, state} -> state
      {:error, reason} -> reject_action(state, reason)
    end
  end

  @doc "Publishes failure feedback for a deferred code-action resolve."
  @spec resolve_failed(EditorState.t(), term()) :: EditorState.t()
  def resolve_failed(state, reason) do
    Log.warning(:lsp, "codeAction/resolve failed: #{inspect(reason)}")

    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
      state,
      "Code action could not be resolved"
    )
  end

  @spec apply_action_edit(EditorState.t(), map(), DocumentContext.t() | nil) ::
          {:ok, EditorState.t()} | {:edit_error, EditorState.t()}
  defp apply_action_edit(state, %{"edit" => edit}, context) when is_map(edit) do
    case LspActions.apply_workspace_edit_result(state, edit, "Code action", context) do
      {:ok, state, message} ->
        {:ok, MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, message)}

      {:error, state, message} ->
        {:edit_error, MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, message)}
    end
  end

  defp apply_action_edit(state, %{"edit" => nil}, _context), do: {:ok, state}

  defp apply_action_edit(state, %{"edit" => _invalid}, _context) do
    {:edit_error,
     MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
       state,
       "Code action: could not apply edits (invalid workspace edit)"
     )}
  end

  defp apply_action_edit(state, _action, _context), do: {:ok, state}

  @spec maybe_execute_command(EditorState.t(), map(), DocumentContext.t() | nil) ::
          EditorState.t()
  defp maybe_execute_command(state, %{"command" => %{"command" => cmd} = command}, context) do
    execute_lsp_command(state, cmd, command, context)
  end

  defp maybe_execute_command(state, _action, _context), do: state

  @spec execute_lsp_command(EditorState.t(), String.t(), map(), DocumentContext.t() | nil) ::
          EditorState.t()
  defp execute_lsp_command(state, _cmd, _command, nil),
    do: reject_action(state, :missing_document_context)

  defp execute_lsp_command(state, cmd, command, %DocumentContext{client: client}) do
    params = %{"command" => cmd, "arguments" => Map.get(command, "arguments", [])}
    Client.request(client, "workspace/executeCommand", params)
    Log.info(:lsp, "Executing LSP command: #{cmd}")
    state
  end

  @spec validate_context(
          EditorState.t(),
          DocumentContext.t() | nil,
          MingaEditor.State.LSP.workspace_generation() | nil
        ) :: :ok | {:error, atom()}
  defp validate_context(_state, nil, _generation), do: :ok

  defp validate_context(state, %DocumentContext{} = context, generation) do
    if state.workspace.buffers.active == context.buffer and
         context.client in SyncServer.clients_for_buffer(context.buffer) and
         Minga.Buffer.version(context.buffer) == context.buffer_revision and
         generation_current?(state, context, generation) and
         Client.context_current?(context) do
      :ok
    else
      {:error, :stale_code_action}
    end
  catch
    :exit, _ -> {:error, :stale_code_action}
  end

  @spec generation_current?(
          EditorState.t(),
          DocumentContext.t(),
          MingaEditor.State.LSP.workspace_generation() | nil
        ) :: boolean()
  defp generation_current?(_state, _context, nil), do: true

  defp generation_current?(state, context, generation) do
    MingaEditor.State.LSP.workspace_generation_current?(
      state.lsp,
      :code_action,
      context.buffer,
      generation
    )
  end

  @spec reject_action(EditorState.t(), term()) :: EditorState.t()
  defp reject_action(state, reason) do
    Log.warning(:lsp, "Code action rejected: #{inspect(reason)}")

    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
      state,
      "Code action rejected because its source document changed"
    )
  end

  @spec format_kind(String.t()) :: String.t()
  defp format_kind("quickfix"), do: "quickfix"
  defp format_kind("refactor"), do: "refactor"
  defp format_kind("refactor.extract"), do: "extract"
  defp format_kind("refactor.inline"), do: "inline"
  defp format_kind("refactor.rewrite"), do: "rewrite"
  defp format_kind("source"), do: "source"
  defp format_kind("source.organizeImports"), do: "organize imports"
  defp format_kind("source.fixAll"), do: "fix all"
  defp format_kind(kind), do: kind
end
