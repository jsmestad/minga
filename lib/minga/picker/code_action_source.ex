defmodule Minga.Picker.CodeActionSource do
  @moduledoc """
  Picker source for LSP code actions.

  Displays available code actions (quickfixes, refactorings, source actions)
  and applies the selected action's workspace edit or executes its command.

  The caller opens the picker with a context map containing an `:actions`
  key (the raw LSP code action response array).
  """

  @behaviour Minga.Picker.Source

  alias Minga.Editor.LspActions
  alias Minga.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Code Actions"

  @impl true
  @spec layout() :: :centered
  def layout, do: :centered

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(%{picker_ui: %{context: %{actions: actions}}}) when is_list(actions) do
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
    # Code actions can have an edit (WorkspaceEdit) and/or a command
    state =
      case action["edit"] do
        nil -> state
        edit -> LspActions.apply_workspace_edit(state, edit, "Code action")
      end

    # If there's a command, we'd need to execute it via the LSP client
    # Commands are server-side operations; for now log them
    case action["command"] do
      nil ->
        state

      %{"command" => cmd, "title" => title} ->
        Minga.Log.info(:lsp, "Code action command: #{title} (#{cmd})")
        # TODO: Execute the command via Client.request("workspace/executeCommand", ...)
        state

      _ ->
        state
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
