defmodule MingaEditor.State.Launchpad do
  @moduledoc """
  State for the zero-buffers launchpad surface (#2689).

  Created when the workspace enters the empty state (last buffer closed or
  no-file startup) and cleared when any buffer opens. Session and recents
  data are snapshotted once at entry so the render builder stays pure and
  frame builds never touch the filesystem.

  This module owns focus movement; activation semantics live in the
  commands layer so both frontends behave identically.
  """

  alias Minga.Session

  @max_recents 5

  @resume_id "resume"
  @action_ids ["action-find-file", "action-file-tree", "action-palette", "action-tutor"]

  @type t :: %__MODULE__{
          focused_id: String.t() | nil,
          crashed?: boolean(),
          session_file_count: non_neg_integer(),
          recents: [String.t()],
          pending_g?: boolean()
        }

  defstruct focused_id: nil,
            crashed?: false,
            session_file_count: 0,
            recents: [],
            pending_g?: false

  @doc """
  Builds launchpad state by snapshotting session and recent-file data.

  `:session_dir` scopes the session read (threaded from the editor's
  session options so tests stay hermetic). `:session_file_count`,
  `:crashed?`, and `:recents` override the reads entirely for tests.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    {count, crashed?} = session_info(opts)
    recents = Keyword.get_lazy(opts, :recents, &safe_recent_files/0)

    lp = %__MODULE__{
      crashed?: crashed?,
      session_file_count: count,
      recents: Enum.take(recents, @max_recents)
    }

    %{lp | focused_id: List.first(item_ids(lp))}
  end

  @doc """
  Ordered focusable item ids: resume, recents, then actions.

  On a first run (no session, no recents) the tutorial is promoted to the
  front: it renders as the "Get started" hero card with a `RET` chip, so it
  must also hold the initial focus for Enter-on-launch to honor that chip.
  """
  @spec item_ids(t()) :: [String.t()]
  def item_ids(%__MODULE__{session_file_count: 0, recents: []}) do
    ["action-tutor" | List.delete(@action_ids, "action-tutor")]
  end

  def item_ids(%__MODULE__{} = lp) do
    resume = if lp.session_file_count > 0, do: [@resume_id], else: []
    recents = Enum.with_index(lp.recents, 1) |> Enum.map(fn {_path, i} -> recent_id(i) end)
    resume ++ recents ++ @action_ids
  end

  @doc "The resume item id."
  @spec resume_id() :: String.t()
  def resume_id, do: @resume_id

  @doc "The id for the recent file at 1-based position `i`."
  @spec recent_id(pos_integer()) :: String.t()
  def recent_id(i) when is_integer(i) and i > 0, do: "recent-#{i}"

  @doc "The recent-file path for an item id, or nil."
  @spec recent_path(t(), String.t()) :: String.t() | nil
  def recent_path(%__MODULE__{recents: recents}, "recent-" <> idx) do
    case Integer.parse(idx) do
      {i, ""} when i > 0 -> Enum.at(recents, i - 1)
      _ -> nil
    end
  end

  def recent_path(%__MODULE__{}, _id), do: nil

  @doc "Moves focus by one step or to an edge."
  @spec move_focus(t(), :next | :prev | :first | :last) :: t()
  def move_focus(%__MODULE__{} = lp, direction) do
    ids = item_ids(lp)
    current = Enum.find_index(ids, &(&1 == lp.focused_id)) || 0

    target =
      case direction do
        :next -> min(current + 1, length(ids) - 1)
        :prev -> max(current - 1, 0)
        :first -> 0
        :last -> length(ids) - 1
      end

    %{lp | focused_id: Enum.at(ids, target)}
  end

  @doc "Sets focus to a specific item id when it exists."
  @spec focus(t(), String.t()) :: t()
  def focus(%__MODULE__{} = lp, id) do
    if id in item_ids(lp), do: %{lp | focused_id: id}, else: lp
  end

  @doc """
  Handles a `g` keypress for the `gg` go-to-first chord.

  The first `g` arms the pending state; the second moves focus to the
  first item. Any other key must call `clear_pending_g/1`.
  """
  @spec press_g(t()) :: t()
  def press_g(%__MODULE__{pending_g?: true} = lp) do
    %{move_focus(lp, :first) | pending_g?: false}
  end

  def press_g(%__MODULE__{} = lp), do: %{lp | pending_g?: true}

  @doc "Disarms a pending `gg` chord."
  @spec clear_pending_g(t()) :: t()
  def clear_pending_g(%__MODULE__{} = lp), do: %{lp | pending_g?: false}

  @spec session_info(keyword()) :: {non_neg_integer(), boolean()}
  defp session_info(opts) do
    case Keyword.fetch(opts, :session_file_count) do
      {:ok, count} ->
        {count, Keyword.get(opts, :crashed?, false)}

      :error ->
        # A present-but-nil :session_dir must fall back to the default dir;
        # Session.session_file/1 treats any present key as a real path.
        session_opts =
          opts |> Keyword.take([:session_dir]) |> Enum.reject(fn {_k, v} -> is_nil(v) end)

        case Session.load(session_opts) do
          {:ok, %{buffers: buffers}} when is_list(buffers) and buffers != [] ->
            {length(buffers), not Session.clean_shutdown?(session_opts)}

          _ ->
            {0, false}
        end
    end
  end

  @spec safe_recent_files() :: [String.t()]
  defp safe_recent_files do
    Minga.Project.recent_files()
  catch
    :exit, _ -> []
  end
end
