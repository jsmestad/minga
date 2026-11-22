defmodule MingaEditor.UI.Picker.AgentRetainedOutputSource do
  @moduledoc "Pages immutable tool output without modifying the live transcript or composer."
  @behaviour MingaEditor.UI.Picker.Source

  alias MingaAgent.ArtifactStore.Fetched
  alias MingaAgent.Session
  alias MingaAgent.Session.ConnectionTarget
  alias MingaAgent.Tool.Output.{Range, Reference}
  alias MingaAgent.Tools.OutputLimit
  alias MingaEditor.Agent.ConnectionAction
  alias MingaEditor.PickerUI
  alias MingaEditor.Remote.SessionClient
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State
  alias MingaEditor.UI.Picker.AgentRetainedOutputCopy
  alias MingaEditor.UI.Picker.{Context, Item, Source}

  @page_size 4_096
  @utf8_boundary_margin 3
  @transfer_size 65_536
  @clipboard_limit 16 * 1_024 * 1_024
  @preview_lines 32
  @typep origin :: {non_neg_integer(), ConnectionTarget.t()}
  @typep selection :: {:page, non_neg_integer()} | :copy_all
  @typep reader :: (Range.t() -> {:ok, Fetched.t()} | {:error, term()})
  @typep source :: %{
           origin: origin(),
           message_id: pos_integer(),
           reference: Reference.t(),
           selection: selection()
         }

  @doc "Opens a bounded detail for the retained output already resolved from the displayed tool card."
  @spec open(State.t(), non_neg_integer(), ConnectionTarget.t(), pos_integer(), Reference.t()) ::
          State.t()
  def open(state, workspace_id, target, message_id, reference) do
    reopen(state, %{
      origin: {workspace_id, target},
      message_id: message_id,
      reference: reference,
      selection: {:page, 0}
    })
  end

  @impl true
  @spec title() :: String.t()
  def title, do: "Retained tool output"

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
  @spec preview(Item.t(), Source.preview_context()) :: [[Source.preview_segment()]] | nil
  def preview(%Item{meta: %{view: view}}, context) do
    fg = Map.get(context.intent.frame.theme, :fg, 0xCCCCCC)

    lines =
      view |> preview_text(@page_size) |> String.split("\n", parts: @preview_lines + 1)

    Enum.map(Enum.take(lines, @preview_lines), &[{&1, fg, false}])
  end

  def preview(_item, _context), do: nil

  @impl true
  @spec async_fetch(Context.t()) :: {:ok, [Item.t()], Source.fetch_meta()} | {:error, String.t()}
  def async_fetch(%Context{picker_ui: %{context: source}}) do
    with {:ok, read} <- reader(source),
         {:ok, items, status} <- read_selection(source, source.selection, read) do
      {:ok, items, %{status: status}}
    else
      {:error, reason} -> {:error, failure_message(reason)}
    end
  catch
    :exit, _reason -> {:error, "The original Agent session disconnected. No output was copied."}
  end

  @impl true
  @spec selection_disposition(Item.t(), term()) :: Source.selection_disposition()
  def selection_disposition(%Item{} = item, _context), do: {:stay_open, item}

  @impl true
  @spec on_select(Item.t(), State.t()) :: State.t()
  def on_select(%Item{meta: %{source: %{origin: origin} = source, selection: selection}}, state) do
    if current?(state, origin) do
      PickerUI.reload_retained_output(state, %{source | selection: selection})
    else
      stale_selection(state)
    end
  end

  def on_select(
        %Item{meta: %{source: %{origin: origin}, copy: bytes}},
        %State{shell_runtime: %{state: %{modal: {:picker, %{picker_ui: picker}}}}} = state
      ) do
    if current?(state, origin) do
      case picker.load_status do
        :loading -> NoticeWorkflow.publish(state, "Wait for the retained output read to finish.")
        _ -> AgentRetainedOutputCopy.start(state, bytes, picker.fetch_revision)
      end
    else
      stale_selection(state)
    end
  end

  def on_select(%Item{}, state), do: stale_selection(state)

  @spec stale_selection(State.t()) :: State.t()
  defp stale_selection(state) do
    NoticeWorkflow.publish(
      state,
      "The original Agent conversation changed. No output was copied."
    )
  end

  @doc "Cancels pending work when navigation leaves the source conversation."
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
    if current?(state, origin), do: state, else: PickerUI.close(state)
  end

  def dismiss_if_stale(%State{} = state), do: state

  @spec read_selection(source(), selection(), reader()) ::
          {:ok, [Item.t()], String.t()} | {:error, term()}
  defp read_selection(source, {:page, offset}, read) do
    total = source.reference.bytes
    next = min(offset + @page_size, total)

    with {:ok, fetched, bytes, start, stop} <-
           read_page(read, total, offset, next, source.reference.media_type) do
      label = "#{copy_prefix(fetched.capture)} bytes #{start}–#{stop} (end exclusive)"
      items = add_navigation([copy_item(source, bytes, label)], source, offset, next, total)
      {:ok, items, "#{capture_label(fetched.capture)} · #{total} retained bytes"}
    end
  end

  defp read_selection(%{reference: %{bytes: total}} = source, :copy_all, read)
       when total <= @clipboard_limit do
    with {:ok, capture, bytes} <- read_all(read, total) do
      {encoding, view} = display(bytes, source.reference.media_type)
      label = copy_label("#{copy_prefix(capture)} #{total} retained bytes", encoding)
      item = %Item{id: :copy, label: label, meta: %{source: source, view: view, copy: view}}
      {:ok, [item], capture_label(capture)}
    end
  end

  defp read_selection(_source, :copy_all, _read), do: {:error, :clipboard_limit}

  @spec read_page(reader(), non_neg_integer(), non_neg_integer(), non_neg_integer(), String.t()) ::
          {:ok, Fetched.t(), binary(), non_neg_integer(), non_neg_integer()} | {:error, term()}
  defp read_page(read, total, offset, next, "text/" <> _) do
    window_start = max(0, offset - @utf8_boundary_margin)
    window_stop = min(total, next + @utf8_boundary_margin)

    with {:ok, fetched} <- fetch(read, total, window_start, window_stop - window_start) do
      start = utf8_boundary(fetched.bytes, offset - window_start, 1)
      stop = utf8_boundary(fetched.bytes, next - window_start, 1)
      bytes = binary_part(fetched.bytes, start, stop - start)
      {:ok, fetched, bytes, start + window_start, stop + window_start}
    end
  end

  defp read_page(read, total, offset, next, _media_type) do
    with {:ok, fetched} <- fetch(read, total, offset, next - offset),
         do: {:ok, fetched, fetched.bytes, offset, next}
  end

  # Adjacent nominal ranges resolve the same boundary. Move back only if a valid scalar straddles it.
  @spec utf8_boundary(binary(), non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp utf8_boundary(bytes, position, back)
       when back <= @utf8_boundary_margin and back <= position and position < byte_size(bytes) do
    start = position - back
    suffix = binary_part(bytes, start, byte_size(bytes) - start)

    case suffix do
      <<_scalar::utf8, rest::binary>> when byte_size(suffix) - byte_size(rest) > back -> start
      _ -> utf8_boundary(bytes, position, back + 1)
    end
  end

  defp utf8_boundary(_bytes, position, _back), do: position

  @spec add_navigation(
          [Item.t()],
          source(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [Item.t()]
  defp add_navigation(items, source, offset, next, total) do
    previous_items =
      if offset > 0,
        do: [navigation(source, {:page, max(offset - @page_size, 0)}, "Previous retained range")],
        else: []

    next_items =
      if next < total, do: [navigation(source, {:page, next}, "Next retained range")], else: []

    last = div(max(total - 1, 0), @page_size) * @page_size

    last_items =
      if next < last, do: [navigation(source, {:page, last}, "Last retained range")], else: []

    all_items =
      if total > @page_size and total <= @clipboard_limit,
        do: [navigation(source, :copy_all, "Read all #{total} retained bytes for copying")],
        else: []

    items ++ previous_items ++ next_items ++ last_items ++ all_items
  end

  @spec navigation(source(), selection(), String.t()) :: Item.t()
  defp navigation(source, selection, label),
    do: %Item{id: selection, label: label, meta: %{source: source, selection: selection}}

  @spec copy_item(source(), binary(), String.t()) :: Item.t()
  defp copy_item(source, bytes, label) do
    {encoding, view} = display(bytes, source.reference.media_type)
    [description | _] = view |> preview_text(256) |> :binary.split("\n")

    %Item{
      id: :copy,
      label: copy_label(label, encoding),
      description: description,
      meta: %{source: source, view: view, copy: view}
    }
  end

  @spec preview_text(String.t(), pos_integer()) :: String.t()
  defp preview_text(view, limit) do
    view
    |> OutputLimit.utf8_prefix(limit)
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F-\x9F]/u, "�")
    |> OutputLimit.utf8_prefix(limit)
  end

  @spec copy_label(String.t(), :text | :base64) :: String.t()
  defp copy_label(label, :text), do: label
  defp copy_label(label, :base64), do: label <> " as Base64"

  @spec read_all(reader(), non_neg_integer()) ::
          {:ok, MingaAgent.Tool.Output.capture_status(), binary()} | {:error, term()}
  defp read_all(read, total) do
    with {:ok, first} <- fetch(read, total, 0, min(@transfer_size, total)),
         {:ok, parts} <- read_rest(read, first.selection.count, total, [first.bytes]) do
      {:ok, first.capture, parts |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  @spec read_rest(reader(), non_neg_integer(), non_neg_integer(), [binary()]) ::
          {:ok, [binary()]} | {:error, term()}
  defp read_rest(_read, total, total, parts), do: {:ok, parts}

  defp read_rest(read, offset, total, parts) do
    with {:ok, fetched} <- fetch(read, total, offset, min(@transfer_size, total - offset)) do
      read_rest(read, offset + fetched.selection.count, total, [fetched.bytes | parts])
    end
  end

  @spec fetch(reader(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, Fetched.t()} | {:error, term()}
  defp fetch(read, total, offset, count) do
    with {:ok, range} <- Range.new(:requested, :bytes, offset, count, total), do: read.(range)
  end

  @spec reader(source()) :: {:ok, reader()} | {:error, term()}
  defp reader(%{
         origin: {_id, %ConnectionTarget{session: session} = target},
         message_id: message_id,
         reference: reference
       })
       when node(session) == node() do
    # minga:allow-blocking — async_fetch/1 runs the reader in the picker fetch worker (async?/0 is true)
    {:ok, &Session.read_retained_output(target, message_id, reference, &1)}
  end

  defp reader(%{
         origin: {_id, %ConnectionTarget{session: session, session_id: session_id} = target},
         message_id: message_id,
         reference: reference
       }) do
    case SessionClient.credentials_for_pid(session) do
      {:ok, ^session_id, token} ->
        {:ok, &SessionClient.read_retained_output(target, token, message_id, reference, &1)}

      {:ok, _different_session_id, _token} ->
        {:error, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  @spec display(binary(), String.t()) :: {:text | :base64, String.t()}
  defp display(bytes, "text/" <> _subtype) do
    if String.valid?(bytes) and :binary.match(bytes, <<0>>) == :nomatch,
      do: {:text, bytes},
      else: {:base64, Base.encode64(bytes)}
  end

  defp display(bytes, _type), do: {:base64, Base.encode64(bytes)}

  @spec copy_prefix(MingaAgent.Tool.Output.capture_status()) :: String.t()
  defp copy_prefix(:complete), do: "Copy"
  defp copy_prefix({:incomplete, _reason}), do: "Copy partial"

  @spec capture_label(MingaAgent.Tool.Output.capture_status()) :: String.t()
  defp capture_label(:complete), do: "Complete capture"

  defp capture_label({:incomplete, reason}),
    do: "Partial capture: " <> String.replace(Atom.to_string(reason), "_", " ")

  @spec failure_message(term()) :: String.t()
  defp failure_message(:output_changed),
    do: "The displayed tool result changed. Reopen its retained output."

  defp failure_message(:stale_target),
    do: "The original Agent conversation changed. Reopen its retained output."

  defp failure_message(:unauthorized),
    do: "This session is not authorized to read the retained output."

  defp failure_message({:remote_unavailable, :timeout}),
    do: "The remote Agent did not respond in time. Retry reading the output."

  defp failure_message(reason)
       when reason in [:not_found, {:remote_unavailable, :noconnection}],
       do: "The original Agent session disconnected. Reconnect before reading its output."

  defp failure_message(reason) when reason in [:expired, :unknown_reference, :output_unavailable],
    do: "The original output is no longer retained. The tool was not rerun."

  defp failure_message(:clipboard_limit),
    do: "This capture is too large to copy at once. Copy one retained range at a time."

  defp failure_message(_reason),
    do: "Reading retained output failed. The clipboard and original transcript are unchanged."

  @spec reopen(State.t(), source()) :: State.t()
  defp reopen(state, %{origin: origin} = source) do
    if current?(state, origin), do: PickerUI.open(state, __MODULE__, source), else: state
  end

  @doc "Checks whether a pending read still belongs to the displayed conversation."
  @spec current_fetch?(State.t(), term()) :: boolean()
  def current_fetch?(state, %{origin: origin}), do: current?(state, origin)
  def current_fetch?(_state, _context), do: false

  @spec current?(State.t(), origin()) :: boolean()
  defp current?(state, {id, target}),
    do: match?({:ok, ^id, %{target: ^target}}, ConnectionAction.origin(state))
end
