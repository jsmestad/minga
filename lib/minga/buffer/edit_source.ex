defmodule Minga.Buffer.EditSource do
  @moduledoc """
  Identifies who made an edit to a buffer.

  The rich source type flows through events, ghost cursors, and the edit
  timeline. The undo history uses a simpler source; use `to_undo_source/1`
  to bridge. A Minga author key (`Minga.Buffer.Author.key/0`) is the same
  value in both, so the task and step that made an edit reach the buffer's
  edit record unchanged.

  ## Creating sources

  Always use the constructor functions instead of building raw tuples:

      EditSource.user()
      EditSource.agent(session_pid, tool_call_id)
      EditSource.minga(task_id, step)
      EditSource.lsp(:elixir_ls)
      EditSource.formatter()
      EditSource.unknown()

  Constructors validate arguments with guards (e.g. `session_id` must be a
  pid, `server_name` must be an atom). Pattern matching on the raw shapes
  is fine and encouraged; only construction should go through constructors.

  ## Source variants

  - `:user` — interactive keystroke from the human
  - `{:agent, session_id, tool_call_id}` — agent tool applying an edit
  - `{:minga, task_id, step}` — Minga's edit in a task step; see `Minga.Buffer.Author`
  - `{:lsp, server_name}` — LSP-initiated edit (code action, rename)
  - `:formatter` — format-on-save or explicit format command
  - `:unknown` — source not determined (legacy code paths during migration)
  """

  alias Minga.Buffer.Author

  require Author

  @undo_atoms [:user, :agent, :lsp, :recovery]

  @typedoc "Rich edit source for events, ghost cursors, and edit timeline."
  @type t ::
          :user
          | {:agent, session_id :: pid(), tool_call_id :: String.t()}
          | Author.key()
          | {:lsp, server_name :: atom()}
          | :formatter
          | :unknown

  @typedoc """
  Simple edit source for undo/redo attribution.

  `:agent` is an agent edit with no task attribution, made outside an admitted tool call.
  """
  @type undo_source :: :user | :agent | :lsp | :recovery | Author.key()

  @doc "Guards a value accepted as an undo source."
  defguard is_undo_source(source) when source in @undo_atoms or Author.is_key(source)

  # ── Constructors ──────────────────────────────────────────────────────

  @doc "Interactive edit from the human user."
  @spec user() :: t()
  def user, do: :user

  @doc "Edit from an agent tool call."
  @spec agent(pid(), String.t()) :: t()
  def agent(session_id, tool_call_id)
      when is_pid(session_id) and is_binary(tool_call_id) do
    {:agent, session_id, tool_call_id}
  end

  @doc "Edit by Minga in task `task_id`, made by the step `step`."
  @spec minga(Author.id(), Author.step()) :: t()
  def minga(task_id, step) when is_binary(task_id) and is_binary(step) do
    task_id
    |> Author.minga()
    |> Author.key(step)
  end

  @doc "Edit from an LSP server (code action, rename, etc.)."
  @spec lsp(atom()) :: t()
  def lsp(server_name) when is_atom(server_name) do
    {:lsp, server_name}
  end

  @doc "Edit from format-on-save or explicit format command."
  @spec formatter() :: t()
  def formatter, do: :formatter

  @doc "Source not determined (legacy code paths during migration)."
  @spec unknown() :: t()
  def unknown, do: :unknown

  # ── Undo stack bridge ─────────────────────────────────────────────────

  @doc """
  Maps a rich edit source to the simple source used by the undo stack.

  A Minga author key passes through unchanged, so the undo history records its task and step.
  """
  @spec to_undo_source(t()) :: undo_source()
  def to_undo_source(:user), do: :user
  def to_undo_source({:agent, _session_id, _tool_call_id}), do: :agent
  def to_undo_source(key) when Author.is_key(key), do: key
  def to_undo_source({:lsp, _server_name}), do: :lsp
  def to_undo_source(:formatter), do: :lsp
  def to_undo_source(:unknown), do: :user

  @doc """
  Converts a simple undo source to the rich event source.

  Used when Buffer.Process mutation functions are called without an explicit
  source parameter, preserving backward compatibility.

  A Minga author key is returned unchanged. Note: for `:agent`, the returned `session_id` is the Buffer.Process's own PID,
  not an agent session PID. The undo stack doesn't preserve the original session
  reference. Treat it as a sentinel indicating "some agent edit, origin unknown."
  """
  @spec from_undo_source(undo_source()) :: t()
  def from_undo_source(:user), do: user()
  def from_undo_source(:agent), do: agent(self(), "unknown")
  def from_undo_source(:lsp), do: lsp(:unknown)
  def from_undo_source(:recovery), do: unknown()
  def from_undo_source(key) when Author.is_key(key), do: key
end
