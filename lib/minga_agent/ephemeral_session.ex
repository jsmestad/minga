defmodule MingaAgent.EphemeralSession do
  @moduledoc """
  Short-lived read-only agent sessions for inline ask.

  These sessions are not persisted and are stopped after the editor has captured the answer. Inline asks send the selected context directly in the prompt and intentionally expose no tools, so the provider cannot silently read or search unrelated project files.
  """

  alias MingaAgent.Session
  alias MingaAgent.SessionManager

  @doc "Starts a read-only ephemeral ask session and sends its prompt."
  @spec ask(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ask(prompt, project_root, opts \\ []) when is_binary(prompt) and is_binary(project_root) do
    manager = Keyword.get(opts, :session_manager, SessionManager)
    editor_pid = Keyword.get(opts, :subscriber, self())

    session_opts = [
      session_id: "inline-ask-#{System.unique_integer([:positive])}",
      session_store_dir: nil,
      startup_notice: nil,
      persist?: false,
      hooks_enabled?: false,
      provider_opts: [
        project_root: project_root,
        read_only?: true,
        tool_allowlist: [],
        tools: read_only_tools(project_root)
      ]
    ]

    case SessionManager.start_session(manager, session_opts) do
      {:ok, _session_id, pid} -> subscribe_and_prompt(pid, editor_pid, prompt)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stops an ephemeral session if it is still alive."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(pid) when is_pid(pid) do
    SessionManager.stop_session_by_pid(pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  @spec subscribe_and_prompt(pid(), pid(), String.t()) :: {:ok, pid()} | {:error, term()}
  defp subscribe_and_prompt(pid, editor_pid, prompt) do
    Session.subscribe(pid, editor_pid)
    send_prompt_when_ready(pid, prompt)
    {:ok, pid}
  catch
    :exit, reason ->
      stop(pid)
      {:error, reason}
  end

  @doc "Returns the latest assistant response from a session."
  @spec assistant_response(pid()) :: String.t()
  def assistant_response(pid) when is_pid(pid) do
    pid
    |> Session.messages()
    |> Enum.filter(&match?({:assistant, _}, &1))
    |> List.last()
    |> assistant_text()
  catch
    :exit, _ -> ""
  end

  @doc "Builds the final inline ask tool list. Inline asks use prompt-provided context only."
  @spec read_only_tools(String.t()) :: [ReqLLM.Tool.t()]
  def read_only_tools(project_root) when is_binary(project_root) do
    _project_root = project_root
    []
  end

  @spec send_prompt_when_ready(pid(), String.t()) :: :ok
  defp send_prompt_when_ready(pid, prompt) do
    parent = self()

    Task.start(fn ->
      wait_for_provider(pid, 20)
      result = Session.send_prompt(pid, prompt)
      send(parent, {:inline_ask_prompt_sent, pid, result})
    end)

    :ok
  end

  @spec wait_for_provider(pid(), non_neg_integer()) :: :ok
  defp wait_for_provider(_pid, 0), do: :ok

  defp wait_for_provider(pid, attempts) do
    if Session.get_provider(pid) do
      :ok
    else
      receive do
      after
        50 -> wait_for_provider(pid, attempts - 1)
      end
    end
  catch
    :exit, _ -> :ok
  end

  @spec assistant_text(MingaAgent.Message.t() | nil) :: String.t()
  defp assistant_text({:assistant, text}), do: text
  defp assistant_text(_message), do: ""
end
