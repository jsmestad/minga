defmodule MingaEditor.Extension.EventWorkflow do
  @moduledoc """
  Admits extension editor events to the generation-owned effect scheduler.

  The Editor only constructs bounded typed requests here. Extension code runs in
  scheduler workers and correlated outcomes return through the normal effect path.
  """

  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CodeLease
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Extension.EventEffect
  alias MingaEditor.Extension.EventHandler
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState

  @type unload_context :: %{
          required(:token) => CodeLease.unload_token(),
          optional(:callback_registry) => GenServer.server(),
          optional(:callback_admission) => GenServer.server()
        }

  @doc "Schedules an ordinary extension editor event without waiting in the Editor."
  @spec dispatch(EditorState.t(), EventHandler.event(), keyword()) :: EditorState.t()
  def dispatch(%EditorState{} = state, event, opts \\ []) do
    schedule(state, EventEffect.request(state, event, opts))
  end

  @doc "Schedules token-authorized unload callbacks and defers the caller reply."
  @spec dispatch_unload(
          EditorState.t(),
          CallbackInvoker.source(),
          unload_context(),
          {pid(), term()}
        ) :: {:ok, EditorState.t()} | {:error, term(), EditorState.t()}
  def dispatch_unload(%EditorState{} = state, source, context, reply_to) do
    token = Map.fetch!(context, :token)

    opts =
      [
        callback_registry: Map.get(context, :callback_registry),
        callback_admission: Map.get(context, :callback_admission)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    request = EventEffect.unload_request(state, source, token, reply_to, opts)

    case admit(state, request) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec schedule(EditorState.t(), MingaEditor.Effect.Request.t()) :: EditorState.t()
  defp schedule(%EditorState{} = state, %MingaEditor.Effect.Request{} = request) do
    case admit(state, request) do
      :ok ->
        state

      {:error, reason} ->
        event = request.effect.event

        Minga.Log.warning(
          :editor,
          "Extension editor event not scheduled event=#{inspect(event)} reason=#{inspect(reason)}"
        )

        admission_failure(state, event, reason)
    end
  end

  @spec admission_failure(EditorState.t(), EventHandler.event(), term()) :: EditorState.t()
  defp admission_failure(state, {:editor_action, :open_git_diff_for_path, _arguments}, reason),
    do: NoticeWorkflow.publish(state, "Git diff not scheduled: #{inspect(reason)}")

  defp admission_failure(state, {:editor_action, :execute_git_command, _command}, reason),
    do: NoticeWorkflow.publish(state, "Git command not scheduled: #{inspect(reason)}")

  defp admission_failure(state, _event, _reason), do: state

  @spec admit(EditorState.t(), MingaEditor.Effect.Request.t()) :: :ok | {:error, term()}
  defp admit(%EditorState{effect_scheduler: nil}, _request), do: {:error, :scheduler_unavailable}

  defp admit(%EditorState{} = state, request) do
    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _request_id, _disposition} -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end
end
