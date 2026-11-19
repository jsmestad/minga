defmodule MingaEditor.UI.Picker.AgentDraftAttachmentSource do
  @moduledoc "Inspects and removes immutable attachments from the current Agent draft."

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Core.Unicode
  alias MingaAgent.{DraftAttachment, DraftSnapshot, Session}
  alias MingaAgent.Tool.Output.Reference
  alias MingaEditor.Agent.{DraftSave, DraftWorkflow}
  alias MingaEditor.PickerUI
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State
  alias MingaEditor.State.TabBar
  alias MingaEditor.UI.Picker.{Context, Item, Source}

  @typep origin :: {non_neg_integer(), DraftSave.target()}
  @typep page :: {DraftAttachment.identity(), non_neg_integer(), [non_neg_integer()]}
  # Keep the whole page visible in the stacked terminal picker's one-row preview.
  @row_cells 16
  @min_terminal_cols 24
  @min_terminal_rows 8

  @doc "Opens the attachment inspector without changing prompt editing state."
  @spec open(State.t()) :: State.t()
  def open(state) do
    case current_origin(state) do
      {origin, [_ | _] = attachments} ->
        PickerUI.open(state, __MODULE__, %{origin: origin, attachments: attachments})

      _empty ->
        NoticeWorkflow.publish(
          state,
          "No attachments in this draft. Select text in a file to attach a snapshot."
        )
    end
  end

  @doc "Closes an inspector when its original draft is no longer active."
  @spec dismiss_if_stale(State.t()) :: State.t()
  def dismiss_if_stale(
        %State{
          shell_runtime: %{
            state: %{
              modal: {:picker, %{picker_ui: %{source: __MODULE__, context: %{origin: origin}}}}
            }
          }
        } = state
      ) do
    case current_origin(state) do
      {^origin, _attachments} -> state
      _changed -> PickerUI.close(state)
    end
  end

  def dismiss_if_stale(state), do: state

  @impl true
  @spec title() :: String.t()
  def title, do: "Draft attachments"

  @impl true
  @spec async?() :: boolean()
  def async?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(_context), do: []

  @impl true
  @spec gui_preview?() :: boolean()
  def gui_preview?, do: true

  @impl true
  @spec async_fetch(Context.t()) :: {:ok, [Item.t()], Source.fetch_meta()} | {:error, String.t()}
  def async_fetch(%Context{picker_ui: %{context: %{origin: origin, attachments: attachments}}}) do
    items =
      for {kind, _source, label, revision, {:snapshot, %Reference{bytes: bytes, token: token}}} <-
            attachments do
        identity = {token, revision}

        %Item{
          id: {:page, origin, {identity, 0, []}},
          label: literal(label),
          description: "#{DraftAttachment.snapshot_label(kind)} · #{bytes} bytes",
          two_line: true
        }
      end

    {:ok, items, %{status: "Choose a snapshot to inspect or remove it."}}
  end

  def async_fetch(%Context{
        picker_ui: %{
          context: %{
            origin: {_owner, {session, record}} = origin,
            page: {identity, offset, previous}
          }
        }
      }) do
    case Session.read_draft_attachment(session, record, identity) do
      {:ok, {kind, _source, label, _revision, _capture}, text} when offset <= byte_size(text) ->
        tail = binary_part(text, offset, byte_size(text) - offset)
        {row, remaining} = take_row(tail, @row_cells, [])
        next = byte_size(text) - byte_size(remaining)
        description = DraftAttachment.snapshot_label(kind)

        items =
          page_items(
            origin,
            identity,
            {offset, previous},
            next,
            byte_size(text),
            {literal(label), description},
            [IO.iodata_to_binary(Enum.reverse(row))]
          )

        {:ok, items, %{status: "#{description} · bytes #{offset}–#{next} of #{byte_size(text)}"}}

      _unavailable ->
        {:error, "The snapshot is no longer available in this draft."}
    end
  catch
    :exit, _reason -> {:error, "The original Agent conversation disconnected."}
  end

  def async_fetch(%Context{picker_ui: %{context: %{origin: origin, confirmation: identity}}}) do
    {:ok,
     [
       %Item{id: :list, label: "Keep snapshot"},
       %Item{id: {:remove, origin, identity}, label: "Remove snapshot from draft"}
     ], %{status: "Removing a snapshot does not change the source file."}}
  end

  @impl true
  @spec preview(Item.t(), Source.preview_context()) :: [[Source.preview_segment()]] | nil
  def preview(%Item{meta: %{rows: rows}}, context) do
    fg = Map.get(context.intent.frame.theme, :fg, 0xCCCCCC)
    Enum.map(rows, &[{&1, fg, false}])
  end

  def preview(_item, _context), do: nil

  @impl true
  @spec on_select(Item.t(), State.t()) :: State.t()
  def on_select(
        %Item{id: {:page, _, _}},
        %State{frontend: %{capabilities: %{frontend_type: :tui}, terminal_viewport: viewport}} =
          state
      )
      when viewport.cols < @min_terminal_cols or viewport.rows < @min_terminal_rows do
    NoticeWorkflow.publish(
      state,
      "Enlarge the terminal to at least 24×8 to inspect the snapshot."
    )
  end

  def on_select(%Item{id: {:page, origin, {identity, _, _} = page}}, state) do
    if current_snapshot?(state, origin, identity),
      do: PickerUI.open(state, __MODULE__, %{origin: origin, page: page}),
      else: stale(state)
  end

  def on_select(%Item{id: {:confirm_remove, origin, identity}}, state) do
    if current_snapshot?(state, origin, identity) do
      PickerUI.open(state, __MODULE__, %{origin: origin, confirmation: identity})
    else
      stale(state)
    end
  end

  def on_select(%Item{id: {:remove, {owner, target} = origin, identity}}, state) do
    if current_snapshot?(state, origin, identity),
      do: DraftWorkflow.remove_attachment(state, owner, target, identity),
      else: stale(state)
  end

  def on_select(%Item{id: :list}, state), do: open(state)
  def on_select(_item, state), do: state

  @spec current_origin(State.t()) :: {origin(), [DraftSnapshot.attachment()]} | nil
  defp current_origin(%State{
         shell_runtime: %{state: %TraditionalState{} = shell},
         workspace: %{
           agent_ui: %{draft_save: %DraftSave{target: target, attachments: attachments}}
         }
       }) do
    case TraditionalState.tab_bar(shell) do
      %TabBar{} = tabs -> {{TabBar.active_workspace_id(tabs), target}, attachments}
      nil -> nil
    end
  end

  defp current_origin(_state), do: nil

  @spec current_snapshot?(State.t(), origin(), DraftAttachment.identity()) :: boolean()
  defp current_snapshot?(state, origin, identity) do
    case current_origin(state) do
      {^origin, attachments} ->
        Enum.any?(attachments, &(DraftAttachment.identity(&1) == identity))

      _changed ->
        false
    end
  end

  @spec page_items(
          origin(),
          DraftAttachment.identity(),
          {non_neg_integer(), [non_neg_integer()]},
          non_neg_integer(),
          non_neg_integer(),
          {String.t(), String.t()},
          [String.t()]
        ) :: [Item.t()]
  defp page_items(origin, identity, {offset, previous}, next, total, {label, description}, rows) do
    meta = %{rows: rows}

    trailing = [
      %Item{id: {:confirm_remove, origin, identity}, label: "Remove snapshot…", meta: meta},
      %Item{id: :list, label: "Back to attachments", meta: meta}
    ]

    trailing =
      case previous do
        [prior | rest] ->
          [page_item(origin, {identity, prior, rest}, "Previous page", meta) | trailing]

        [] ->
          trailing
      end

    trailing =
      if next < total,
        do: [
          page_item(origin, {identity, next, [offset | previous]}, "Next page", meta) | trailing
        ],
        else: trailing

    [%Item{id: :display, label: label, description: description, meta: meta} | trailing]
  end

  @spec page_item(origin(), page(), String.t(), map()) :: Item.t()
  defp page_item(origin, page, label, meta),
    do: %Item{id: {:page, origin, page}, label: label, meta: meta}

  @spec take_row(binary(), non_neg_integer(), [iodata()]) :: {[iodata()], binary()}
  defp take_row("\n" <> rest, _left, row), do: {row, rest}
  defp take_row(rest, 0, row), do: {row, rest}
  defp take_row("", _left, row), do: {row, ""}

  defp take_row(text, left, row) do
    {grapheme, remaining} = String.next_grapheme(text)
    literal = literal(grapheme)
    # A frontend can render a narrow base character as a two-cell emoji.
    width = max(Unicode.display_width(literal), min(byte_size(grapheme), 2))

    if width > left,
      do: {row, text},
      else: take_row(remaining, left - width, [literal | row])
  end

  @spec literal(String.t()) :: String.t()
  defp literal(text), do: for(<<cp::utf8 <- text>>, into: "", do: literal_codepoint(cp))

  @spec literal_codepoint(non_neg_integer()) :: String.t()
  defp literal_codepoint(cp) when cp in 0..31 or cp in 127..159,
    do: "\\x" <> Base.encode16(<<cp>>)

  defp literal_codepoint(cp), do: <<cp::utf8>>

  @spec stale(State.t()) :: State.t()
  defp stale(state),
    do: NoticeWorkflow.publish(state, "The Agent draft changed. Reopen its attachments.")
end
