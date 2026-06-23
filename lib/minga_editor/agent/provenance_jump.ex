defmodule MingaEditor.Agent.ProvenanceJump do
  @moduledoc """
  A pending "jump to the turn that wrote this line" navigation.

  Created when the user presses Enter on a code-provenance popup
  (`MingaAgent.Autobiography`). It holds everything the async session-load and
  the subsequent buffer re-syncs need to land the chat cursor on the right turn
  and to get the reader back to where they started:

  * `target_message_id` — the stable chat message id to land on (the turn's
    opening user message, resolved once at request time so layout shifts during
    the multi-sync load can't move it; see `Transcript.turn_anchor_id/2`).
  * `landed?` — false until the first sync after load performs the jump. While
    false, syncs land on the target; once true, syncs leave the cursor where it
    is so re-syncs don't yank the reader back to the bottom.
  * `origin` — `{path, line}` of the source file the user jumped from, for the
    return trip. Stored as a path (not a buffer pid) so it survives the source
    buffer being closed.

  The whole struct is cleared when the user sends a new prompt (live streaming
  should resume its bottom-pinned auto-scroll).
  """

  @enforce_keys [:target_message_id]
  defstruct [:target_message_id, :origin, landed?: false]

  @type origin :: {path :: String.t(), line :: non_neg_integer()}

  @type t :: %__MODULE__{
          target_message_id: pos_integer(),
          landed?: boolean(),
          origin: origin() | nil
        }

  @doc "Creates a pending jump to `target_message_id`, remembering the origin for the return trip."
  @spec request(pos_integer(), origin() | nil) :: t()
  def request(target_message_id, origin \\ nil) when is_integer(target_message_id) do
    %__MODULE__{target_message_id: target_message_id, origin: origin}
  end

  @doc "Marks the jump as landed (the cursor has been placed on the target turn)."
  @spec mark_landed(t()) :: t()
  def mark_landed(%__MODULE__{} = jump), do: %{jump | landed?: true}

  @doc "Returns the cursor target a sync should use for this jump's current phase."
  @spec cursor_target(t()) :: {:message_id, pos_integer()} | :keep
  def cursor_target(%__MODULE__{landed?: false, target_message_id: id}), do: {:message_id, id}
  def cursor_target(%__MODULE__{landed?: true}), do: :keep
end
