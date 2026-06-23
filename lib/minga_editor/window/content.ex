defmodule MingaEditor.Window.Content do
  @moduledoc """
  Polymorphic content reference for window panes.

  A window can host any content type: a file buffer, an agent chat session,
  a terminal, etc. This module defines the tagged union that replaces the
  old `buffer: pid()` field on `Window.t()`.

  ## Why a tagged tuple instead of a protocol?

  Window content references are stored in the window tree, serialized for
  tab save/restore, and pattern-matched in the render pipeline. A simple
  tagged tuple (`{:buffer, pid}`, `{:agent, session_ref}`) is easier to
  serialize, pattern-match, and debug than a protocol struct. This module handles only identity/reference polymorphism.

  ## Content types

  | Tag | Reference | Editable? |
  |-----|-----------|-----------|
  | `:buffer` | `pid()` (Buffer.Process) | Yes |
  | `:agent_chat` | `:semantic` | No |

  Only these tags are implemented today. Add future content types when they ship.
  """

  @typedoc """
  A content reference identifying what a window pane displays.

  Currently only `:buffer` is used. Other variants will be added as
  their features are implemented.
  """
  @type t ::
          {:buffer, pid()}
          | {:agent_chat, :semantic}

  @doc "Creates a buffer content reference."
  @spec buffer(pid()) :: t()
  def buffer(pid) when is_pid(pid), do: {:buffer, pid}

  @doc "Creates a semantic agent chat content reference."
  @spec agent_chat() :: t()
  def agent_chat, do: {:agent_chat, :semantic}

  @doc "Returns the buffer pid if this is a buffer content reference, nil otherwise."
  @spec buffer_pid(t()) :: pid() | nil
  def buffer_pid({:buffer, pid}), do: pid
  def buffer_pid({:agent_chat, :semantic}), do: nil

  @doc """
  Returns the underlying pid for any content type.

  For `:buffer`, this is the Buffer.Process pid. Semantic agent chat panes have no underlying buffer pid.
  """
  @spec pid(t()) :: pid() | nil
  def pid({:buffer, p}), do: p
  def pid({:agent_chat, :semantic}), do: nil

  @doc "Returns true if this content reference is a file buffer."
  @spec buffer?(t()) :: boolean()
  def buffer?({:buffer, _pid}), do: true
  def buffer?({:agent_chat, :semantic}), do: false

  @doc "Returns true if this content reference is an agent chat."
  @spec agent_chat?(t()) :: boolean()
  def agent_chat?({:agent_chat, :semantic}), do: true
  def agent_chat?({:buffer, _pid}), do: false

  @doc "Returns true if the content is editable (supports insert mode)."
  @spec editable?(t()) :: boolean()
  def editable?({:buffer, _pid}), do: true
  def editable?({:agent_chat, :semantic}), do: false
end
