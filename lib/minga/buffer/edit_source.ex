defmodule Minga.Buffer.EditSource do
  @moduledoc """
  Identifies who made an edit to a buffer.

  The rich source type flows through events, ghost cursors, and the edit
  timeline. The undo stack uses a simpler atom-based source (see
  `Minga.Buffer.State.edit_source`); use `to_undo_source/1` to bridge.

  ## Creating sources

  Always use the constructor functions instead of building raw tuples:

      EditSource.user()
      EditSource.agent(session_pid, tool_call_id)
      EditSource.lsp(:elixir_ls)
      EditSource.formatter()
      EditSource.unknown()

  Constructors validate arguments with guards (e.g. `session_id` must be a
  pid, `server_name` must be an atom). Pattern matching on the raw shapes
  is fine and encouraged; only construction should go through constructors.

  ## Source variants

  - `:user` — interactive keystroke from the human
  - `{:agent, session_id, tool_call_id}` — agent tool applying an edit
  - `{:lsp, server_name}` — LSP-initiated edit (code action, rename)
  - `:formatter` — format-on-save or explicit format command
  - `:unknown` — source not determined (legacy code paths during migration)
  """

  @typedoc "Rich edit source for events, ghost cursors, and edit timeline."
  @type t ::
          :user
          | {:agent, session_id :: pid(), tool_call_id :: String.t()}
          | {:lsp, server_name :: atom()}
          | :formatter
          | :unknown

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
  Maps a rich edit source to the simple atom used by the undo stack.

  This bridge exists so the undo system can continue using atom-based
  guards until Provenance Undo (#1108) migrates it to the rich type.
  """
  @spec to_undo_source(t()) :: Minga.Buffer.State.edit_source()
  def to_undo_source(:user), do: :user
  def to_undo_source({:agent, _session_id, _tool_call_id}), do: :agent
  def to_undo_source({:lsp, _server_name}), do: :lsp
  def to_undo_source(:formatter), do: :lsp
  def to_undo_source(:unknown), do: :user

  @doc """
  Converts a simple undo source atom to the rich event source.

  Used when Buffer.Server mutation functions are called without an explicit
  source parameter, preserving backward compatibility.

  Note: for `:agent`, the returned `session_id` is the Buffer.Server's own PID,
  not an agent session PID. The undo stack doesn't preserve the original session
  reference. Treat it as a sentinel indicating "some agent edit, origin unknown."
  """
  @spec from_undo_source(Minga.Buffer.State.edit_source()) :: t()
  def from_undo_source(:user), do: user()
  def from_undo_source(:agent), do: agent(self(), "unknown")
  def from_undo_source(:lsp), do: lsp(:unknown)
  def from_undo_source(:recovery), do: unknown()
end
