defmodule MingaEditor.Input.OperationCancellation do
  @moduledoc "Routes Escape to the authoritative effect scheduler after higher interactive surfaces pass."

  @behaviour MingaEditor.Input.Handler

  alias MingaEditor.EffectScheduler
  alias MingaEditor.State.Operation
  alias MingaEditor.State.OperationFeedback

  @type state :: MingaEditor.Input.Handler.handler_state()

  @key_escape 27

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(state, @key_escape, _modifiers) do
    case OperationFeedback.selected_from(state) do
      %Operation{id: id, cancelable?: true} -> cancel(state, id)
      _operation -> {:passthrough, state}
    end
  end

  def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}

  @spec cancel(state(), Operation.id()) :: MingaEditor.Input.Handler.result()
  defp cancel(state, operation_id) do
    case EffectScheduler.cancel_operation(state.effect_scheduler, operation_id) do
      :ok ->
        {:handled, state}

      {:error, :not_found} ->
        Minga.Log.warning(
          :editor,
          "Operation cancellation could not find active operation #{operation_id}"
        )

        {:handled, state}

      {:error, :scheduler_unavailable} ->
        Minga.Log.error(
          :editor,
          "Operation cancellation failed because the effect scheduler is unavailable (operation #{operation_id})"
        )

        {:handled, state}
    end
  end
end
