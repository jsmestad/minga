defmodule Minga.Editor.Window.Content do
  @moduledoc """
  Polymorphic content reference for window panes.

  A window can host any content type: a file buffer, an agent chat session,
  a terminal, etc. This module defines the tagged union that replaces the
  old `buffer: pid()` field on `Window.t()`.

  ## Why a tagged tuple instead of a protocol?

  Window content references are stored in the window tree, serialized for
  tab save/restore, and pattern-matched in the render pipeline. A simple
  tagged tuple (`{:buffer, pid}`, `{:agent, session_ref}`) is easier to
  serialize, pattern-match, and debug than a protocol struct. The
  NavigableContent protocol handles the behavioral polymorphism; this
  module handles the identity/reference polymorphism.

  ## Content types

  | Tag | Reference | NavigableContent? | Editable? |
  |-----|-----------|-------------------|-----------|
  | `:buffer` | `pid()` (Buffer.Server) | Yes (via BufferSnapshot) | Yes |
  | `:agent_chat` | `pid()` (Agent.Session) | Yes (future, Phase E) | No |
  | `:agent_prompt` | `pid()` (Buffer.Server) | Yes (via BufferSnapshot) | Yes |
  | `:terminal` | `pid()` (future, #122) | Yes (future) | No |
  | `:browser` | `reference()` (future, #305) | Yes (future) | No |

  Only `:buffer` is implemented today. Other tags are documented here to
  show the design direction and will be added as their features land.
  """

  @typedoc """
  A content reference identifying what a window pane displays.

  Currently only `:buffer` is used. Other variants will be added as
  their features are implemented.
  """
  @type t ::
          {:buffer, pid()}

  # Future variants (uncomment as implemented):
  # | {:agent_chat, pid()}
  # | {:agent_prompt, pid()}
  # | {:terminal, pid()}

  @doc "Creates a buffer content reference."
  @spec buffer(pid()) :: t()
  def buffer(pid) when is_pid(pid), do: {:buffer, pid}

  @doc "Returns the buffer pid if this is a buffer content reference, nil otherwise."
  @spec buffer_pid(t()) :: pid() | nil
  def buffer_pid({:buffer, pid}), do: pid

  @doc "Returns true if this content reference is a file buffer."
  @spec buffer?(t()) :: boolean()
  def buffer?({:buffer, _pid}), do: true
end
