defmodule MingaEditor.InlineOverlay.Events do
  @moduledoc """
  Shared event-routing framework for inline overlays (ask and edit).

  Both variants route ephemeral agent session events into per-buffer
  overlay state in the same way: look up the overlay that owns a session
  pid, apply a variant-specific transition, and write it back. This
  module owns that shared plumbing (`session?/3`, `handle_event/4`,
  `handle_prompt_result/4`, and the session lookup/update). The
  variant-specific transitions (`apply_event`, the failure message) stay
  in the adapters and are passed in as callbacks.

  The `spec` map carries the store accessor, focused replacement operation,
  and the `session?` predicate over the variant's state store.
  """

  alias MingaAgent.EphemeralSession
  alias MingaEditor.State, as: EditorState

  @typedoc """
  Variant behaviour for an inline overlay event router.

  * `:store` reads the variant's per-buffer overlay store off editor state.
  * `:replace` writes one transitioned overlay through its focused owner.
  * `:session?` is true when a session pid belongs to this variant's store.
  """
  @type spec :: %{
          store: (EditorState.t() -> %{pid() => struct()} | nil),
          replace: (EditorState.t(), struct() -> EditorState.t()),
          session?: (%{pid() => struct()}, pid() -> boolean())
        }

  @doc "Returns true when a session belongs to an overlay of this variant."
  @spec session?(EditorState.t(), pid(), spec()) :: boolean()
  def session?(state, session_pid, spec) when is_pid(session_pid) do
    case spec.store.(state) do
      store when is_map(store) -> spec.session?.(store, session_pid)
      _ -> false
    end
  end

  @doc """
  Handles an agent event for the overlay that owns `session_pid`.

  `apply_event` is the variant transition `(overlay, session_pid, event -> overlay)`.
  """
  @spec handle_event(EditorState.t(), pid(), term(), spec(), (struct(), pid(), term() -> struct())) ::
          EditorState.t()
  def handle_event(state, session_pid, event, spec, apply_event) when is_pid(session_pid) do
    update_for_session(state, session_pid, spec, fn overlay ->
      apply_event.(overlay, session_pid, event)
    end)
  end

  @doc """
  Handles the async result of sending the overlay's prompt.

  On `{:error, reason}` the session is stopped and the overlay is failed
  via `fail` (`(overlay, reason -> overlay)`).
  """
  @spec handle_prompt_result(EditorState.t(), pid(), term(), spec(), (struct(), term() ->
                                                                        struct())) ::
          EditorState.t()
  def handle_prompt_result(state, _session_pid, :ok, _spec, _fail), do: state

  def handle_prompt_result(state, session_pid, {:error, reason}, spec, fail) do
    EphemeralSession.stop(session_pid)
    update_for_session(state, session_pid, spec, fn overlay -> fail.(overlay, reason) end)
  end

  @doc """
  Looks up the overlay that owns `session_pid`, applies `fun`, writes it back.

  Returns the state unchanged when no overlay owns the session.
  """
  @spec update_for_session(EditorState.t(), pid(), spec(), (struct() -> struct())) ::
          EditorState.t()
  def update_for_session(state, session_pid, spec, fun) do
    case spec.store.(state) do
      store when is_map(store) ->
        {_buffer_pid, overlay} = find_by_session(store, session_pid)

        if overlay, do: spec.replace.(state, fun.(overlay)), else: state

      _ ->
        state
    end
  end

  @spec find_by_session(%{pid() => struct()}, pid()) :: {pid() | nil, struct() | nil}
  defp find_by_session(store, session_pid) do
    Enum.find(store, {nil, nil}, fn {_buffer_pid, overlay} ->
      overlay.session_pid == session_pid
    end)
  end
end
