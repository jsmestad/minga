defmodule MingaAgent.Tools.Subagent do
  @moduledoc """
  Starts a child agent session to work on a subtask.

  Foreground sub-agents keep the historical blocking behavior: the tool call waits for the child to finish and returns the final assistant text. Background sub-agents are registered with `MingaAgent.SessionManager`, return a stable session handle immediately, and keep the child chat alive for later inspection.
  """

  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias MingaAgent.Subagent.Handle
  alias MingaAgent.Supervisor, as: AgentSupervisor

  @typedoc "Options for subagent execution."
  @type opts :: [
          model: String.t() | nil,
          project_root: String.t() | nil,
          background: boolean(),
          parent_session: pid() | nil,
          provider: module(),
          provider_opts: keyword(),
          session_manager: GenServer.server()
        ]

  @subagent_timeout_ms 300_000
  @provider_ready_retry_ms 10
  @provider_ready_max_attempts 100

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
    manager = Keyword.get(opts, :session_manager, SessionManager)
    parent_session = Keyword.get(opts, :parent_session)
    model = Keyword.get(opts, :model)

    case SessionManager.start_background_subagent(manager, parent_session, task,
           session_opts: session_opts(opts),
           model: model
         ) do
      {:ok, %Handle{} = handle} ->
        {:ok, background_result(handle)}

      {:error, reason} ->
        {:error, "Failed to start background subagent: #{inspect(reason)}"}
    end
  end

  @spec start_foreground(String.t(), opts()) :: {:ok, String.t()} | {:error, String.t()}
  defp start_foreground(task, opts) do
    case AgentSupervisor.start_session(session_opts(opts)) do
      {:ok, session_pid} ->
        run_subagent(session_pid, task)

      {:error, reason} ->
        {:error, "Failed to start subagent: #{inspect(reason)}"}
    end
  end

  @spec run_subagent(pid(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp run_subagent(session_pid, task) do
    :ok = Session.subscribe(session_pid)

    case send_prompt_when_ready(session_pid, task, 0) do
      :ok ->
        result = collect_response(session_pid)
        cleanup(session_pid)
        result

      {:error, reason} ->
        cleanup(session_pid)
        {:error, "Subagent failed to start: #{inspect(reason)}"}
    end
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
  defp collect_response(session_pid) do
    collect_response_loop(session_pid, "", @subagent_timeout_ms)
  end

  @spec collect_response_loop(pid(), String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp collect_response_loop(session_pid, text_acc, timeout) do
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

  @spec cleanup(pid()) :: :ok
  defp cleanup(session_pid) do
    Session.unsubscribe(session_pid)
    AgentSupervisor.stop_session(session_pid)
    :ok
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end

  @spec session_opts(opts()) :: keyword()
  defp session_opts(opts) do
    project_root = Keyword.get(opts, :project_root, detect_project_root())
    model = Keyword.get(opts, :model)
    provider = Keyword.get(opts, :provider, MingaAgent.Providers.Native)

    provider_opts =
      opts
      |> Keyword.get(:provider_opts, [])
      |> Keyword.merge(build_provider_opts(project_root, model))

    [provider: provider, provider_opts: provider_opts, model_name: model || "unknown"]
    |> maybe_put_notifier(opts)
  end

  @spec maybe_put_notifier(keyword(), opts()) :: keyword()
  defp maybe_put_notifier(session_opts, opts) do
    case Keyword.fetch(opts, :notifier) do
      {:ok, notifier} -> Keyword.put(session_opts, :notifier, notifier)
      :error -> session_opts
    end
  end

  @spec build_provider_opts(String.t(), String.t() | nil) :: keyword()
  defp build_provider_opts(project_root, model) do
    opts = [
      project_root: project_root,
      provider: "native"
    ]

    if model do
      [{:model, model} | opts]
    else
      opts
    end
  end

  @spec background_result(Handle.t()) :: String.t()
  defp background_result(%Handle{} = handle) do
    "Background subagent started. Handle: #{Handle.id(handle)}. Use the agent session picker to inspect its chat."
  end

  defdelegate detect_project_root, to: Minga.Project, as: :resolve_root
end
