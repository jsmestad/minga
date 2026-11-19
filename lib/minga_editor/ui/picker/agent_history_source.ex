defmodule MingaEditor.UI.Picker.AgentHistorySource do
  @moduledoc "A bounded read-only history picker that leaves the live transcript in place."
  @behaviour MingaEditor.UI.Picker.Source

  alias MingaAgent.{Message, Session}
  alias MingaAgent.Session.ConnectionTarget
  alias MingaAgent.Session.Transcript.{Cursor, Entry}
  alias MingaAgent.Tools.OutputLimit
  alias MingaEditor.Agent.ConnectionAction
  alias MingaEditor.PickerUI
  alias MingaEditor.Remote.SessionClient
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.{Context, Item}

  @typep origin :: {non_neg_integer(), ConnectionTarget.t()}
  @typep source :: ConnectionTarget.t() | Cursor.t()
  @page_size 24
  # The item section shares one 16-bit byte budget across the whole page.
  @description_bytes 512
  @preview_bytes 4_096
  @preview_lines 32

  @doc "Opens retained history for the active conversation without changing its scroll state."
  @spec open(EditorState.t()) :: EditorState.t()
  def open(state) do
    case ConnectionAction.origin(state) do
      {:ok, id, %{target: target}} ->
        open_page(state, {id, target}, target, :tail)

      {:error, _reason} ->
        NoticeWorkflow.publish(state, "Open an Agent session to read its retained history.")
    end
  end

  @doc "Closes this picker when workspace navigation leaves its owning conversation."
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

  def dismiss_if_stale(%EditorState{} = state), do: state

  @impl true
  @spec title() :: String.t()
  def title, do: "Retained Agent history"

  @impl true
  @spec gui_preview?() :: boolean()
  def gui_preview?, do: true

  @impl true
  @spec preview(Item.t(), MingaEditor.UI.Picker.Source.preview_context()) ::
          [[MingaEditor.UI.Picker.Source.preview_segment()]] | nil
  def preview(%Item{meta: %{intent: {:copy, text}}}, context) do
    fg = Map.get(context.intent.frame.theme, :fg, 0xCCCCCC)
    bounded = OutputLimit.utf8_prefix(text, @preview_bytes)

    {lines, overflow} =
      bounded
      |> String.split("\n", parts: @preview_lines + 1)
      |> Enum.split(@preview_lines)

    rendered = Enum.map(lines, &[{&1, fg, false}])

    if byte_size(bounded) == byte_size(text) and overflow == [],
      do: rendered,
      else: rendered ++ [[{"Preview shortened. Select to copy the full text.", fg, false}]]
  end

  def preview(_item, _context), do: nil

  @impl true
  @spec async?() :: boolean()
  def async?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(_context), do: []

  @impl true
  @spec async_fetch(Context.t()) :: {:ok, [Item.t()], map()} | {:error, String.t()}
  def async_fetch(%Context{
        picker_ui: %{context: %{origin: origin, source: source, anchor: anchor}}
      }) do
    {_id, target} = origin

    case read_page(target, source, anchor) do
      {:ok, _cursor, [], false} ->
        {:ok, [], %{status: "No retained messages before this point."}}

      {:ok, cursor, entries, earlier?} ->
        rows = Enum.map(entries, &message_row(&1, origin))
        items = if earlier?, do: [older_row(hd(entries), origin, cursor) | rows], else: rows
        {:ok, items, %{status: "Select a message to copy its retained text."}}

      {:error, :anchor_unavailable} ->
        {:error, "This message is no longer available. Reopen retained history."}

      {:error, reason} when reason in [:unauthorized, :not_found] ->
        {:error, "Retained history is not available for this session. Reconnect and try again."}

      _rejected ->
        {:error, "This conversation changed. Reopen retained history."}
    end
  catch
    :exit, _reason -> {:error, "The original Agent session is unavailable."}
  end

  @spec read_page(ConnectionTarget.t(), source(), pos_integer() | :tail) ::
          MingaAgent.Session.Transcript.history_result() | {:error, term()}
  defp read_page(%ConnectionTarget{session: pid}, source, anchor) when node(pid) == node() do
    Session.transcript_history_before(pid, source, anchor, @page_size)
  end

  defp read_page(target, source, anchor) do
    SessionClient.transcript_history_before(target, source, anchor, @page_size)
  end

  @impl true
  @spec on_select(Item.t(), EditorState.t()) :: EditorState.t()
  def on_select(%Item{meta: %{origin: origin, intent: {:older, cursor, id}}}, state),
    do: open_page(state, origin, cursor, id)

  def on_select(%Item{meta: %{origin: origin, intent: {:copy, text}}}, state) do
    if current?(state, origin) do
      Minga.Clipboard.write_async(text)
      state
    else
      state
    end
  end

  @spec open_page(EditorState.t(), origin(), source(), pos_integer() | :tail) :: EditorState.t()
  defp open_page(state, origin, source, anchor) do
    if current?(state, origin),
      do: PickerUI.open(state, __MODULE__, %{origin: origin, source: source, anchor: anchor}),
      else: state
  end

  @spec current?(EditorState.t(), origin()) :: boolean()
  defp current?(state, {id, target}) do
    match?({:ok, ^id, %{target: ^target}}, ConnectionAction.origin(state))
  end

  @spec older_row(Entry.t(), origin(), Cursor.t()) :: Item.t()
  defp older_row(%Entry{id: id}, origin, cursor) do
    %Item{
      id: {:older, id},
      label: "Earlier retained messages",
      meta: %{origin: origin, intent: {:older, cursor, id}}
    }
  end

  @spec message_row(Entry.t(), origin()) :: Item.t()
  defp message_row(%Entry{id: id, message: message}, origin) do
    text = Message.text(message)
    [description | _] = text |> OutputLimit.utf8_prefix(@description_bytes) |> :binary.split("\n")

    %Item{
      id: {:message, id},
      label: "#{role(message)} ##{id}",
      description: description,
      meta: %{origin: origin, intent: {:copy, text}}
    }
  end

  @spec role(Message.t()) :: String.t()
  defp role(message) do
    case elem(message, 0) do
      :user -> "You"
      :assistant -> "Assistant"
      :thinking -> "Thinking"
      :tool_call -> "Tool summary"
      :system -> "System"
      :usage -> "Usage"
    end
  end
end
