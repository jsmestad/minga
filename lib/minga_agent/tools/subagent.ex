defmodule MingaAgent.Tools.Subagent do
  @moduledoc """
  Starts a child agent session to work on a subtask.

  Foreground sub-agents keep the historical blocking behavior: the tool call waits for the child to finish and returns the final assistant text. Background sub-agents are registered with `MingaAgent.SessionManager`, return a stable session handle immediately, and keep the child chat alive for later inspection.
  """

  alias MingaAgent.ProviderResolver
  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias MingaAgent.Subagent.Handle
  alias MingaAgent.Subagent.Worktree
  alias MingaAgent.SubagentContext
  alias MingaAgent.Supervisor, as: AgentSupervisor

  @typedoc "Provider override accepted by direct callers and the tool schema."
  @type provider_override :: :native | :pi_rpc | module() | String.t() | nil

  @typedoc "Context inherited from the parent agent session."
  @type parent_context :: SubagentContext.t()

  @typedoc "Resolved provider for a child session."
  @type resolved_provider :: %{
          module: module(),
          name: String.t(),
          id: String.t(),
          source: Minga.Extension.ContributionCleanup.contribution_source()
        }

  @typedoc "Options for subagent execution."
  @type opts :: [
          model: String.t() | nil,
          provider: provider_override(),
          parent_session: GenServer.server() | nil,
          project_root: String.t() | nil,
          provider_opts: keyword(),
          background: boolean(),
          isolation: String.t() | atom() | nil,
          worktree_backend: module(),
          worktree_backend_opts: keyword(),
          session_manager: GenServer.server(),
          notifier: module() | {module(), term()},
          startup_timeout_ms: pos_integer()
        ]

  @subagent_timeout_ms 300_000
  @provider_ready_retry_ms 10
  @provider_ready_max_attempts 100
  @approval_unavailable_message "Subagent tool approval is unavailable because this child session has no interactive approval driver. Run the subagent with worktree isolation or route approvals through the parent session."

  @doc """
  Runs a sub-agent task.

  With `background: false` or no background option, waits for the child to finish and returns its final text. With `background: true`, returns immediately with the child session handle and leaves the child running.
  """
  @spec execute(String.t(), opts()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(task, opts \\ []) when is_binary(task) do
    if Keyword.get(opts, :background, false) do
      start_background(task, opts)
    else
      start_foreground(task, opts)
    end
  end

  @spec start_background(String.t(), opts()) :: {:ok, String.t()} | {:error, String.t()}
  defp start_background(task, opts) do
    if worktree_isolation?(opts) do
      start_worktree_background(task, opts)
    else
      do_start_background(task, opts)
    end
  end

  @spec start_worktree_background(String.t(), opts()) :: {:ok, String.t()} | {:error, String.t()}
  defp start_worktree_background(task, opts) do
    project_root =
      Keyword.get(opts, :project_root) || parent_context(opts).project_root ||
        detect_project_root()

    case Worktree.create(project_root, worktree_opts(opts)) do
      {:ok, worktree} ->
        child_opts = Keyword.put(opts, :project_root, worktree.path)

        case do_start_background(task, child_opts) do
          {:ok, result} -> {:ok, result <> Worktree.metadata(worktree)}
          {:error, reason} -> Worktree.finish_error(worktree, reason)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec do_start_background(String.t(), opts()) :: {:ok, String.t()} | {:error, String.t()}
  defp do_start_background(task, opts) do
    manager = Keyword.get(opts, :session_manager, SessionManager)
    parent_session = Keyword.get(opts, :parent_session)
    model = Keyword.get(opts, :model)

    with {:ok, session_opts} <- session_opts(opts),
         {:ok, %Handle{} = handle} <-
           SessionManager.start_background_subagent(manager, parent_session, task,
             session_opts: session_opts,
             model: model
           ) do
      {:ok, background_result(handle)}
    else
      {:error, {:provider_resolution_failed, reason}} ->
        {:error, "Failed to resolve subagent provider: #{reason}"}

      {:error, reason} ->
        {:error, "Failed to start background subagent: #{inspect(reason)}"}
    end
  end

  @spec start_foreground(String.t(), opts()) :: {:ok, String.t()} | {:error, String.t()}
  defp start_foreground(task, opts) do
    if worktree_isolation?(opts) do
      start_worktree_foreground(task, opts)
    else
      do_start_foreground(task, opts)
    end
  end

  @spec do_start_foreground(String.t(), opts()) :: {:ok, String.t()} | {:error, String.t()}
  defp do_start_foreground(task, opts) do
    with {:ok, session_opts} <- session_opts(opts),
         {:ok, session_pid} <- AgentSupervisor.start_session(session_opts) do
      timeout = Keyword.get(opts, :startup_timeout_ms, @subagent_timeout_ms)
      run_subagent(session_pid, task, timeout)
    else
      {:error, {:provider_resolution_failed, reason}} ->
        {:error, "Failed to resolve subagent provider: #{reason}"}

      {:error, reason} ->
        {:error, "Failed to start subagent: #{inspect(reason)}"}
    end
  end

  @spec start_worktree_foreground(String.t(), opts()) :: {:ok, String.t()} | {:error, String.t()}
  defp start_worktree_foreground(task, opts) do
    project_root =
      Keyword.get(opts, :project_root) || parent_context(opts).project_root ||
        detect_project_root()

    case Worktree.create(project_root, worktree_opts(opts)) do
      {:ok, worktree} ->
        child_opts = Keyword.put(opts, :project_root, worktree.path)

        case do_start_foreground(task, child_opts) do
          {:ok, result} ->
            Worktree.finish_result(worktree, result)

          {:error, reason} ->
            Worktree.finish_error(worktree, reason)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec run_subagent(pid(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  defp run_subagent(session_pid, task, timeout) do
    :ok = Session.subscribe(session_pid, self(), [], timeout)

    case send_prompt_when_ready(session_pid, task, 0) do
      :ok -> collect_response(session_pid)
      {:error, reason} -> {:error, "Subagent failed to start: #{inspect(reason)}"}
    end
  catch
    :exit, {:timeout, {GenServer, :call, [^session_pid, {:subscribe, _pid, _opts}, ^timeout]}} ->
      {:error, "Subagent timed out while starting"}
  after
    AgentSupervisor.stop_session(session_pid)
  end

  @spec send_prompt_when_ready(pid(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp send_prompt_when_ready(session_pid, task, attempt) do
    case Session.send_prompt(session_pid, task) do
      :ok ->
        :ok

      {:error, :provider_not_ready} when attempt < @provider_ready_max_attempts ->
        receive do
        after
          @provider_ready_retry_ms -> send_prompt_when_ready(session_pid, task, attempt + 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec collect_response(pid()) :: {:ok, String.t()} | {:error, String.t()}
  def collect_response(session_pid) do
    collect_response_loop(session_pid, "", @subagent_timeout_ms)
  end

  @spec collect_response_loop(pid(), String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def collect_response_loop(session_pid, text_acc, timeout) do
    receive do
      {:agent_event, ^session_pid, {:text_delta, delta}} ->
        collect_response_loop(session_pid, text_acc <> delta, timeout)

      {:agent_event, ^session_pid, {:status_changed, :idle}} ->
        result = String.trim(text_acc)

        if result == "" do
          {:ok, "(subagent completed with no text output)"}
        else
          {:ok, result}
        end

      {:agent_event, ^session_pid, {:error, message}} ->
        {:error, "Subagent error: #{message}"}

      {:agent_event, ^session_pid, _other_event} ->
        collect_response_loop(session_pid, text_acc, timeout)
    after
      timeout ->
        {:error, "Subagent timed out after #{div(@subagent_timeout_ms, 1000)} seconds"}
    end
  end

  # ── Worktree isolation ─────────────────────────────────────────────────────

  @spec worktree_isolation?(opts()) :: boolean()
  defp worktree_isolation?(opts), do: Keyword.get(opts, :isolation) in ["worktree", :worktree]

  @spec worktree_opts(opts()) :: Worktree.create_opts()
  defp worktree_opts(opts) do
    [
      backend: Keyword.get(opts, :worktree_backend, MingaAgent.Subagent.Worktree.System),
      backend_opts: Keyword.get(opts, :worktree_backend_opts, [])
    ]
  end

  # ── Session opts (shared by foreground and background) ─────────────────────

  @spec session_opts(opts()) ::
          {:ok, keyword()} | {:error, {:provider_resolution_failed, String.t()}}
  defp session_opts(opts) do
    parent_ctx = parent_context(opts)

    case resolve_provider(Keyword.get(opts, :provider), parent_ctx) do
      {:ok, resolved_provider} ->
        model = Keyword.get(opts, :model) || parent_ctx.model

        project_root =
          Keyword.get(opts, :project_root) || parent_ctx.project_root || detect_project_root()

        thinking_level = parent_ctx.thinking_level
        active_skill_names = parent_ctx.active_skill_names
        extra_provider_opts = Keyword.get(opts, :provider_opts, [])

        session_opts =
          [
            provider: resolved_provider.module,
            provider_id: resolved_provider.id,
            provider_source: resolved_provider.source,
            model_name: model || "unknown",
            startup_notice:
              startup_notice(
                Keyword.get(opts, :provider),
                Keyword.get(opts, :model),
                resolved_provider,
                model
              ),
            provider_opts:
              build_provider_opts(
                project_root,
                resolved_provider.name,
                model,
                thinking_level,
                active_skill_names,
                extra_provider_opts
              )
          ]
          |> maybe_put_thinking_level(thinking_level)
          |> maybe_put_notifier(opts)
          |> put_tool_approval_policy(opts)

        {:ok, session_opts}

      {:error, reason} ->
        {:error, {:provider_resolution_failed, reason}}
    end
  end

  @spec maybe_put_notifier(keyword(), opts()) :: keyword()
  defp maybe_put_notifier(session_opts, opts) do
    case Keyword.fetch(opts, :notifier) do
      {:ok, notifier} -> Keyword.put(session_opts, :notifier, notifier)
      :error -> session_opts
    end
  end

  @spec put_tool_approval_policy(keyword(), opts()) :: keyword()
  defp put_tool_approval_policy(session_opts, opts) do
    if worktree_isolation?(opts) do
      Keyword.put(session_opts, :tool_approval_policy, {:auto_approve, :session})
    else
      Keyword.put(session_opts, :tool_approval_policy, {:reject, @approval_unavailable_message})
    end
  end

  @spec background_result(Handle.t()) :: String.t()
  defp background_result(%Handle{} = handle) do
    "Background subagent started. Handle: #{Handle.id(handle)}. Use the agent session picker to inspect its chat."
  end

  # ── Context inheritance ────────────────────────────────────────────────────

  @spec parent_context(opts()) :: parent_context()
  defp parent_context(opts) do
    case Keyword.get(opts, :parent_session) do
      nil -> default_parent_context()
      parent_session -> fetch_parent_context(parent_session)
    end
  end

  @spec fetch_parent_context(GenServer.server()) :: parent_context()
  defp fetch_parent_context(parent_session) do
    Session.subagent_context(parent_session)
  catch
    :exit, {reason, _} ->
      Minga.Log.warning(
        :agent,
        "[Subagent] parent session #{inspect(parent_session)} unreachable: #{inspect(reason)}"
      )

      default_parent_context()

    :exit, reason ->
      Minga.Log.warning(
        :agent,
        "[Subagent] parent session #{inspect(parent_session)} unreachable: #{inspect(reason)}"
      )

      default_parent_context()
  end

  @spec default_parent_context() :: parent_context()
  defp default_parent_context do
    SubagentContext.default()
  end

  @spec resolve_provider(provider_override(), parent_context()) ::
          {:ok, resolved_provider()} | {:error, String.t()}
  defp resolve_provider(nil, parent_context) do
    resolve_inherited_provider(parent_context)
  end

  defp resolve_provider(:native, _parent_context) do
    resolve_registered_provider(:native)
  end

  defp resolve_provider(:pi_rpc, _parent_context) do
    {:ok, %{module: MingaAgent.Providers.PiRpc, name: "pi_rpc", id: "pi_rpc", source: :config}}
  end

  defp resolve_provider(provider, _parent_context) when is_atom(provider) do
    {:ok, %{module: provider, name: inspect(provider), id: inspect(provider), source: :config}}
  end

  defp resolve_provider("native", _parent_context), do: resolve_registered_provider(:native)
  defp resolve_provider("pi_rpc", parent_context), do: resolve_provider(:pi_rpc, parent_context)

  defp resolve_provider(provider, _parent_context) when is_binary(provider) do
    resolve_registered_provider(provider)
  end

  defp resolve_provider(provider, _parent_context) do
    {:error, "Unknown subagent provider override: #{inspect(provider)}"}
  end

  @spec resolve_inherited_provider(parent_context()) ::
          {:ok, resolved_provider()} | {:error, String.t()}
  defp resolve_inherited_provider(%{provider_source: {:bundle, _name}, provider_id: id}) do
    resolve_registered_provider(id)
  end

  defp resolve_inherited_provider(%{provider_source: {:extension, _name}, provider_id: id}) do
    resolve_registered_provider(id)
  end

  defp resolve_inherited_provider(parent_context) do
    {:ok,
     %{
       module: parent_context.provider_module,
       name: parent_context.provider_name,
       id: parent_context.provider_id,
       source: parent_context.provider_source
     }}
  end

  @spec resolve_registered_provider(ProviderResolver.preference()) ::
          {:ok, resolved_provider()} | {:error, String.t()}
  defp resolve_registered_provider(provider) do
    resolved = ProviderResolver.resolve(provider)

    {:ok,
     %{
       module: resolved.module,
       name: resolved.name,
       id: resolved.id,
       source: resolved.source
     }}
  rescue
    e in ArgumentError ->
      {:error, Exception.message(e)}

    e ->
      Minga.Log.error(
        :agent,
        "Unexpected subagent provider resolution failure: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {:error, "Unexpected subagent provider resolution failure"}
  end

  @spec build_provider_opts(
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          [String.t()],
          keyword()
        ) :: keyword()
  defp build_provider_opts(
         project_root,
         provider_name,
         model,
         thinking_level,
         active_skill_names,
         extra_provider_opts
       ) do
    [project_root: project_root, provider: provider_name]
    |> maybe_put(:model, model)
    |> maybe_put(:thinking_level, thinking_level)
    |> maybe_put_active_skill_names(active_skill_names)
    |> Keyword.merge(provider_passthrough_opts(extra_provider_opts))
  end

  @spec provider_passthrough_opts(keyword()) :: keyword()
  defp provider_passthrough_opts(opts) do
    opts
    |> Keyword.delete(:subscriber)
    |> Keyword.delete(:project_root)
  end

  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @spec maybe_put_active_skill_names(keyword(), [String.t()]) :: keyword()
  defp maybe_put_active_skill_names(opts, []), do: opts

  defp maybe_put_active_skill_names(opts, names),
    do: Keyword.put(opts, :active_skill_names, names)

  @spec maybe_put_thinking_level(keyword(), String.t() | nil) :: keyword()
  defp maybe_put_thinking_level(opts, nil), do: opts

  defp maybe_put_thinking_level(opts, thinking_level),
    do: Keyword.put(opts, :thinking_level, thinking_level)

  @spec startup_notice(
          provider_override(),
          String.t() | nil,
          resolved_provider(),
          String.t() | nil
        ) ::
          String.t() | nil
  defp startup_notice(nil, nil, _resolved_provider, _model), do: nil

  defp startup_notice(provider_override, model_override, resolved_provider, model) do
    [provider_notice(provider_override, resolved_provider), model_notice(model_override, model)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> then(&("Subagent overrides · " <> &1))
  end

  @spec provider_notice(provider_override(), resolved_provider()) :: String.t() | nil
  defp provider_notice(nil, _resolved_provider), do: nil

  defp provider_notice(_provider_override, resolved_provider),
    do: "provider override: #{resolved_provider.name}"

  @spec model_notice(String.t() | nil, String.t() | nil) :: String.t() | nil
  defp model_notice(nil, _model), do: nil
  defp model_notice(_model_override, nil), do: "model override: unknown"
  defp model_notice(_model_override, model), do: "model override: #{model}"

  defdelegate detect_project_root, to: Minga.Project, as: :resolve_root
end
