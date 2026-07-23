defmodule MingaEditor.InlineOverlay.Events do
  @moduledoc """
  Shared event-routing framework for inline overlays (ask and edit).

  Both variants route ephemeral agent session events into per-buffer overlay state in the same way: look up the overlay that owns a session pid, apply a variant-specific transition, and write it back. This module owns that shared plumbing (`session?/3`, `handle_event/4`, `handle_prompt_result/4`, and the session lookup/update). The variant-specific transitions (`apply_event`, the failure message) stay in the adapters and are passed in as callbacks.
  """

  alias MingaAgent.EphemeralSession
  alias MingaEditor.State, as: EditorState

  @typedoc """
  Variant behaviour for an inline overlay event router.

  * `:store` reads the variant's per-buffer overlay store off editor state.
  * `:replace` writes one transitioned overlay through its focused owner.
  * `:session?` is true when a session pid belongs to this variant's store.
  * `:session_pid` reads the current owner session pid from this variant.
  """
  @type spec :: %{
          store: (EditorState.t() -> %{pid() => struct()} | nil),
          replace: (EditorState.t(), struct() -> EditorState.t()),
          session?: (%{pid() => struct()}, pid() -> boolean()),
          session_pid: (struct() -> pid() | nil)
        }

  @doc "Returns true when a session belongs to an overlay of this variant."
  @spec session?(EditorState.t(), pid(), spec()) :: boolean()
  def session?(state, session_pid, spec) when is_pid(session_pid) do
    case spec.store.(state) do
      store when is_map(store) -> spec.session?.(store, session_pid)
      _ -> false
    end
  end

  @doc "Handles an agent event for the overlay that owns `session_pid`."
  @spec handle_event(EditorState.t(), pid(), term(), spec(), (struct(), pid(), term() -> struct())) ::
          EditorState.t()
  def handle_event(state, session_pid, event, spec, apply_event) when is_pid(session_pid) do
    update_for_session(state, session_pid, spec, fn overlay ->
      apply_event.(overlay, session_pid, event)
    end)
  end

  @doc "Handles the async result of sending the overlay's prompt."
  @spec handle_prompt_result(EditorState.t(), pid(), term(), spec(), (struct(), term() ->
                                                                        struct())) ::
          EditorState.t()
  def handle_prompt_result(state, _session_pid, :ok, _spec, _fail), do: state

  def handle_prompt_result(state, session_pid, {:error, reason}, spec, fail) do
    EphemeralSession.stop(session_pid)
    update_for_session(state, session_pid, spec, fn overlay -> fail.(overlay, reason) end)
  end

  @doc "Looks up the overlay that owns `session_pid`, applies `fun`, and writes it back."
  @spec update_for_session(EditorState.t(), pid(), spec(), (struct() -> struct())) ::
          EditorState.t()
  def update_for_session(state, session_pid, spec, fun) do
    case spec.store.(state) do
      store when is_map(store) ->
        case find_by_session(store, session_pid, spec.session_pid) do
          {_buffer_pid, overlay} -> spec.replace.(state, fun.(overlay))
          nil -> state
        end

      _ ->
        state
    end
  end

  @spec find_by_session(%{pid() => struct()}, pid(), (struct() -> pid() | nil)) ::
          {pid(), struct()} | nil
  defp find_by_session(store, session_pid, session_pid_fun) do
    Enum.find(store, fn {_buffer_pid, overlay} -> session_pid_fun.(overlay) == session_pid end)
  end
end
