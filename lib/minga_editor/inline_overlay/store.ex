defmodule MingaEditor.InlineOverlay.Store do
  @moduledoc """
  Shared per-buffer store for inline overlays (ask and edit).

  Both variants key their ephemeral overlays by `buffer_pid` and track an
  optional `session_pid`. The lookup/insert/dismiss/session plumbing only
  touches those two fields, so it lives here once and is reused by both
  `MingaEditor.State.InlineAsk` and `MingaEditor.State.InlineEdit` rather
  than being copied per variant.

  An overlay is any struct carrying `:buffer_pid` and `:session_pid`. The
  variant struct modules own their own fields and transitions; this module
  owns only the store mechanics.
  """

  @typedoc "An overlay struct carrying `:buffer_pid` and `:session_pid`."
  @type overlay :: %{
          :__struct__ => module(),
          :buffer_pid => pid(),
          :session_pid => pid() | nil,
          optional(atom()) => term()
        }

  @typedoc "A per-buffer overlay store."
  @type store :: %{pid() => overlay()}

  @doc "Returns the active overlay for a buffer, or `nil`."
  @spec active(store(), pid() | nil) :: overlay() | nil
  def active(store, buffer_pid) when is_map(store) and is_pid(buffer_pid),
    do: Map.get(store, buffer_pid)

  def active(_store, _buffer_pid), do: nil

  @doc "Returns true when the given session pid belongs to an overlay in this store."
  @spec session?(store(), pid()) :: boolean()
  def session?(store, session_pid) when is_map(store) and is_pid(session_pid) do
    Enum.any?(store, fn {_buffer, overlay} -> overlay.session_pid == session_pid end)
  end

  @doc "Opens or replaces an overlay for its buffer."
  @spec put(store(), overlay()) :: store()
  def put(store, %{buffer_pid: buffer_pid} = overlay) when is_map(store) do
    Map.put(store, buffer_pid, overlay)
  end

  @doc """
  Dismisses the overlay for a buffer.

  Returns `{store, session_pid}` where `session_pid` is the dismissed
  overlay's session pid (or `nil` when there was no overlay), so callers
  can stop the session.
  """
  @spec dismiss(store(), pid() | nil) :: {store(), pid() | nil}
  def dismiss(store, buffer_pid) when is_map(store) and is_pid(buffer_pid) do
    {overlay, store} = Map.pop(store, buffer_pid)
    {store, if(overlay, do: overlay.session_pid, else: nil)}
  end

  def dismiss(store, _buffer_pid), do: {store, nil}
end
