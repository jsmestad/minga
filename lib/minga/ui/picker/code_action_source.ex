defmodule Minga.UI.Picker.CodeActionSource do
  @moduledoc """
  Picker source for LSP code actions.

  Displays available code actions (quickfixes, refactorings, source actions)
  and applies the selected action's workspace edit or executes its command.

  The caller opens the picker with a context map containing an `:actions`
  key (the raw LSP code action response array).
  """

  @behaviour Minga.UI.Picker.Source

  alias Minga.Editor.LspActions
  alias Minga.Log
  alias Minga.LSP.Client
  alias Minga.LSP.SyncServer
  alias Minga.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Code Actions"

  @impl true
  @spec layout() :: :centered
  def layout, do: :centered

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(%{shell_state: %{picker_ui: %{context: %{actions: actions}}}})
      when is_list(actions) do
    actions
    |> Enum.with_index()
    |> Enum.map(fn {action, index} ->
      title = action["title"] || "Untitled action"
      kind = action["kind"]
      kind_label = if kind, do: " [#{format_kind(kind)}]", else: ""

      is_preferred = action["isPreferred"] == true
      preferred_label = if is_preferred, do: " ★", else: ""

      %Item{
        id: {index, action},
        label: "#{title}#{kind_label}#{preferred_label}",
        description: kind || ""
      }
    end)
  end

  def candidates(_state), do: []

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {_index, action}}, state) do
    apply_code_action(state, action)
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  # ── Private ────────────────────────────────────────────────────────────────

  @spec apply_code_action(term(), map()) :: term()
  defp apply_code_action(state, action) do
    # If the action has a `data` field but no `edit` field, resolve it first
    # via codeAction/resolve to get the full action with the edit.
    action = maybe_resolve_action(state, action)

    # Code actions can have an edit (WorkspaceEdit) and/or a command
    state =
      case action["edit"] do
        nil -> state
        edit -> LspActions.apply_workspace_edit(state, edit, "Code action")
      end

    # If there's a command, execute it via the LSP client
    case action["command"] do
      nil ->
        state

      %{"command" => cmd} = command ->
        execute_lsp_command(state, cmd, command)

      _ ->
        state
    end
  end

  # Resolves a code action that has a `data` field but no `edit` field.
  # This handles lazy-resolved actions per LSP 3.16+.
  @spec maybe_resolve_action(term(), map()) :: map()
  defp maybe_resolve_action(state, action) do
    needs_resolve = action["data"] != nil and action["edit"] == nil

    if needs_resolve do
      resolve_action(state, action)
    else
      action
    end
  end

  @spec resolve_action(term(), map()) :: map()
  defp resolve_action(state, action) do
    case lsp_client_for(state.workspace.buffers.active) do
      nil ->
        Log.warning(:lsp, "No LSP client to resolve code action")
        action

      client ->
        do_resolve_request(client, action)
    end
  end

  @spec do_resolve_request(pid(), map()) :: map()
  defp do_resolve_request(client, action) do
    case Client.request_sync(client, "codeAction/resolve", action, 5_000) do
      {:ok, resolved} when is_map(resolved) ->
        resolved

      {:error, reason} ->
        Log.warning(:lsp, "codeAction/resolve failed: #{inspect(reason)}")
        action

      _ ->
        action
    end
  end

  @spec execute_lsp_command(term(), String.t(), map()) :: term()
  defp execute_lsp_command(state, cmd, command) do
    buf = state.workspace.buffers.active

    case lsp_client_for(buf) do
      nil ->
        Log.warning(:lsp, "No LSP client to execute command: #{cmd}")
        state

      client ->
        params = %{
          "command" => cmd,
          "arguments" => Map.get(command, "arguments", [])
        }

        # Fire and forget; command results (if any) arrive as LSP notifications
        Client.request(client, "workspace/executeCommand", params)
        Log.info(:lsp, "Executing LSP command: #{cmd}")
        state
    end
  end

  @spec lsp_client_for(pid() | nil) :: pid() | nil
  defp lsp_client_for(nil), do: nil

  defp lsp_client_for(buffer_pid) do
    case SyncServer.clients_for_buffer(buffer_pid) do
      [client | _] -> client
      [] -> nil
    end
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
