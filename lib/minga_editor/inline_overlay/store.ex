defmodule MingaEditor.InlineOverlay.Store do
  @moduledoc """
  Shared per-buffer store for inline overlays (ask and edit).

  Both variants key their ephemeral overlays by `buffer_pid` and track an optional session through a leaf-owner query. The lookup/insert/dismiss/session plumbing only touches those facts, so it lives here once and is reused by both `MingaEditor.State.InlineAsk` and `MingaEditor.State.InlineEdit` rather than being copied per variant.
  """

  @typedoc "An overlay struct carrying `:buffer_pid`."
  @type overlay :: %{
          :__struct__ => module(),
          :buffer_pid => pid(),
          optional(atom()) => term()
        }

  @typedoc "A per-buffer overlay store."
  @type store :: %{pid() => overlay()}
  @type session_pid_fun :: (overlay() -> pid() | nil)

  @doc "Returns the active overlay for a buffer, or `nil`."
  @spec active(store(), pid() | nil, module()) :: overlay() | nil
  def active(store, buffer_pid, module) when is_map(store) and is_pid(buffer_pid) do
    case Map.get(store, buffer_pid) do
      %{__struct__: ^module} = overlay -> overlay
      _other -> nil
    end
  end

  def active(_store, _buffer_pid, _module), do: nil

  @doc "Returns true when the given session pid belongs to an overlay in this store."
  @spec session?(store(), pid(), session_pid_fun()) :: boolean()
  def session?(store, session_pid, session_pid_fun)
      when is_map(store) and is_pid(session_pid) and is_function(session_pid_fun, 1) do
    Enum.any?(store, fn {_buffer, overlay} -> session_pid_fun.(overlay) == session_pid end)
  end

  @doc "Opens or replaces an overlay for its buffer."
  @spec put(store(), overlay(), module()) :: store()
  def put(store, %{__struct__: module, buffer_pid: buffer_pid} = overlay, module)
      when is_map(store) and is_pid(buffer_pid), do: Map.put(store, buffer_pid, overlay)

  def put(store, _overlay, _module) when is_map(store), do: store

  @doc """
  Dismisses the overlay for a buffer.

  Returns `{store, session_pid}` where `session_pid` is the dismissed overlay's session pid (or `nil` when there was no overlay), so callers can stop the session.
  """
  @spec dismiss(store(), pid() | nil, session_pid_fun()) :: {store(), pid() | nil}
  def dismiss(store, buffer_pid, session_pid_fun)
      when is_map(store) and is_pid(buffer_pid) and is_function(session_pid_fun, 1) do
    {overlay, store} = Map.pop(store, buffer_pid)
    {store, if(overlay, do: session_pid_fun.(overlay), else: nil)}
  end

  def dismiss(store, _buffer_pid, _session_pid_fun), do: {store, nil}
end
