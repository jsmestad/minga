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
  serialize, pattern-match, and debug than a protocol struct. The
  NavigableContent protocol handles the behavioral polymorphism; this
  module handles the identity/reference polymorphism.

  ## Content types

  | Tag | Reference | NavigableContent? | Editable? |
  |-----|-----------|-------------------|-----------|
  | `:buffer` | `pid()` (Buffer.Server) | Yes (via BufferSnapshot) | Yes |
  | `:agent_chat` | `pid()` (Agent.Session) | Yes | No |
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
          | {:agent_chat, pid()}

  @doc "Creates a buffer content reference."
  @spec buffer(pid()) :: t()
  def buffer(pid) when is_pid(pid), do: {:buffer, pid}

  @doc "Creates an agent chat content reference. The pid is the agent's `*Agent*` Buffer.Server."
  @spec agent_chat(pid()) :: t()
  def agent_chat(pid) when is_pid(pid), do: {:agent_chat, pid}

  @doc "Returns the buffer pid if this is a buffer content reference, nil otherwise."
  @spec buffer_pid(t()) :: pid() | nil
  def buffer_pid({:buffer, pid}), do: pid
  def buffer_pid({:agent_chat, _pid}), do: nil

  @doc """
  Returns the underlying pid for any content type.

  For `:buffer`, this is the Buffer.Server pid. For `:agent_chat`, this
  is the agent's `*Agent*` Buffer.Server pid (used for cursor/scroll).
  """
  @spec pid(t()) :: pid()
  def pid({:buffer, p}), do: p
  def pid({:agent_chat, p}), do: p

  @doc "Returns true if this content reference is a file buffer."
  @spec buffer?(t()) :: boolean()
  def buffer?({:buffer, _pid}), do: true
  def buffer?({:agent_chat, _pid}), do: false

  @doc "Returns true if this content reference is an agent chat."
  @spec agent_chat?(t()) :: boolean()
  def agent_chat?({:agent_chat, _pid}), do: true
  def agent_chat?({:buffer, _pid}), do: false

  @doc "Returns true if the content is editable (supports insert mode)."
  @spec editable?(t()) :: boolean()
  def editable?({:buffer, _pid}), do: true
  def editable?({:agent_chat, _pid}), do: false
end
