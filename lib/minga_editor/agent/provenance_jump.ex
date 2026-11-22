defmodule MingaEditor.Agent.ProvenanceJump do
  @moduledoc """
  A pending "jump to the turn that wrote this line" navigation.

  Created when the user presses Enter on a code-provenance popup
  (`MingaAgent.Autobiography`). It holds everything the async session-load and
  the subsequent buffer re-syncs need to land the chat cursor on the right turn
  and to get the reader back to where they started:

  * `target`: the requested tool call, then the stable anchor message ID resolved from the replacement transcript.
  * `landed?`: false until the anchor is visible. Later updates leave the reader in control of the scroll position.
  * `origin`: `{path, line}` of the source file for the return trip. A path survives closing the source buffer.

  The whole struct is cleared when the user sends a new prompt (live streaming
  should resume its bottom-pinned auto-scroll).
  """

  @enforce_keys [:target]
  defstruct [:target, :origin, landed?: false]

  @type origin :: {path :: String.t(), line :: non_neg_integer()}
  @type target :: {:tool_call_id, String.t()} | {:message_id, pos_integer()}

  @type t :: %__MODULE__{
          target: target(),
          landed?: boolean(),
          origin: origin() | nil
        }

  @doc "Requests a jump, remembering the source location for the return trip."
  @spec request(target(), origin() | nil) :: t()
  def request(target, origin \\ nil), do: %__MODULE__{target: target, origin: origin}

  @doc "Binds a tool occurrence to the anchor in the newly installed transcript."
  @spec resolve(t(), pos_integer()) :: t()
  def resolve(%__MODULE__{target: {:tool_call_id, _id}} = jump, id),
    do: %{jump | target: {:message_id, id}}

  @doc "Marks the jump as landed (the cursor has been placed on the target turn)."
  @spec mark_landed(t()) :: t()
  def mark_landed(%__MODULE__{} = jump), do: %{jump | landed?: true}

  @doc "Returns the cursor target a sync should use for this jump's current phase."
  @spec cursor_target(t()) :: target() | :keep
  def cursor_target(%__MODULE__{landed?: false, target: target}), do: target
  def cursor_target(%__MODULE__{landed?: true}), do: :keep
end
