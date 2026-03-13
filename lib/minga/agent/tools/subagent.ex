defmodule Minga.Agent.Tools.Subagent do
  @moduledoc """
  Spawns a child agent session to work on a subtask.

  The parent agent describes a task, the subagent executes it (with its own
  tool calls and conversation), and returns a summary result. The subagent
  runs as a separate `Agent.Session` process under `Agent.Supervisor`, so
  crashes do not affect the parent.

  The subagent's conversation is ephemeral (not saved to session history).
  Only the final text response is returned to the parent as the tool result.
  """

  alias Minga.Agent.Event
  alias Minga.Agent.Session
  alias Minga.Agent.Supervisor, as: AgentSupervisor

  @typedoc "Options for subagent execution."
  @type opts :: [
          model: String.t() | nil,
          project_root: String.t() | nil
        ]

  @subagent_timeout_ms 300_000

  @doc """
  Spawns a subagent session, sends it the task, and blocks until it completes.

  Returns the subagent's final text response, or an error if it times out
  or crashes.
  """
  @spec execute(String.t(), opts()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(task, opts \\ []) when is_binary(task) do
    model = Keyword.get(opts, :model)
    project_root = Keyword.get(opts, :project_root, detect_project_root())

    session_opts =
      [
        provider: Minga.Agent.Providers.Native,
        provider_opts: build_provider_opts(project_root, model)
      ]

    case AgentSupervisor.start_session(session_opts) do
      {:ok, session_pid} ->
        run_subagent(session_pid, task)

      {:error, reason} ->
        {:error, "Failed to start subagent: #{inspect(reason)}"}
    end
  end

  @spec run_subagent(pid(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp run_subagent(session_pid, task) do
    # Subscribe to receive events from the subagent
    :ok = Session.subscribe(session_pid)

    # Send the task as a prompt
    case Session.send_prompt(session_pid, task) do
      :ok ->
        result = collect_response(session_pid)
        cleanup(session_pid)
        result

      {:error, reason} ->
        cleanup(session_pid)
        {:error, "Subagent failed to start: #{inspect(reason)}"}
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
        # Agent finished
        result = String.trim(text_acc)

        if result == "" do
          {:ok, "(subagent completed with no text output)"}
        else
          {:ok, result}
        end

      {:agent_event, ^session_pid, {:error, message}} ->
        {:error, "Subagent error: #{message}"}

      {:agent_event, ^session_pid, _other_event} ->
        # Ignore tool events, thinking events, etc.
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
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @spec build_provider_opts(String.t(), String.t() | nil) :: keyword()
  defp build_provider_opts(project_root, model) do
    opts = [
      subscriber: self(),
      project_root: project_root,
      provider: "native"
    ]

    if model do
      [{:model, model} | opts]
    else
      opts
    end
  end

  @spec detect_project_root() :: String.t()
  defp detect_project_root do
    case Minga.Project.root() do
      nil -> File.cwd!()
      root -> root
    end
  rescue
    _ -> File.cwd!()
  catch
    :exit, _ -> File.cwd!()
  end

  # Suppress the unused alias warning; Event is referenced in type context
  # but not directly called in this module.
  _ = Event
end
