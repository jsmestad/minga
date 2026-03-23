defmodule Minga.Buffer.EditSource do
  @moduledoc """
  Identifies who made an edit to a buffer.

  The rich source type flows through events, ghost cursors, and the edit
  timeline. The undo stack uses a simpler atom-based source (see
  `Minga.Buffer.State.edit_source`); use `to_undo_source/1` to bridge.

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
  def from_undo_source(:user), do: :user
  def from_undo_source(:agent), do: {:agent, self(), "unknown"}
  def from_undo_source(:lsp), do: {:lsp, :unknown}
  def from_undo_source(:recovery), do: :unknown
end
