defmodule MingaAgent.EphemeralSession do
  @moduledoc """
  Short-lived constrained agent sessions for inline overlays.

  These sessions are not persisted and are stopped after the editor has captured the answer or rewrite. Inline ask uses prompt-provided context only and exposes no tools. Inline edit exposes only file-read tools plus the structured rewrite result tool.
  """

  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias MingaAgent.Tools
  alias ReqLLM.Tool

  @doc "Starts a read-only ephemeral ask session and sends its prompt."
  @spec ask(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ask(prompt, project_root, opts \\ []) when is_binary(prompt) and is_binary(project_root) do
    tools = Keyword.get(opts, :tools, read_only_tools(project_root))
    start(prompt, project_root, "inline-ask", tools, :inline_ask_prompt_sent, opts)
  end

  @doc "Starts a constrained ephemeral rewrite session and sends its prompt."
  @spec rewrite(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def rewrite(prompt, project_root, opts \\ [])
      when is_binary(prompt) and is_binary(project_root) do
    tools = Keyword.get(opts, :tools, rewrite_tools(project_root))
    start(prompt, project_root, "inline-edit", tools, :inline_edit_prompt_sent, opts)
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
  @spec read_only_tools(String.t()) :: [Tool.t()]
  def read_only_tools(project_root) when is_binary(project_root) do
    _project_root = project_root
    []
  end

  @doc "Builds the constrained tool list for inline edit rewrite sessions."
  @spec rewrite_tools(String.t()) :: [Tool.t()]
  def rewrite_tools(project_root) when is_binary(project_root) do
    Tools.file_read(project_root: project_root) ++ [produce_rewrite_tool()]
  end

  @spec start(String.t(), String.t(), String.t(), [Tool.t()], atom(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  defp start(prompt, project_root, prefix, tools, result_message, opts) do
    manager = Keyword.get(opts, :session_manager, SessionManager)
    editor_pid = Keyword.get(opts, :subscriber, self())

    session_opts = [
      session_id: "#{prefix}-#{System.unique_integer([:positive])}",
      session_store_dir: nil,
      startup_notice: nil,
      persist?: false,
      hooks_enabled?: false,
      provider_opts: [
        project_root: project_root,
        read_only?: true,
        tool_allowlist: Enum.map(tools, & &1.name),
        tools: tools
      ]
    ]

    case SessionManager.start_session(manager, session_opts) do
      {:ok, _session_id, pid} -> subscribe_and_prompt(pid, editor_pid, prompt, result_message)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec subscribe_and_prompt(pid(), pid(), String.t(), atom()) :: {:ok, pid()} | {:error, term()}
  defp subscribe_and_prompt(pid, editor_pid, prompt, result_message) do
    Session.subscribe(pid, editor_pid)
    send_prompt_when_ready(pid, prompt, result_message)
    {:ok, pid}
  catch
    :exit, reason ->
      stop(pid)
      {:error, reason}
  end

  @spec send_prompt_when_ready(pid(), String.t(), atom()) :: :ok
  defp send_prompt_when_ready(pid, prompt, result_message) do
    parent = self()

    Task.start(fn ->
      wait_for_provider(pid, 20)
      result = Session.send_prompt(pid, prompt)
      send(parent, {result_message, pid, result})
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

  @spec produce_rewrite_tool() :: Tool.t()
  defp produce_rewrite_tool do
    Tool.new!(
      name: "produce_rewrite",
      description:
        "Return the single replacement text for the selected inline edit range. This must not edit files.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "replacement" => %{
            "type" => "string",
            "description" => "Exact replacement text for the selected lines"
          }
        },
        "required" => ["replacement"]
      },
      callback: fn args -> {:ok, args["replacement"] || ""} end
    )
  end

  @spec assistant_text(MingaAgent.Message.t() | nil) :: String.t()
  defp assistant_text({:assistant, text}), do: text
  defp assistant_text(_message), do: ""
end
