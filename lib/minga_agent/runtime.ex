defmodule MingaAgent.Runtime do
  @moduledoc """
  Public API for the Minga agent runtime.

  Unifies session management, tool execution, and introspection into
  a single entry point. External clients (API gateway, CLI tools, IDE
  extensions) should call this module rather than reaching into
  SessionManager, Tool.Registry, or Tool.Executor directly.

  All functions here are Layer 1 (MingaAgent.*). They work in both
  headless mode (`Minga.Runtime.start/1`) and full editor mode.
  """

  # ── Session lifecycle ────────────────────────────────────────────────────────

  @doc "Starts a new agent session. Returns `{:ok, session_id, pid}`."
  @spec start_session(keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  defdelegate start_session(opts \\ []), to: MingaAgent.SessionManager

  @doc "Stops a session by its human-readable ID."
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  defdelegate stop_session(session_id), to: MingaAgent.SessionManager

  @doc "Sends a user prompt to a session."
  @spec send_prompt(String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate send_prompt(session_id, prompt), to: MingaAgent.SessionManager

  @doc "Aborts the current operation on a session."
  @spec abort(String.t()) :: :ok | {:error, :not_found}
  defdelegate abort(session_id), to: MingaAgent.SessionManager

  @doc "Lists all active sessions as `{id, pid, metadata}` tuples."
  @spec list_sessions() :: [{String.t(), pid(), MingaAgent.SessionMetadata.t()}]
  defdelegate list_sessions(), to: MingaAgent.SessionManager

  @doc "Looks up the PID for a session ID."
  @spec get_session(String.t()) :: {:ok, pid()} | {:error, :not_found}
  defdelegate get_session(session_id), to: MingaAgent.SessionManager

  # ── Tool operations ─────────────────────────────────────────────────────────

  @doc "Executes a tool by name with the given arguments."
  @spec execute_tool(String.t(), map()) :: MingaAgent.Tool.Executor.result()
  defdelegate execute_tool(name, args), to: MingaAgent.Tool.Executor, as: :execute

  @doc "Returns all registered tool specs."
  @spec list_tools() :: [MingaAgent.Tool.Spec.t()]
  defdelegate list_tools(), to: MingaAgent.Tool.Registry, as: :all

  @doc "Looks up a tool spec by name."
  @spec get_tool(String.t()) :: {:ok, MingaAgent.Tool.Spec.t()} | :error
  defdelegate get_tool(name), to: MingaAgent.Tool.Registry, as: :lookup

  @doc "Returns true if a tool with the given name is registered."
  @spec tool_registered?(String.t()) :: boolean()
  defdelegate tool_registered?(name), to: MingaAgent.Tool.Registry, as: :registered?

  # ── Introspection ───────────────────────────────────────────────────────────

  @doc "Returns a capabilities manifest describing the runtime."
  @spec capabilities() :: MingaAgent.Introspection.capabilities_manifest()
  defdelegate capabilities(), to: MingaAgent.Introspection

  @doc "Returns structured descriptions of all registered tools."
  @spec describe_tools() :: [MingaAgent.Introspection.tool_description()]
  defdelegate describe_tools(), to: MingaAgent.Introspection

  @doc "Returns structured descriptions of all active sessions."
  @spec describe_sessions() :: [MingaAgent.Introspection.session_description()]
  defdelegate describe_sessions(), to: MingaAgent.Introspection

  # ── Gateway ─────────────────────────────────────────────────────────────────

  @doc """
  Starts the API gateway (WebSocket + JSON-RPC).

  Does not start by default. Call explicitly from headless mode or when
  external clients need to connect. The Editor boot path never calls this.

  Options:
    * `:port` - TCP port to listen on (default: 4820)
  """
  @spec start_gateway(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_gateway(opts \\ []) do
    DynamicSupervisor.start_child(
      MingaAgent.Supervisor,
      {MingaAgent.Gateway.Server, opts}
    )
  end
end
