defmodule Minga.Session do
  @moduledoc """
  Session persistence: what the window held, saved per project.

  The editor periodically saves a `Minga.Session.Snapshot` (open files, cursors, window splits with each window's scroll, and the active file) to a JSON file. Each project root has its own file (see `session_file/1`), so opening a project picks up where you left off in that project. `MingaEditor.Session.Capture` builds the snapshot from editor state.

  The session file includes a `version` field for forward compatibility.
  Old session files that lack newer fields get defaults when loaded.

  ## Clean shutdown detection

  A `clean_shutdown` flag is set in the session file on orderly exit.
  On next launch, if the flag is missing or false, Minga knows the
  previous session crashed and shows "Restored from previous session"
  in `*Messages*`.
  """

  @session_filename "session.json"

  alias Minga.Session.BufferEntry
  alias Minga.Session.Snapshot

  @typedoc "A snapshot of the current editor session."
  @type snapshot :: Snapshot.t()

  @typedoc "A single buffer's session state."
  @type buffer_entry :: BufferEntry.t()

  @doc """
  Returns the session file path.

  With a `:project_root`, each project keeps its own file under `projects/` in the session directory, named after the project and a hash of its absolute path, so two projects with one name never share a session. Without one, the global `session.json` is used.
  """
  @spec session_file(keyword()) :: String.t()
  def session_file(opts \\ []) do
    dir =
      Keyword.get_lazy(opts, :session_dir, fn ->
        Path.join(
          System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"),
          "minga/sessions"
        )
      end)

    case Keyword.get(opts, :project_root) do
      root when is_binary(root) and root != "" -> Path.join([dir, "projects", project_file(root)])
      _none -> Path.join(dir, @session_filename)
    end
  end

  @doc "Saves a session snapshot to disk as JSON."
  @spec save(snapshot(), keyword()) :: :ok | {:error, term()}
  def save(snapshot, opts \\ []) do
    path = session_file(opts)
    dir = Path.dirname(path)
    json = snapshot |> encodable() |> JSON.encode!()

    # A unique temp name per write, so a save on quit and a periodic save never interleave in one file.
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  @doc "Marks the session as cleanly shut down."
  @spec mark_clean_shutdown(keyword()) :: :ok
  def mark_clean_shutdown(opts \\ []) do
    case load(opts) do
      {:ok, session} ->
        case save(%{session | clean_shutdown: true}, opts) do
          :ok ->
            :ok

          {:error, reason} ->
            Minga.Log.warning(:editor, "Failed to mark clean shutdown: #{inspect(reason)}")
            :ok
        end

      {:error, _} ->
        :ok
    end
  end

  @doc "Loads the session from disk."
  @spec load(keyword()) :: {:ok, snapshot()} | {:error, term()}
  def load(opts \\ []) do
    path = session_file(opts)

    case File.read(path) do
      {:ok, data} -> decode(data)
      error -> error
    end
  end

  @doc "Returns whether the last session was a clean shutdown."
  @spec clean_shutdown?(keyword()) :: boolean()
  def clean_shutdown?(opts \\ []) do
    case load(opts) do
      {:ok, %{clean_shutdown: true}} -> true
      _ -> false
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @spec decode(String.t()) :: {:ok, snapshot()} | {:error, term()}
  defp decode(data) do
    case JSON.decode(data) do
      {:ok, raw} -> Snapshot.from_map(raw)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec encodable(snapshot() | map()) :: map()
  defp encodable(%Snapshot{} = snapshot), do: Snapshot.to_map(snapshot)
  defp encodable(map) when is_map(map), do: map

  @spec project_file(String.t()) :: String.t()
  defp project_file(root) do
    root = Path.expand(root)
    hash = :sha256 |> :crypto.hash(root) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    name = root |> Path.basename() |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    "#{name}-#{hash}.json"
  end

  # ── Swap file delegates ───────────────────────────────────────────────────

  @doc "Returns the default swap directory path."
  @spec swap_dir() :: String.t()
  defdelegate swap_dir, to: Minga.Session.Swap

  @doc "Writes a swap file for the given buffer path."
  @spec write_swap(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate write_swap(path, content, opts \\ []), to: Minga.Session.Swap, as: :write

  @doc "Deletes the swap file for the given buffer path. Returns an error when filesystem cleanup fails."
  @spec delete_swap(String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate delete_swap(path, opts \\ []), to: Minga.Session.Swap, as: :delete

  # ── Swap recovery delegates ───────────────────────────────────────────────

  @typedoc "A recoverable swap file entry."
  @type swap_entry :: Minga.Session.Swap.Recovery.entry()

  @doc "Scans the swap directory for recoverable swap files."
  @spec scan_recoverable_swaps(keyword()) :: [swap_entry()]
  defdelegate scan_recoverable_swaps(opts \\ []), to: Minga.Session.Swap.Recovery, as: :scan

  @doc "Recovers content from a swap file. Returns `{:ok, original_path, content}`."
  @spec recover_swap_file(String.t()) :: {:ok, String.t(), String.t()} | {:error, term()}
  defdelegate recover_swap_file(swap_path), to: Minga.Session.Swap.Recovery, as: :recover
end
