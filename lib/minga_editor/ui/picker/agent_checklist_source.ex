defmodule MingaEditor.UI.Picker.AgentChecklistSource do
  @moduledoc "Inspects the active conversation's retained checklist without moving its transcript or changing its draft."
  @behaviour MingaEditor.UI.Picker.Source

  alias MingaAgent.TodoItem
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.Tools.OutputLimit
  alias MingaEditor.Agent.ConnectionAction
  alias MingaEditor.PickerUI
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.{Context, Item, Source}

  @doc "Opens the checklist of the current Agent workspace."
  @spec open(EditorState.t()) :: EditorState.t()
  def open(state) do
    with {:ok, tab_id, %{target: target}} <- ConnectionAction.origin(state),
         [_first | _rest] = todos <- state.workspace.agent_ui.view.activity.todos do
      PickerUI.open(state, __MODULE__, %{origin: {tab_id, target}, todos: todos})
    else
      [] ->
        NoticeWorkflow.publish(state, "No tasks in this conversation.")

      {:error, _reason} ->
        NoticeWorkflow.publish(state, "Open an Agent session to inspect its checklist.")
    end
  end

  @doc "Dismisses the checklist when the workspace leaves its owning conversation."
  @spec dismiss_if_stale(EditorState.t()) :: EditorState.t()
  def dismiss_if_stale(
        %EditorState{
          shell_runtime: %{
            state: %{
              modal: {:picker, %{picker_ui: %{source: __MODULE__, context: %{origin: origin}}}}
            }
          }
        } = state
      ) do
    if current?(state, origin), do: state, else: PickerUI.close(state)
  end

  def dismiss_if_stale(state), do: state

  @impl true
  @spec title() :: String.t()
  def title, do: "Agent checklist"

  @impl true
  @spec gui_preview?() :: boolean()
  def gui_preview?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{picker_ui: %{context: %{origin: origin, todos: todos}}}) do
    Enum.map(todos, fn %TodoItem{} = todo ->
      %Item{
        id: todo.id,
        label: first_line(todo.description),
        description: status_label(todo.status),
        meta: %{origin: origin, todo: todo}
      }
    end)
  end

  @impl true
  @spec preview(Item.t(), Source.preview_context()) :: [[Source.preview_segment()]]
  def preview(%Item{meta: %{todo: todo}}, context) do
    fg = Map.get(context.intent.frame.theme, :fg, 0xCCCCCC)

    todo
    |> details()
    |> Enum.join("\n")
    |> String.split("\n", parts: 31)
    |> Enum.map(&[{&1, fg, false}])
  end

  @impl true
  @spec on_select(Item.t(), EditorState.t()) :: EditorState.t()
  def on_select(%Item{meta: %{origin: origin, todo: todo}}, state) do
    if current?(state, origin) do
      text = Enum.join(details(todo) ++ reference_token(todo.result_ref), "\n")
      Minga.Clipboard.write_async(text)
      state
    else
      NoticeWorkflow.publish(state, "The checklist belongs to a different conversation.")
    end
  end

  @spec current?(EditorState.t(), {non_neg_integer(), MingaAgent.Session.ConnectionTarget.t()}) ::
          boolean()
  defp current?(state, {tab_id, target}) do
    match?({:ok, ^tab_id, %{target: ^target}}, ConnectionAction.origin(state))
  end

  @spec first_line(String.t()) :: String.t()
  defp first_line(text) do
    [line | _rest] = text |> OutputLimit.utf8_prefix(320) |> :binary.split("\n")
    line
  end

  @spec details(TodoItem.t()) :: [String.t()]
  defp details(todo) do
    [
      "#{status_label(todo.status)}: #{todo.description}"
      | reference_summary(todo.result_ref) ++ note_lines(todo, "Task ID: #{todo.id}")
    ]
  end

  @spec note_lines(TodoItem.t(), String.t()) :: [String.t()]
  defp note_lines(%TodoItem{note: nil}, id), do: [id]
  defp note_lines(%TodoItem{status: :blocked, note: note}, id), do: ["Blocker: #{note}", id]
  defp note_lines(%TodoItem{note: note}, id), do: ["Note: #{note}", id]

  @spec reference_summary(Reference.t() | nil) :: [String.t()]
  defp reference_summary(nil), do: []

  defp reference_summary(%Reference{} = reference),
    do: ["Retained result: #{reference.bytes} bytes (#{reference.media_type})"]

  @spec reference_token(Reference.t() | nil) :: [String.t()]
  defp reference_token(nil), do: []
  defp reference_token(%Reference{token: token}), do: ["Reference token: #{token}"]

  @spec status_label(TodoItem.status()) :: String.t()
  defp status_label(:pending), do: "Pending"
  defp status_label(:in_progress), do: "Active"
  defp status_label(:blocked), do: "Blocked"
  defp status_label(:done), do: "Done"
end
