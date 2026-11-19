defmodule MingaEditor.Agent.ConnectionSetup do
  @moduledoc "Opens local credential input for a captured workspace and schedules its guarded submission."

  @behaviour MingaEditor.Effect

  alias MingaAgent.Credentials
  alias MingaAgent.OAuth.Flow
  alias MingaAgent.Credentials.Secret
  alias MingaAgent.Session
  alias MingaAgent.Session.{ConnectionSnapshot, ConnectionTarget}
  alias MingaEditor.Agent.{ConnectionAction, ConnectionInput, ConnectionPrompt, UIState}
  alias MingaEditor.Effect.{Outcome, Policy, Request}
  alias MingaEditor.EffectScheduler
  alias MingaEditor.PromptUI
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.{NoticeWorkflow, Workflow}
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.{Prompt, TabBar, Workspace}
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent
  @typep setup_method :: {:api_key, String.t()} | :oauth_browser | :oauth_manual
  @typep intent ::
           {:begin, setup_method(), pid(), pid()}
           | {:submit, ConnectionPrompt.t(), pid(), ConnectionInput.receipt()}
           | {:authorization_url, :open | :copy, ConnectionPrompt.t()}
  @type t :: %__MODULE__{
          workspace_id: non_neg_integer(),
          target: ConnectionTarget.t(),
          intent: intent()
        }
  @enforce_keys [:workspace_id, :target, :intent]
  defstruct [:workspace_id, :target, :intent]

  @doc "Begins local credential setup for the workspace that offered the action."
  @spec start(EditorState.t(), non_neg_integer(), ConnectionTarget.t(), setup_method()) ::
          EditorState.t()
  def start(
        state,
        workspace_id,
        %ConnectionTarget{session: session} = target,
        {:api_key, provider} = kind
      )
      when node(session) == node() do
    if Credentials.env_var_for(provider) do
      subscriber = state.agent_connection.agent_ingest || self()

      effect = %__MODULE__{
        workspace_id: workspace_id,
        target: target,
        intent: {:begin, kind, self(), subscriber}
      }

      admit(state, Request.new(effect, {:agent_connection, session}, Policy.fifo(0)))
    else
      NoticeWorkflow.publish(state, "Choose a supported API-key provider.")
    end
  end

  def start(state, workspace_id, %ConnectionTarget{session: session} = target, method)
      when node(session) == node() and method in [:oauth_browser, :oauth_manual] do
    subscriber = state.agent_connection.agent_ingest || self()

    effect = %__MODULE__{
      workspace_id: workspace_id,
      target: target,
      intent: {:begin, method, self(), subscriber}
    }

    admit(state, Request.new(effect, {:agent_connection, session}, Policy.fifo(0)))
  end

  def start(state, _workspace_id, %ConnectionTarget{}, {:api_key, _provider}) do
    NoticeWorkflow.publish(state, "Add API keys on the host running this agent session.")
  end

  @doc "Captures the original workspace for an explicit credential setup command."
  @spec start_current(EditorState.t(), String.t() | setup_method()) ::
          EditorState.t()
  def start_current(state, provider) when is_binary(provider),
    do: start_current(state, {:api_key, provider})

  def start_current(state, method) do
    case ConnectionAction.origin(state) do
      {:ok, workspace_id, %{target: target}} ->
        start(state, workspace_id, target, method)

      {:error, _reason} ->
        NoticeWorkflow.publish(state, "Open an agent session before configuring a connection.")
    end
  end

  @doc "Opens or copies the public link for the exact current sign-in operation."
  @spec authorization_url(EditorState.t(), ConnectionPrompt.t(), :open | :copy) :: EditorState.t()
  def authorization_url(state, %ConnectionPrompt{authorization_url: url} = prompt, action)
      when is_binary(url) do
    if current_input?(state, prompt) do
      effect = %__MODULE__{
        workspace_id: prompt.workspace_id,
        target: prompt.target,
        intent: {:authorization_url, action, prompt}
      }

      admit(
        state,
        Request.new(effect, {:connection_authorization, prompt.target.session}, Policy.fifo(0))
      )
    else
      state
    end
  end

  @doc "Resumes an offered operation without using the draft or changing workspaces."
  @spec resume(EditorState.t(), ConnectionPrompt.t()) :: EditorState.t()
  def resume(state, %ConnectionPrompt{} = prompt) do
    if current_input?(state, prompt), do: open_prompt(state, prompt), else: state
  end

  @doc "Cancels only the original prompt and discards its local input request."
  @spec cancel(EditorState.t(), ConnectionPrompt.t()) :: EditorState.t()
  def cancel(state, %ConnectionPrompt{} = prompt) do
    request_cancel(prompt)
    clear_prompt(state, prompt)
  end

  @doc "Closes an obsolete credential modal after the canonical connection changes."
  @spec retire_prompt(EditorState.t(), ConnectionSnapshot.t()) :: EditorState.t()
  def retire_prompt(
        %{
          shell_runtime: %{
            state: %{
              modal:
                {:prompt,
                 %{
                   prompt_ui: %Prompt{
                     handler: ConnectionPrompt,
                     context: %ConnectionPrompt{} = prompt
                   }
                 }}
            }
          }
        } = state,
        connection
      ) do
    if ConnectionPrompt.current?(prompt, connection), do: state, else: PromptUI.close(state)
  end

  def retire_prompt(state, _connection), do: state

  @doc "Offers input to the original workspace after its canonical operation event arrives."
  @spec offer(
          EditorState.t(),
          non_neg_integer(),
          ConnectionTarget.t(),
          reference(),
          setup_method()
        ) ::
          EditorState.t()
  def offer(state, id, %ConnectionTarget{} = target, ref, method)
      when method in [:oauth_browser, :oauth_manual] do
    owner = self()
    session = target.session

    notify = fn notice ->
      send(owner, {:agent_event, session, {:oauth_manual_requested, id, notice}})
    end

    acquire = fn ->
      case Flow.run_connection(target, ref, method, owner, notify) do
        {:ok, :openai} ->
          :ok

        {:error, reason} ->
          Session.report_oauth_failure(session, target, ref, reason)
      end
    end

    with {:ok, supervisor} <- submission_supervisor(state.effect_scheduler),
         {:ok, worker} <- Task.Supervisor.start_child(supervisor, acquire) do
      :ok = Session.request_connection_worker(session, target, ref, worker)
      state
    else
      {:error, _reason} ->
        Session.report_oauth_failure(session, target, ref, :worker_unavailable)
        state
    end
  end

  def offer(state, id, %ConnectionTarget{} = target, ref, {:api_key, _provider} = kind) do
    offer_prompt(state, %ConnectionPrompt{
      workspace_id: id,
      target: target,
      operation_ref: ref,
      kind: kind
    })
  end

  @doc "Offers the masked fallback for the exact local acquisition worker."
  @spec offer_oauth(EditorState.t(), non_neg_integer(), MingaAgent.OAuth.ManualReady.t()) ::
          EditorState.t()
  def offer_oauth(state, id, %MingaAgent.OAuth.ManualReady{} = ready) do
    target = ready.target

    prompt = %ConnectionPrompt{
      workspace_id: id,
      target: target,
      operation_ref: ready.operation_ref,
      kind: {:oauth_manual, ready.worker, ready.flow_ref},
      authorization_url: ready.url
    }

    case project_workspace(state, id, target, &UIState.offer_connection_prompt(&1, prompt)) do
      {:active, updated} ->
        if current_input?(updated, prompt) do
          NoticeWorkflow.publish(
            updated,
            "Open or copy the OpenAI authorization link from Models and connections, then resume sign-in to paste the redirect."
          )
        else
          updated
        end

      {:background, updated} ->
        updated

      :unowned ->
        request_cancel(prompt)
        state
    end
  end

  @doc "Projects an OAuth failure only to the original workspace."
  @spec oauth_failed(EditorState.t(), non_neg_integer(), ConnectionTarget.t(), atom()) ::
          EditorState.t()
  def oauth_failed(state, id, target, reason) do
    message =
      case reason do
        :account_mismatch ->
          "OpenAI sign-in used a different account. Sign in with the original account."

        _other ->
          "Could not complete OpenAI sign-in. Open Models and connections to retry."
      end

    project_notice(
      state,
      id,
      target,
      message,
      :error
    )
  end

  @spec offer_prompt(EditorState.t(), ConnectionPrompt.t()) :: EditorState.t()
  defp offer_prompt(state, %ConnectionPrompt{workspace_id: id, target: target} = prompt) do
    case project_workspace(state, id, target, &UIState.offer_connection_prompt(&1, prompt)) do
      {:active, updated} ->
        maybe_open_prompt(updated, prompt)

      {:background, updated} ->
        updated

      :unowned ->
        request_cancel(prompt)
        state
    end
  end

  @doc "Displays a saved credential only in the exact post-commit conversation."
  @spec saved(EditorState.t(), non_neg_integer(), ConnectionTarget.t(), reference()) ::
          EditorState.t()
  def saved(state, workspace_id, %ConnectionTarget{} = target, ref) when is_reference(ref) do
    project_notice(state, workspace_id, target, "API key saved.", :info)
  end

  @doc "Projects the post-commit OpenAI result to its original conversation."
  @spec oauth_saved(EditorState.t(), non_neg_integer(), ConnectionTarget.t()) :: EditorState.t()
  def oauth_saved(state, workspace_id, target) do
    project_notice(state, workspace_id, target, "OpenAI sign-in saved.", :info)
  end

  @doc "Passes sealed input directly to its private worker, then admits a secret-free join."
  @spec submit(EditorState.t(), ConnectionPrompt.t(), Secret.t()) :: EditorState.t()
  def submit(state, %ConnectionPrompt{} = prompt, secret) do
    if current_input?(state, prompt) do
      state |> clear_prompt(prompt) |> schedule_submission(prompt, secret)
    else
      cancel(state, prompt)
    end
  end

  @impl true
  @spec run(t()) :: {:ok, reference() | :saved | :open | :copy} | {:error, term()}
  def run(%__MODULE__{
        workspace_id: id,
        target: target,
        intent: {:begin, kind, owner, subscriber}
      }) do
    Session.begin_connection(target.session, target, kind, owner, {subscriber, id})
  catch
    :exit, _reason -> {:error, :session_unavailable}
  end

  def run(%__MODULE__{intent: {:submit, _prompt, worker, receipt}}) do
    with {:ok, _receipt} <- ConnectionInput.await(worker, receipt), do: {:ok, :saved}
  end

  def run(%__MODULE__{
        intent: {:authorization_url, action, %ConnectionPrompt{authorization_url: url}}
      }) do
    result = if action == :open, do: Flow.open_browser(url), else: Minga.Clipboard.write(url)

    case result do
      :ok -> {:ok, action}
      {:error, _reason} -> {:error, :authorization_link_unavailable}
    end
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(state, %Outcome{request: %{effect: %__MODULE__{} = effect}, value: value} = outcome) do
    {apply_result(state, effect, value), outcome}
  end

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(outcome), do: Outcome.terminal?(outcome)

  @spec apply_result(EditorState.t(), t(), Outcome.value()) :: EditorState.t()
  defp apply_result(
         state,
         %__MODULE__{
           intent: {:submit, %ConnectionPrompt{kind: {:oauth_manual, _, _}} = prompt, _, _}
         },
         {:failed, :invalid_input}
       ) do
    updated = offer_prompt(state, prompt)

    if current_input?(updated, prompt),
      do: NoticeWorkflow.publish(updated, "Paste the authorization redirect URL or code."),
      else: updated
  end

  defp apply_result(
         state,
         %__MODULE__{
           intent:
             {:submit, %ConnectionPrompt{kind: {:oauth_manual, _, _}} = prompt, worker, receipt}
         },
         {status, reason}
       )
       when status in [:failed, :canceled, :stale] do
    ConnectionInput.abort(worker, receipt)

    Session.report_oauth_failure(
      prompt.target.session,
      prompt.target,
      prompt.operation_ref,
      reason
    )

    state
  end

  defp apply_result(state, %__MODULE__{intent: {:authorization_url, _, prompt}}, {status, reason})
       when status in [:failed, :canceled, :stale] do
    if current_input?(state, prompt) do
      project_notice(state, prompt.workspace_id, prompt.target, result_message(reason), :error)
    else
      state
    end
  end

  defp apply_result(state, effect, {status, reason})
       when status in [:failed, :canceled, :stale] do
    retire_submission(effect)
    project_notice(state, effect.workspace_id, effect.target, result_message(reason), :error)
  end

  defp apply_result(state, _effect, _progress), do: state

  @spec maybe_open_prompt(EditorState.t(), ConnectionPrompt.t()) :: EditorState.t()
  defp maybe_open_prompt(%{shell_runtime: %{state: %{modal: :none}}} = state, prompt),
    do: resume(state, prompt)

  defp maybe_open_prompt(state, _prompt), do: state

  @spec open_prompt(EditorState.t(), ConnectionPrompt.t()) :: EditorState.t()
  defp open_prompt(state, %ConnectionPrompt{kind: {:api_key, provider}} = prompt) do
    PromptUI.open(state, ConnectionPrompt,
      label: "#{String.capitalize(provider)} API key: ",
      context: prompt,
      sensitive: true
    )
  end

  defp open_prompt(state, %ConnectionPrompt{kind: {:oauth_manual, _, _}} = prompt) do
    PromptUI.open(state, ConnectionPrompt,
      label: "OpenAI authorization redirect: ",
      context: prompt,
      sensitive: true
    )
  end

  @spec clear_prompt(EditorState.t(), ConnectionPrompt.t()) :: EditorState.t()
  defp clear_prompt(state, prompt) do
    case project_workspace(
           state,
           prompt.workspace_id,
           prompt.target,
           &UIState.retire_connection_prompt(&1, prompt)
         ) do
      {_visibility, updated} -> updated
      :unowned -> state
    end
  end

  @spec current_input?(EditorState.t(), ConnectionPrompt.t()) :: boolean()
  defp current_input?(
         %{workspace: %{agent_ui: %{connection_prompt: prompt}}} = state,
         %ConnectionPrompt{workspace_id: id} = prompt
       ) do
    case ConnectionAction.origin(state) do
      {:ok, ^id, connection} -> ConnectionPrompt.current?(prompt, connection)
      _other -> false
    end
  end

  defp current_input?(_state, _prompt), do: false

  @spec schedule_submission(EditorState.t(), ConnectionPrompt.t(), Secret.t()) :: EditorState.t()
  defp schedule_submission(state, prompt, secret) do
    with {:ok, supervisor} <- submission_supervisor(state.effect_scheduler),
         {:ok, worker, receipt} <-
           ConnectionInput.start(
             supervisor,
             self(),
             prompt.target,
             prompt.operation_ref,
             prompt.kind,
             secret
           ) do
      effect = %__MODULE__{
        workspace_id: prompt.workspace_id,
        target: prompt.target,
        intent: {:submit, prompt, worker, receipt}
      }

      request =
        Request.new(effect, {:connection_submission, prompt.target.session}, Policy.fifo(0),
          timeout_ms: 170_000
        )

      admit(state, request)
    else
      {:error, _reason} ->
        request_cancel(prompt)

        NoticeWorkflow.publish(
          state,
          "Could not start secure input. Open Models and connections to retry."
        )
    end
  end

  @spec submission_supervisor(GenServer.server() | nil) ::
          {:ok, GenServer.server()} | {:error, :scheduler_unavailable}
  defp submission_supervisor(nil), do: {:error, :scheduler_unavailable}

  defp submission_supervisor(scheduler) do
    {:ok, EffectScheduler.task_supervisor(scheduler)}
  catch
    :exit, _reason -> {:error, :scheduler_unavailable}
  end

  @spec admit(EditorState.t(), Request.t()) :: EditorState.t()
  defp admit(state, request) do
    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _id, _disposition} -> state
      {:error, _reason} -> reject_admission(state, request)
    end
  catch
    :exit, _reason -> reject_admission(state, request)
  end

  @spec reject_admission(EditorState.t(), Request.t()) :: EditorState.t()
  defp reject_admission(state, request) do
    {state, _outcome} = __MODULE__.apply(state, Outcome.failed(request, :scheduler_unavailable))
    MingaEditor.schedule_render(state, 16)
  end

  @spec retire_submission(t()) :: :ok
  defp retire_submission(%__MODULE__{intent: {:submit, prompt, worker, receipt}}) do
    ConnectionInput.abort(worker, receipt)
    request_cancel(prompt)
  end

  defp retire_submission(%__MODULE__{}), do: :ok

  @spec request_cancel(ConnectionPrompt.t()) :: :ok
  defp request_cancel(%ConnectionPrompt{target: target, operation_ref: ref}) do
    Session.request_connection_cancel(target.session, target, ref)
  end

  @spec project_notice(
          EditorState.t(),
          non_neg_integer(),
          ConnectionTarget.t(),
          String.t(),
          :info | :error
        ) :: EditorState.t()
  defp project_notice(state, workspace_id, target, message, kind) do
    case project_workspace(
           state,
           workspace_id,
           target,
           &UIState.push_toast(&1, message, kind)
         ) do
      {:active, updated} -> NoticeWorkflow.publish(updated, message)
      {:background, updated} -> updated
      :unowned -> state
    end
  end

  @spec project_workspace(
          EditorState.t(),
          non_neg_integer(),
          ConnectionTarget.t(),
          (UIState.t() -> UIState.t())
        ) ::
          {:active | :background, EditorState.t()} | :unowned
  defp project_workspace(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tab_bar}}} = state,
         id,
         target,
         update
       ) do
    case TabBar.get_workspace(tab_bar, id) do
      %Workspace{payload: %WorkspaceAgent{session: session, agent_ui: ui}} = workspace
      when session == target.session ->
        if TabBar.active_workspace_id(tab_bar) == id do
          project_active_ui(state, target, update)
        else
          project_background_ui(state, workspace, ui, tab_bar, target, update)
        end

      _other ->
        :unowned
    end
  end

  defp project_workspace(_state, _id, _target, _update), do: :unowned

  @spec project_active_ui(
          EditorState.t(),
          ConnectionTarget.t(),
          (UIState.t() -> UIState.t())
        ) ::
          {:active, EditorState.t()} | :unowned
  defp project_active_ui(state, target, update) do
    ui = state.workspace.agent_ui

    if target_matches?(ui, target),
      do: {:active, Workflow.install_agent_ui(state, update.(ui))},
      else: :unowned
  end

  @spec project_background_ui(
          EditorState.t(),
          Workspace.t(),
          UIState.t(),
          TabBar.t(),
          ConnectionTarget.t(),
          (UIState.t() -> UIState.t())
        ) ::
          {:background, EditorState.t()} | :unowned
  defp project_background_ui(state, workspace, ui, tab_bar, target, update) do
    if target_matches?(ui, target) do
      tab_bar = TabBar.accept_workspace(tab_bar, Workspace.set_agent_ui(workspace, update.(ui)))
      shell = ShellState.install_tab_bar(Runtime.state(state.shell_runtime), tab_bar)

      {:background,
       %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell)}}
    else
      :unowned
    end
  end

  @spec target_matches?(UIState.t() | nil, ConnectionTarget.t()) :: boolean()
  defp target_matches?(%UIState{connection: %{target: target}}, target), do: true
  defp target_matches?(_ui, _target), do: false

  @spec result_message(term()) :: String.t()
  defp result_message(:invalid_secret), do: "Enter a non-empty API key with no line breaks."

  defp result_message(:credential_store_failed),
    do: "Could not save the API key. The previous key was kept."

  defp result_message(:model_catalog_unavailable),
    do: "Could not load the model catalog. The API key was not changed."

  defp result_message(:stale_target),
    do: "The conversation or model changed. Open Models and connections to try again."

  defp result_message(:not_driver), do: "Only the session driver can configure this connection."
  defp result_message(:session_unavailable), do: "The original agent session is unavailable."

  defp result_message(reason) when reason in [:credential_result_unknown, :input_worker_timeout],
    do:
      "Could not confirm whether the key was saved. Check Models and connections before retrying."

  defp result_message(:authorization_link_unavailable),
    do:
      "Could not open or copy the authorization link. Try the other action in Models and connections."

  defp result_message(_reason),
    do: "Connection did not finish. Open Models and connections to try again."
end
