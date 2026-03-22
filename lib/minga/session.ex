defmodule Minga.Session do
  @moduledoc """
  Session state persistence for crash recovery.

  Periodically saves the list of open files, cursor positions, scroll
  positions, and active buffer to a JSON file. On next launch, the
  session is restored: files are reopened and cursors are repositioned.

  The session file includes a `version` field for forward compatibility.
  Old session files that lack newer fields get defaults when loaded.

  ## Clean shutdown detection

  A `clean_shutdown` flag is set in the session file on orderly exit.
  On next launch, if the flag is missing or false, Minga knows the
  previous session crashed and shows "Restored from previous session"
  in `*Messages*`.
  """

  alias Minga.Buffer

  @default_session_dir Path.expand("~/.local/share/minga/sessions")
  @session_filename "session.json"
  @current_version 1

  @typedoc "A snapshot of the current editor session."
  @type snapshot :: %{
          version: pos_integer(),
          buffers: [buffer_entry()],
          active_file: String.t() | nil,
          clean_shutdown: boolean()
        }

  @typedoc "A single buffer's session state."
  @type buffer_entry :: %{
          file: String.t(),
          cursor_line: non_neg_integer(),
          cursor_col: non_neg_integer()
        }

  @doc "Returns the session file path."
  @spec session_file(keyword()) :: String.t()
  def session_file(opts \\ []) do
    dir = Keyword.get(opts, :session_dir, @default_session_dir)
    Path.join(dir, @session_filename)
  end

  @doc """
  Builds a session snapshot from the Editor's state.

  Queries each open buffer for its file path and cursor position.
  Only includes file-backed buffers (not scratch, nofile, or log buffers).
  """
  @spec snapshot(Minga.Editor.State.t()) :: snapshot()
  def snapshot(editor_state) do
    buffers =
      editor_state.buffers.list
      |> Enum.flat_map(fn pid ->
        file_path = Buffer.Server.file_path(pid)

        case file_path do
          nil ->
            []

          path ->
            {line, col} = get_cursor(pid)
            [%{file: path, cursor_line: line, cursor_col: col}]
        end
      end)

    active_file =
      case editor_state.buffers.active do
        nil -> nil
        pid -> Buffer.Server.file_path(pid)
      end

    %{
      version: @current_version,
      buffers: buffers,
      active_file: active_file,
      clean_shutdown: false
    }
  end

  @doc "Saves a session snapshot to disk as JSON."
  @spec save(snapshot(), keyword()) :: :ok | {:error, term()}
  def save(snapshot, opts \\ []) do
    path = session_file(opts)
    dir = Path.dirname(path)
    json = JSON.encode!(snapshot)
    tmp = path <> ".tmp"

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

  @spec get_cursor(pid()) :: {non_neg_integer(), non_neg_integer()}
  defp get_cursor(pid) do
    Buffer.Server.cursor(pid)
  catch
    # Race window: buffer may exit between snapshot iteration and this call.
    :exit, _ -> {0, 0}
  end

  @spec decode(String.t()) :: {:ok, snapshot()} | {:error, term()}
  defp decode(data) do
    case JSON.decode(data) do
      {:ok, %{"buffers" => buffers} = raw} ->
        entries =
          Enum.map(buffers, fn b ->
            %{
              file: b["file"],
              cursor_line: b["cursor_line"] || 0,
              cursor_col: b["cursor_col"] || 0
            }
          end)

        {:ok,
         %{
           version: raw["version"] || 1,
           buffers: entries,
           active_file: raw["active_file"],
           clean_shutdown: raw["clean_shutdown"] == true
         }}

      {:ok, _} ->
        {:error, :invalid_format}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
