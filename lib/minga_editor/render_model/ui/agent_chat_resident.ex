defmodule MingaEditor.RenderModel.UI.AgentChatResident do
  @moduledoc """
  Renderer-local, revision-keyed resident derivation of the active Agent transcript.

  The Editor owns the indexed display and sends exact keyed display changes (`MingaEditor.Renderer.TranscriptUpdate`). `Renderer.Server` admits every update in mailbox order through `MingaEditor.RenderModel.UI.AgentChatBuilder.admit/3` before frames are coalesced, so each frame attempt carries the immutable root for its own revision. A root is disposable: it never reads Session, never persists, and is rebuilt only from an Editor seed.

  The displayed sequence is split into segments in display order: pinned rows before the cut, the pinned separator, the hidden-history separator, rows at or after the cut, the first-run empty state, and the registry footer. Row segments are `AgentChatResident.Trie` values with cached exact wire weights, so the byte-capped newest suffix is one descent per segment. Admission derives and weighs only changed entries, plus the exactly affected decorated rows when the pending approval or retained-output scope changes. Unchanged bodies are never re-derived or re-sized.

  Pending approval decorates only the latest displayed occurrence of its tool-call ID, and only while that occurrence is running. An older running occurrence is never decorated.
  """

  alias Minga.RenderModel.UI.AgentChat
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaEditor.Agent.UIState.TranscriptProjection.Index
  alias MingaEditor.Renderer.TranscriptUpdate
  alias MingaEditor.RenderModel.UI.AgentChatResident.Entry
  alias MingaEditor.RenderModel.UI.AgentChatResident.Trie

  @typedoc """
  Admission context resolved by the semantic builder from the admitted intent.

  `approval` is `{tool_call_id, approval}` for the displayed Session's pending approval. `derive` converts one display item with an optional approval into its semantic message; `tool_id` names the tool call a display item shows; `decoratable?` reports whether an item can carry inline approval controls. `measure` returns a message's exact resident wire weight, or a bounded fallback message and its weight when the message exceeds a codec limit, so admission is total.
  """
  @type context :: %{
          scope: term(),
          approval: {String.t(), term()} | nil,
          footer: [AgentChat.message()],
          max_bytes: pos_integer(),
          derive: (Index.item(), term() | nil -> AgentChat.message()),
          measure: (AgentChat.message() ->
                      {:ok, pos_integer()} | {:fallback, AgentChat.message(), pos_integer()}),
          tool_id: (Index.item() -> String.t() | nil),
          decoratable?: (Index.item() -> boolean())
        }

  @type key :: TranscriptProjection.display_key()
  @typep segment_selection ::
           :all | :none | {:from, non_neg_integer()} | {:last, non_neg_integer()}
  @typep selection ::
           {segment_selection(), segment_selection(), segment_selection(), segment_selection(),
            segment_selection(), segment_selection()}

  @enforce_keys [:identity, :revision, :epoch]
  defstruct identity: nil,
            revision: 0,
            epoch: 0,
            pinned: Trie.new(),
            pinned_separator: nil,
            hidden_separator: nil,
            rows: Trie.new(),
            empty: nil,
            footer: [],
            footer_source: [],
            tools: %{},
            tool_of: %{},
            scope: nil,
            approval: nil,
            decorated: nil,
            fallbacks: MapSet.new(),
            selection: nil

  @type t :: %__MODULE__{
          identity: TranscriptUpdate.identity(),
          revision: TranscriptUpdate.revision(),
          epoch: TranscriptUpdate.epoch(),
          pinned: Trie.t(),
          pinned_separator: Entry.t() | nil,
          hidden_separator: Entry.t() | nil,
          rows: Trie.t(),
          empty: Entry.t() | nil,
          footer: [Entry.t()],
          footer_source: [AgentChat.message()],
          tools: %{optional(String.t()) => [key()]},
          tool_of: %{optional(key()) => String.t()},
          scope: term(),
          approval: {String.t(), term()} | nil,
          decorated: {key(), term()} | nil,
          fallbacks: MapSet.t(key()),
          selection: {pos_integer(), selection(), boolean()} | nil
        }

  @typedoc "`:reseed` leaves the last good root untouched and asks the Editor for a seed."
  @type admission :: {:ok, t()} | {:reseed, t() | nil}

  @doc """
  Applies one Editor update to the last admitted root.

  A seed always replaces the root. An unchanged marker or change list applies only on the exact identity and revision; anything else returns `{:reseed, root}` without mutation.
  """
  @spec admit(t() | nil, TranscriptUpdate.t(), context()) :: admission()
  def admit(_root, {:seed, identity, revision, epoch, entries}, context),
    do: {:ok, seed(identity, revision, epoch, entries, context)}

  def admit(
        %__MODULE__{identity: identity, revision: revision} = root,
        {:unchanged, identity, revision, epoch},
        context
      ),
      do: {:ok, advance(root, revision, epoch, [], context)}

  def admit(
        %__MODULE__{identity: identity, revision: from} = root,
        {:changes, identity, from, to, epoch, changes},
        context
      ),
      do: {:ok, advance(root, to, epoch, changes, context)}

  def admit(root, _noncontiguous, _context), do: {:reseed, root}

  @doc "Returns the semantic messages inside the byte-capped resident suffix and whether older entries were omitted."
  @spec resident_messages(t()) :: {[AgentChat.message()], boolean()}
  def resident_messages(%__MODULE__{selection: {_max, selection, truncated?}} = root) do
    {pinned, pinned_sep, hidden_sep, rows, empty, footer} = selection

    messages =
      []
      |> trie_messages(root.pinned, pinned)
      |> slot_message(root.pinned_separator, pinned_sep)
      |> slot_message(root.hidden_separator, hidden_sep)
      |> trie_messages(root.rows, rows)
      |> slot_message(root.empty, empty)
      |> footer_messages(root.footer, footer)
      |> Enum.reverse()

    {messages, truncated?}
  end

  @doc """
  Returns the display keys that show a fallback notice in `root` but did not in `previous`.

  A different presentation reports all of its fallback keys. Callers use this to report each unencodable entry once instead of on every frame.
  """
  @spec new_fallbacks(t() | nil, t() | nil) :: [key()]
  def new_fallbacks(
        %__MODULE__{identity: identity} = previous,
        %__MODULE__{identity: identity} = root
      ),
      do: root.fallbacks |> MapSet.difference(previous.fallbacks) |> Enum.sort()

  def new_fallbacks(_previous, %__MODULE__{fallbacks: fallbacks}), do: Enum.sort(fallbacks)
  def new_fallbacks(_previous, nil), do: []

  @doc "Returns the trie height used by the work bound, the larger of the two row segments."
  @spec height(t()) :: non_neg_integer()
  def height(%__MODULE__{pinned: pinned, rows: rows}),
    do: max(Trie.height(pinned), Trie.height(rows))

  # ── Seed ──

  @spec seed(
          TranscriptUpdate.identity(),
          TranscriptUpdate.revision(),
          TranscriptUpdate.epoch(),
          [{key(), Index.item()}],
          context()
        ) :: t()
  defp seed(identity, revision, epoch, entries, context) do
    {tools, tool_of} =
      Enum.reduce(entries, {%{}, %{}}, fn {key, item}, index ->
        index_tool(index, key, context.tool_id.(item))
      end)

    decorated = decoration(tools, context, &seed_item(entries, &1))

    derived =
      Enum.map(entries, fn {key, item} -> {key, derive(key, item, decorated, context)} end)

    root = %__MODULE__{
      fallbacks: for({key, %Entry{fallback?: true}} <- derived, into: MapSet.new(), do: key),
      identity: identity,
      revision: revision,
      epoch: epoch,
      pinned: Trie.from_sorted(for {{0, ordinal}, entry} <- derived, do: {ordinal, entry}),
      pinned_separator: slot(derived, {1, 0}),
      hidden_separator: slot(derived, {2, 0}),
      rows: Trie.from_sorted(for {{3, ordinal}, entry} <- derived, do: {ordinal, entry}),
      empty: slot(derived, {4, 0}),
      tools: tools,
      tool_of: tool_of,
      scope: context.scope,
      approval: context.approval,
      decorated: decorated
    }

    root |> install_footer(context) |> select(context.max_bytes, nil)
  end

  defp seed_item(entries, key) do
    case List.keyfind(entries, key, 0) do
      {^key, item} -> item
      nil -> nil
    end
  end

  defp slot(derived, key) do
    case List.keyfind(derived, key, 0) do
      {^key, entry} -> entry
      nil -> nil
    end
  end

  # ── Ordered changes ──

  @spec advance(
          t(),
          TranscriptUpdate.revision(),
          TranscriptUpdate.epoch(),
          [TranscriptUpdate.change()],
          context()
        ) :: t()
  defp advance(previous, revision, epoch, changes, context) do
    {tools, tool_of} =
      Enum.reduce(changes, {previous.tools, previous.tool_of}, &reindex(&1, &2, context))

    changed = Map.new(changes, &change_entry/1)

    decorated =
      if changes == [] and context.approval == previous.approval,
        do: previous.decorated,
        else: decoration(tools, context, &current_item(previous, changed, &1))

    root =
      Enum.reduce(changes, previous, fn
        {:delete, key}, acc -> remove(acc, key)
        {:put, key, item}, acc -> place(acc, key, derive(key, item, decorated, context))
      end)

    root =
      %{root | revision: revision, epoch: epoch, tools: tools, tool_of: tool_of}
      |> redecorate(previous.decorated, decorated, changed, context)
      |> rescope(context, changed)
      |> install_footer(context)

    select(root, context.max_bytes, previous)
  end

  defp change_entry({:put, key, item}), do: {key, item}
  defp change_entry({:delete, key}), do: {key, nil}

  defp current_item(root, changed, key) do
    case Map.fetch(changed, key) do
      {:ok, item} -> item
      :error -> lookup_item(root, key)
    end
  end

  defp reindex({:delete, key}, index, _context), do: unindex_tool(index, key)

  defp reindex({:put, key, item}, index, context),
    do: index |> unindex_tool(key) |> index_tool(key, context.tool_id.(item))

  defp index_tool(index, _key, nil), do: index

  defp index_tool({tools, tool_of}, key, tool_id) do
    keys = Map.get(tools, tool_id, [])
    {Map.put(tools, tool_id, insert_desc(keys, key)), Map.put(tool_of, key, tool_id)}
  end

  defp unindex_tool({tools, tool_of} = index, key) do
    case Map.pop(tool_of, key) do
      {nil, _tool_of} ->
        index

      {tool_id, tool_of} ->
        case List.delete(Map.fetch!(tools, tool_id), key) do
          [] -> {Map.delete(tools, tool_id), tool_of}
          keys -> {Map.put(tools, tool_id, keys), tool_of}
        end
    end
  end

  defp insert_desc([head | rest], key) when head > key, do: [head | insert_desc(rest, key)]
  defp insert_desc(keys, key), do: [key | keys]

  # ── Decorations ──

  # The latest displayed occurrence owns the approval; an older running row never does.
  defp decoration(_tools, %{approval: nil}, _item), do: nil

  defp decoration(tools, %{approval: {tool_call_id, approval}} = context, item) do
    with [latest | _] <- Map.get(tools, tool_call_id, []),
         {_id, _message, _style} = candidate <- item.(latest) do
      if context.decoratable?.(candidate), do: {latest, approval}
    else
      _missing -> nil
    end
  end

  defp redecorate(root, same, same, _changed, _context), do: root

  defp redecorate(root, previous, decorated, changed, context) do
    root
    |> rederive_decorated(previous, decorated, changed, context)
    |> rederive_decorated(decorated, decorated, changed, context)
    |> then(&%{&1 | decorated: decorated})
  end

  defp rederive_decorated(root, nil, _decorated, _changed, _context), do: root

  defp rederive_decorated(root, {key, _approval}, decorated, changed, context) do
    if Map.has_key?(changed, key), do: root, else: rederive(root, key, decorated, context)
  end

  defp rescope(%__MODULE__{scope: scope} = root, %{scope: scope, approval: approval}, _changed),
    do: %{root | approval: approval}

  defp rescope(root, context, changed) do
    root = %{root | scope: context.scope, approval: context.approval}

    root.tool_of
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(changed, &1))
    |> Enum.reduce(root, &rederive(&2, &1, root.decorated, context))
  end

  defp rederive(root, key, decorated, context) do
    case lookup_item(root, key) do
      nil -> root
      item -> place(root, key, derive(key, item, decorated, context))
    end
  end

  defp derive(key, item, {key, approval}, context),
    do: weigh(item, context.derive.(item, approval), context)

  defp derive(_key, item, _decorated, context),
    do: weigh(item, context.derive.(item, nil), context)

  defp weigh(item, message, context) do
    case context.measure.(message) do
      {:ok, weight} -> Entry.new(item, message, weight)
      {:fallback, fallback, weight} -> Entry.fallback(item, fallback, weight)
    end
  end

  # ── Footer ──

  defp install_footer(%__MODULE__{footer_source: footer} = root, %{footer: footer}), do: root

  defp install_footer(root, %{footer: footer} = context) do
    previous = Map.new(root.footer, &{&1.message, &1})

    entries =
      Enum.map(footer, fn message ->
        Map.get_lazy(previous, message, fn -> weigh(nil, message, context) end)
      end)

    %{root | footer: entries, footer_source: footer}
  end

  # ── Segment routing ──

  defp lookup_item(root, key) do
    case lookup(root, key) do
      %Entry{item: item} -> item
      nil -> nil
    end
  end

  defp lookup(root, {0, ordinal}), do: Trie.fetch(root.pinned, ordinal)
  defp lookup(root, {1, 0}), do: root.pinned_separator
  defp lookup(root, {2, 0}), do: root.hidden_separator
  defp lookup(root, {3, ordinal}), do: Trie.fetch(root.rows, ordinal)
  defp lookup(root, {4, 0}), do: root.empty

  defp place(root, key, entry), do: root |> place_entry(key, entry) |> track_fallback(key, entry)

  defp place_entry(root, {0, ordinal}, entry),
    do: %{root | pinned: Trie.put(root.pinned, ordinal, entry)}

  defp place_entry(root, {1, 0}, entry), do: %{root | pinned_separator: entry}
  defp place_entry(root, {2, 0}, entry), do: %{root | hidden_separator: entry}

  defp place_entry(root, {3, ordinal}, entry),
    do: %{root | rows: Trie.put(root.rows, ordinal, entry)}

  defp place_entry(root, {4, 0}, entry), do: %{root | empty: entry}

  defp track_fallback(root, key, %Entry{fallback?: true}),
    do: %{root | fallbacks: MapSet.put(root.fallbacks, key)}

  defp track_fallback(root, key, _entry),
    do: %{root | fallbacks: MapSet.delete(root.fallbacks, key)}

  defp remove(root, key),
    do: %{remove_entry(root, key) | fallbacks: MapSet.delete(root.fallbacks, key)}

  defp remove_entry(root, {0, ordinal}), do: %{root | pinned: Trie.delete(root.pinned, ordinal)}
  defp remove_entry(root, {1, 0}), do: %{root | pinned_separator: nil}
  defp remove_entry(root, {2, 0}), do: %{root | hidden_separator: nil}
  defp remove_entry(root, {3, ordinal}), do: %{root | rows: Trie.delete(root.rows, ordinal)}
  defp remove_entry(root, {4, 0}), do: %{root | empty: nil}

  # ── Byte-capped newest suffix ──

  # Reuse the selection when neither the displayed entries nor the cap changed.
  defp select(root, max_bytes, %__MODULE__{selection: {max_bytes, _, _} = selection} = previous) do
    if same_display?(root, previous),
      do: %{root | selection: selection},
      else: select(root, max_bytes, nil)
  end

  defp select(root, max_bytes, _previous) do
    state = {:open, max_bytes, true}
    {footer, state} = fit_footer(root.footer, state)
    {empty, state} = fit_slot(root.empty, state)
    {rows, state} = fit_trie(root.rows, state)
    {hidden_sep, state} = fit_slot(root.hidden_separator, state)
    {pinned_sep, state} = fit_slot(root.pinned_separator, state)
    {pinned, state} = fit_trie(root.pinned, state)
    selection = {pinned, pinned_sep, hidden_sep, rows, empty, footer}
    %{root | selection: {max_bytes, selection, state == :closed}}
  end

  defp same_display?(root, previous) do
    root.pinned === previous.pinned and root.rows === previous.rows and
      root.pinned_separator === previous.pinned_separator and
      root.hidden_separator === previous.hidden_separator and root.empty === previous.empty and
      root.footer === previous.footer
  end

  defp fit_slot(_entry, :closed), do: {:none, :closed}
  defp fit_slot(nil, state), do: {:all, state}

  defp fit_slot(%Entry{weight: weight}, {:open, budget, forced?})
       when forced? or weight <= budget,
       do: {:all, {:open, budget - weight, false}}

  defp fit_slot(%Entry{}, _state), do: {:none, :closed}

  defp fit_trie(_trie, :closed), do: {:none, :closed}

  defp fit_trie(trie, {:open, budget, forced?}) do
    case Trie.fit(trie, budget, forced?) do
      {:all, used, forced?} -> {:all, {:open, budget - used, forced?}}
      {:partial, _used, from} -> {{:from, from}, :closed}
    end
  end

  defp fit_footer(entries, state) do
    entries
    |> Enum.reverse()
    |> Enum.reduce_while({0, state}, fn
      %Entry{weight: weight}, {kept, {:open, budget, forced?}}
      when forced? or weight <= budget ->
        {:cont, {kept + 1, {:open, budget - weight, false}}}

      _entry, {kept, _state} ->
        {:halt, {kept, :closed}}
    end)
    |> case do
      {_kept, {:open, _budget, _forced?} = state} -> {:all, state}
      {kept, :closed} -> {{:last, kept}, :closed}
    end
  end

  defp trie_messages(acc, _trie, :none), do: acc
  defp trie_messages(acc, trie, :all), do: trie_messages(acc, trie, {:from, 0})

  defp trie_messages(acc, trie, {:from, from}),
    do: Trie.reduce_from(trie, from, acc, fn %Entry{message: message}, acc -> [message | acc] end)

  defp slot_message(acc, %Entry{message: message}, :all), do: [message | acc]
  defp slot_message(acc, _entry, _selection), do: acc

  defp footer_messages(acc, _entries, :none), do: acc

  defp footer_messages(acc, entries, :all),
    do: Enum.reduce(entries, acc, fn %Entry{message: message}, acc -> [message | acc] end)

  defp footer_messages(acc, entries, {:last, kept}),
    do: footer_messages(acc, Enum.take(entries, -kept), :all)
end
