defmodule MingaEditor.Agent.QueuedInputEdit do
  @moduledoc "Edits one saved queue entry in an ordinary multiline buffer, separate from the composer."
  @behaviour MingaEditor.Effect

  alias Minga.Buffer
  alias MingaAgent.Session.QueuedInputSummary
  alias MingaEditor.Agent.QueueSurface
  alias MingaEditor.Agent.QueueWorkflow
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Effect.{Outcome, Policy, Request}
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State
  alias MingaEditor.State.Interaction

  @typep origin :: MingaEditor.Agent.PromptInput.submission_owner()
  @typep identity :: QueuedInputSummary.identity()
  @typep operation :: :read | {:save, String.t()}
  @typep request :: (identity(), operation() -> {:ok, String.t()} | :ok | {:error, term()})
  @type edit ::
          {:loading, reference(), non_neg_integer() | nil}
          | {:open, pid(), origin(), identity(), request()}
          | {:saving, reference(), pid(), origin(), identity(), request()}

  @enforce_keys [:ref, :origin, :identity, :operation, :request]
  defstruct [:ref, :origin, :identity, :operation, :request, :buffer_version]

  @type t :: %__MODULE__{
          ref: reference(),
          origin: origin(),
          identity: identity(),
          operation: operation(),
          request: request(),
          buffer_version: non_neg_integer() | nil
        }

  @doc "Opens the exact unabridged input for editing off the Editor process."
  @spec open(State.t(), origin(), identity(), request()) :: State.t()
  def open(state, origin, identity, request) do
    case state.interaction.queued_input_edit do
      {:loading, _ref, _tab_id} ->
        report(state, "A queued input is already loading.")

      {:open, buffer, _, _, _} ->
        open_if_closed(state, buffer, origin, identity, request)

      {:saving, _, _, _, _, _} ->
        report(state, "Wait for the current queued edit to finish saving.")

      nil ->
        load(state, origin, identity, request)
    end
  end

  @doc "Protects unsaved text and in-flight saves when closing the exact scratch tab."
  @spec close_refusal(State.t(), pid() | nil) :: String.t() | nil
  def close_refusal(
        %State{interaction: %{queued_input_edit: {:open, buffer, _, _, _}}},
        buffer
      ) do
    if Buffer.dirty?(buffer), do: "Queued input has unsaved edits. Save it or use :q! to discard."
  catch
    :exit, {:noproc, _} -> nil
  end

  def close_refusal(
        %State{interaction: %{queued_input_edit: {:saving, _, buffer, _, _, _}}},
        buffer
      ),
      do: "Wait for the queued input save to finish before closing."

  def close_refusal(_state, _buffer), do: nil

  @doc "Retires the exact scratch buffer after its tab has closed."
  @spec retire_closed_buffer(State.t(), pid() | nil) :: State.t()
  def retire_closed_buffer(
        %State{interaction: %{queued_input_edit: {:open, buffer, _, _, _}}} = state,
        buffer
      ),
      do: retire_buffer(state, buffer)

  def retire_closed_buffer(
        %State{interaction: %{queued_input_edit: {:saving, _, buffer, _, _, _}}} = state,
        buffer
      ),
      do: retire_buffer(state, buffer)

  def retire_closed_buffer(state, _buffer), do: state

  @spec retire_buffer(State.t(), pid()) :: State.t()
  defp retire_buffer(state, buffer) do
    GenServer.stop(buffer, :normal)
    install(state, nil)
  catch
    :exit, {:noproc, _} -> install(state, nil)
  end

  @doc "Handles ordinary Save only for the exact queued-input buffer."
  @spec save_if_active(State.t()) :: {:handled, State.t()} | :not_editing_queued_input
  def save_if_active(
        %State{
          workspace: %{buffers: %{active: buffer}},
          interaction: %{queued_input_edit: {:open, buffer, origin, identity, request}}
        } = state
      ) do
    {:handled, save_text(state, buffer, origin, identity, request)}
  end

  def save_if_active(
        %State{
          workspace: %{buffers: %{active: buffer}},
          interaction: %{queued_input_edit: {:saving, _, buffer, _, _, _}}
        } = state
      ),
      do: {:handled, report(state, "Wait for the current queued edit to finish saving.")}

  def save_if_active(_state), do: :not_editing_queued_input

  @spec save_text(State.t(), pid(), origin(), identity(), request()) :: State.t()
  defp save_text(state, buffer, origin, identity, request) do
    {text, version} = Buffer.content_with_version(buffer)

    if String.trim(text) == "" do
      report(state, "Use Withdraw to remove an input. The queue was not changed.")
    else
      effect = %__MODULE__{
        ref: make_ref(),
        origin: origin,
        identity: identity,
        operation: {:save, text},
        request: request,
        buffer_version: version
      }

      case schedule(state, effect) do
        :ok ->
          state
          |> install({:saving, effect.ref, buffer, origin, identity, request})
          |> report("Saving queued input…")

        :error ->
          report(state, "Could not start saving the queued edit.")
      end
    end
  catch
    :exit, _reason -> report(state, "The queued editing buffer is no longer available.")
  end

  @impl true
  @spec run(t()) :: {:ok, String.t() | :saved} | {:error, term()}
  def run(%__MODULE__{identity: identity, operation: operation, request: request}) do
    case request.(identity, operation) do
      :ok -> {:ok, :saved}
      result -> result
    end
  end

  @impl true
  @spec apply(State.t(), Outcome.t()) :: {State.t(), Outcome.t()}
  def apply(state, %Outcome{value: {status, value}, request: %{effect: effect}} = outcome)
      when status in [:completed, :failed, :canceled, :stale] do
    {settle(state, effect, {status, value}), outcome}
  end

  def apply(state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {status, _}}),
    do: status in [:completed, :failed, :canceled, :stale]

  def render?(%Outcome{}), do: false

  @spec open_if_closed(State.t(), pid(), origin(), identity(), request()) :: State.t()
  defp open_if_closed(state, buffer, origin, identity, request) do
    if Process.alive?(buffer),
      do:
        report(state, "Return to the open queued input buffer, or close it to edit another item."),
      else: load(state, origin, identity, request)
  end

  @spec load(State.t(), origin(), identity(), request()) :: State.t()
  defp load(state, origin, identity, request) do
    effect = %__MODULE__{
      ref: make_ref(),
      origin: origin,
      identity: identity,
      operation: :read,
      request: request
    }

    case schedule(state, effect) do
      :ok ->
        queue = QueueSurface.begin_edit(state.workspace.agent_ui.queue, effect.ref)

        state
        |> install({:loading, effect.ref, active_tab_id(state)})
        |> QueueWorkflow.install(queue)
        |> report("Loading queued input…")

      :error ->
        report(state, "Could not load queued input.")
    end
  end

  @spec schedule(State.t(), t()) :: :ok | :error
  defp schedule(%State{effect_scheduler: nil}, _effect), do: :error

  defp schedule(state, effect) do
    request =
      Request.new(effect, {:queued_input_edit, effect.origin}, Policy.fifo(0), timeout_ms: 35_000)

    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _, _} -> :ok
      {:error, _} -> :error
    end
  catch
    :exit, _ -> :error
  end

  @spec settle(State.t(), t(), {atom(), term()}) :: State.t()
  defp settle(
         %State{interaction: %{queued_input_edit: {:loading, ref, tab_id}}} = state,
         %__MODULE__{ref: ref} = effect,
         result
       ) do
    state = install(state, nil)

    case QueueSurface.finish_edit(state.workspace.agent_ui.queue, ref) do
      {:current, queue} ->
        state = QueueWorkflow.install(state, queue)

        if current_load?(state, tab_id, effect.origin),
          do: install_loaded(state, effect, result),
          else: state

      :stale ->
        state
    end
  end

  defp settle(
         %State{
           interaction: %{
             queued_input_edit: {:saving, ref, buffer, origin, {id, revision}, request}
           }
         } = state,
         %__MODULE__{ref: ref, buffer_version: version},
         {:completed, :saved}
       ) do
    state
    |> install({:open, buffer, origin, {id, revision + 1}, request})
    |> report_saved(buffer, version)
  end

  defp settle(
         %State{
           interaction: %{queued_input_edit: {:saving, ref, buffer, origin, identity, request}}
         } = state,
         %__MODULE__{ref: ref},
         {_status, reason}
       ) do
    state |> install({:open, buffer, origin, identity, request}) |> report(failure(reason))
  end

  defp settle(state, _effect, _result), do: state

  @spec active_tab_id(State.t()) :: non_neg_integer() | nil
  defp active_tab_id(state) do
    case Runtime.active_tab(state.shell_runtime) do
      %{id: id} -> id
      nil -> nil
    end
  end

  @spec current_load?(State.t(), non_neg_integer() | nil, origin()) :: boolean()
  defp current_load?(%State{shell_runtime: %{state: %{modal: :none}}} = state, tab_id, origin) do
    active_tab_id(state) == tab_id and QueueWorkflow.current_origin(state) == origin
  end

  defp current_load?(_state, _tab_id, _origin), do: false

  @spec report_saved(State.t(), pid(), non_neg_integer()) :: State.t()
  defp report_saved(state, buffer, version) do
    message =
      case Buffer.confirm_scratch_save(buffer, version) do
        :ok -> "Queued input updated. Close this buffer to return to your workspace."
        :stale -> "Queued input updated. Save again to apply newer edits in this buffer."
      end

    report(state, message)
  catch
    :exit, _reason -> report(state, "Queued input updated.")
  end

  @spec install_loaded(State.t(), t(), {atom(), term()}) :: State.t()
  defp install_loaded(state, effect, {:completed, text}) when is_binary(text) do
    case DynamicSupervisor.start_child(
           Minga.Buffer.Supervisor,
           {Minga.Buffer,
            content: text,
            buffer_name: "*Queued Agent input*",
            buffer_type: :nofile,
            read_only: false,
            filetype: :text,
            options_server: state.interaction.options_server}
         ) do
      {:ok, buffer} ->
        state
        |> BufferRegistry.add_buffer(buffer)
        |> focus_edit_buffer()
        |> install({:open, buffer, effect.origin, effect.identity, effect.request})
        |> report(
          "Edit the queued text, then save to apply. Closing without saving keeps the original."
        )

      {:error, _reason} ->
        report(state, "Could not open the queued editing buffer.")
    end
  end

  defp install_loaded(state, _effect, {_status, reason}), do: report(state, failure(reason))

  @spec focus_edit_buffer(State.t()) :: State.t()
  defp focus_edit_buffer(state) do
    agent_ui = UIState.set_input_focused(state.workspace.agent_ui, false)
    agent_ui = if agent_ui.panel.visible, do: UIState.toggle(agent_ui), else: agent_ui
    state = Workflow.install_agent_ui(state, agent_ui)

    workspace =
      state.workspace
      |> SessionState.set_keymap_scope(:editor)
      |> SessionState.transition_mode(:normal)

    %{state | workspace: workspace}
  end

  @spec install(State.t(), edit() | nil) :: State.t()
  defp install(state, edit),
    do: %{state | interaction: Interaction.put_queued_input_edit(state.interaction, edit)}

  @spec failure(term()) :: String.t()
  defp failure(:already_consumed),
    do: "That input already left the queue. Your edits were not applied."

  defp failure(:stale_queue_revision),
    do: "That queued input changed. Reopen it from the queue to edit its new revision."

  defp failure(reason) when is_binary(reason), do: reason

  defp failure(_reason),
    do: "Queued edit not confirmed. Your text was kept; review the queue before retrying."

  @spec report(State.t(), String.t()) :: State.t()
  defp report(state, message), do: NoticeWorkflow.publish(state, message)
end
