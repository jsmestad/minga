defmodule MingaAgent.Autobiography do
  @moduledoc """
  Code provenance over the durable agent event log: "git blame for the agent's mind".

  Every agent file edit is already persisted as a `:file_edit_proposed` event
  carrying the file path, the full before/after content, and the originating
  `tool_call_id`/session. The agent's reasoning for that edit (the user request
  that prompted it, plus the thinking and assistant text of that turn) is
  persisted in the same per-session, append-only log.

  So provenance is a read-only projection, not new captured state. We never
  reconstruct or summarise "why" after the fact: we point at the reasoning that
  was recorded live when the edit happened.

  * `for_line/3` answers "why is this line like this?" by content-matching the
    line against the `after_content` of past edits (most recent wins).
  * `for_file/2` answers "what did the agent do to this file?" as a chronological
    list of edit-turns.

  Both return `Entry` structs. Lines/files the agent never wrote return `nil` / `[]`.

  ## Known limitations (v1)

  Provenance is keyed on the file path recorded at edit time, matched exactly.
  If a file is renamed or moved after the agent edited it, lookups miss and the
  file reads as "no history" even though the edits exist under the old path.
  Bridging renames would require consulting `git` (blame/log `--follow`); that
  is deliberately out of scope for v1. Coverage is also bounded by the event
  log's retention window.
  """

  alias MingaAgent.EventLog
  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.Store

  # How many past edits of a file to consider. Newest first; retention-bounded anyway.
  @candidate_limit 200
  # How many events before an edit to scan for its turn's request/thinking.
  # ponytail: fixed window covers a normal turn; a turn longer than this just
  # loses its leading user_message, upgrade to per-turn indexing if it bites.
  @context_window 5000

  defmodule Entry do
    @moduledoc "One agent edit-turn that produced or changed code, with its recorded reasoning."

    @enforce_keys [:path, :session_id, :occurred_at]
    defstruct [
      :path,
      :session_id,
      :tool_call_id,
      :tool_name,
      :occurred_at,
      :user_request,
      :thinking,
      :assistant_text
    ]

    @type t :: %__MODULE__{
            path: String.t(),
            session_id: String.t(),
            tool_call_id: String.t() | nil,
            tool_name: String.t() | nil,
            occurred_at: DateTime.t(),
            user_request: String.t() | nil,
            thinking: String.t() | nil,
            assistant_text: String.t() | nil
          }
  end

  @typedoc "Read options. `:db` injects an open connection (caller owns it); otherwise one is opened."
  @type opt :: {:db, Store.db()} | {:db_dir, String.t()} | {:limit, pos_integer()}

  @doc """
  Returns the most recent agent edit-turn whose `after_content` contains `needle`, or `nil`.

  Prefers the edit that *introduced* the text (present after, absent before);
  falls back to the most recent edit that merely contains it.
  """
  @spec for_line(String.t(), String.t(), [opt()]) :: {:ok, Entry.t() | nil} | {:error, term()}
  def for_line(path, needle, opts \\ []) when is_binary(path) and is_binary(needle) do
    trimmed = String.trim(needle)

    with_db(opts, fn db ->
      case candidates(db, path, opts) do
        [] ->
          {:ok, nil}

        candidates when trimmed == "" ->
          # Blank line carries no signal: attribute it to the most recent turn.
          {:ok, candidates |> hd() |> build_entry(db)}

        candidates ->
          match =
            Enum.find(candidates, &introduced?(&1, trimmed)) ||
              Enum.find(candidates, &contains_after?(&1, trimmed))

          {:ok, match && build_entry(match, db)}
      end
    end)
  end

  @doc """
  Returns the file's agent edit-turns, most recent first, one per `{session, tool_call}`.
  """
  @spec for_file(String.t(), [opt()]) :: {:ok, [Entry.t()]} | {:error, term()}
  def for_file(path, opts \\ []) when is_binary(path) do
    with_db(opts, fn db ->
      entries =
        db
        |> candidates(path, opts)
        |> Enum.uniq_by(&{&1.session_id, payload(&1, "tool_call_id")})
        |> Enum.map(&build_entry(&1, db))

      {:ok, entries}
    end)
  end

  # ── Internals ──────────────────────────────────────────────────────────────

  @spec candidates(Store.db(), String.t(), [opt()]) :: [EventRecord.t()]
  defp candidates(db, path, opts) do
    limit = Keyword.get(opts, :limit, @candidate_limit)

    # ponytail: exact path match only. A basename/suffix fallback would match a
    # same-named file in another directory and surface the WRONG file's history,
    # which is worse than none. If abs/rel path forms ever diverge in practice,
    # normalize both against the project root here, not by guessing on basename.
    case Store.file_edits_for_path(db, path, limit) do
      {:ok, edits} -> edits
      {:error, _} -> []
    end
  end

  @spec introduced?(EventRecord.t(), String.t()) :: boolean()
  defp introduced?(edit, needle) do
    contains_after?(edit, needle) and
      not String.contains?(payload(edit, "before_content") || "", needle)
  end

  @spec contains_after?(EventRecord.t(), String.t()) :: boolean()
  defp contains_after?(edit, needle),
    do: String.contains?(payload(edit, "after_content") || "", needle)

  @spec build_entry(EventRecord.t(), Store.db()) :: Entry.t()
  defp build_entry(%EventRecord{} = edit, db) do
    context = turn_context(db, edit.session_id, edit.id)

    %Entry{
      path: payload(edit, "path"),
      session_id: edit.session_id,
      tool_call_id: payload(edit, "tool_call_id"),
      tool_name: payload(edit, "tool_name"),
      occurred_at: edit.wall_clock,
      user_request: context.user_request,
      thinking: context.thinking,
      assistant_text: context.assistant_text
    }
  end

  @spec turn_context(Store.db(), String.t(), non_neg_integer() | nil) :: %{
          user_request: String.t() | nil,
          thinking: String.t() | nil,
          assistant_text: String.t() | nil
        }
  defp turn_context(_db, _session_id, nil),
    do: %{user_request: nil, thinking: nil, assistant_text: nil}

  defp turn_context(db, session_id, edit_id) do
    cursor = max(edit_id - @context_window, 0)

    events =
      case Store.events_after(db, session_id, cursor, @context_window + 1) do
        {:ok, evs} -> Enum.filter(evs, &(&1.id <= edit_id))
        {:error, _} -> []
      end

    turn = turn_slice(events)

    %{
      user_request: last_user_request(events),
      thinking: concat_deltas(turn, :thinking_delta),
      assistant_text: concat_deltas(turn, :assistant_delta)
    }
  end

  # Events from the most recent user_message up to the edit (the turn that made it).
  @spec turn_slice([EventRecord.t()]) :: [EventRecord.t()]
  defp turn_slice(events) do
    case last_event(events, :user_message) do
      nil -> events
      user_msg -> Enum.filter(events, &(&1.id > user_msg.id))
    end
  end

  @spec last_user_request([EventRecord.t()]) :: String.t() | nil
  defp last_user_request(events) do
    case last_event(events, :user_message) do
      nil -> nil
      ev -> blank_to_nil(payload(ev, "text"))
    end
  end

  @spec last_event([EventRecord.t()], EventRecord.event_type()) :: EventRecord.t() | nil
  defp last_event(events, type) do
    events |> Enum.filter(&(&1.event_type == type)) |> List.last()
  end

  @spec concat_deltas([EventRecord.t()], EventRecord.event_type()) :: String.t() | nil
  defp concat_deltas(events, type) do
    events
    |> Enum.filter(&(&1.event_type == type))
    |> Enum.map_join("", &(payload(&1, "delta") || ""))
    |> blank_to_nil()
  end

  @spec payload(EventRecord.t(), String.t()) :: term()
  defp payload(%EventRecord{payload: payload}, key), do: Map.get(payload, key)

  @spec blank_to_nil(String.t() | nil) :: String.t() | nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(text), do: if(String.trim(text) == "", do: nil, else: text)

  @spec with_db([opt()], (Store.db() -> result)) :: result | {:error, term()}
        when result: {:ok, term()}
  defp with_db(opts, fun) do
    case Keyword.fetch(opts, :db) do
      {:ok, db} ->
        fun.(db)

      :error ->
        case EventLog.open_read_connection(opts) do
          {:ok, db} -> try_close(db, fun)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec try_close(Store.db(), (Store.db() -> result)) :: result when result: term()
  defp try_close(db, fun) do
    fun.(db)
  after
    Store.close(db)
  end
end
