defmodule MingaAgent.Provider do
  @moduledoc """
  Behaviour for AI agent provider backends.

  A provider manages the connection to an AI agent (LLM API, subprocess,
  etc.) and translates between the provider's native protocol and Minga's
  internal `Agent.Event` structs. The provider process runs under the
  agent supervisor and is crash-isolated from the editor.

  ## Implementing a provider

      defmodule MyProvider do
        @behaviour MingaAgent.Provider

        use GenServer

        @impl MingaAgent.Provider
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

        @impl MingaAgent.Provider
        def send_prompt(pid, request), do: GenServer.call(pid, {:prompt, request})
        # ... other callbacks
      end

  Turn-scoped events are delivered to the subscriber (typically `Agent.Session`)
  as `{:agent_provider_event, request_id, event}`. Session rejects events whose
  request identity is no longer active.
  """

  alias MingaAgent.Event
  alias MingaAgent.ModelCandidate
  alias MingaAgent.ModelSelection
  @typedoc "Provider configuration options."
  @type opts :: keyword()

  @typedoc "Provider state reference (pid or name)."
  @type provider :: GenServer.server()

  @typedoc "Model information returned by the provider."
  @type model_info :: %{
          id: String.t(),
          name: String.t(),
          provider: String.t()
        }

  @typedoc "Session state returned by the provider."
  @type session_state :: %{
          optional(:system_prompt) => String.t() | nil,
          optional(:thinking_level) => String.t() | nil,
          optional(:active_skill_names) => [String.t()],
          optional(:project_root) => String.t() | nil,
          optional(:mcp_status) => [map()],
          optional(:model_selection) => ModelSelection.t(),
          model: model_info() | String.t() | nil,
          is_streaming: boolean(),
          token_usage: Event.token_usage() | nil
        }

  @doc """
  Starts the provider process.

  Options must include `:subscriber` (the pid that receives events).
  Provider-specific options (model, binary path, etc.) are also passed here.
  """
  @callback start_link(opts()) :: GenServer.on_start()

  @doc "Starts work from an immutable, versioned request snapshot."
  @callback send_prompt(provider(), MingaAgent.Session.Request.t()) :: :ok | {:error, term()}

  @doc "Aborts the current agent operation."
  @callback abort(provider()) :: :ok

  @doc "Resets provider runtime state for a fresh Session-owned conversation."
  @callback new_session(provider()) :: :ok | {:error, term()}

  @doc "Continues work from an immutable, versioned request snapshot."
  @callback continue(provider(), MingaAgent.Session.Request.t()) :: :ok | {:error, term()}

  @doc "Compacts an immutable continuation and returns its replacement messages."
  @callback compact(provider(), [ReqLLM.Message.t()]) ::
              {:ok, [ReqLLM.Message.t()], String.t()} | {:error, term()}

  @doc "Returns the current session state (model info, streaming status, etc.)."
  @callback get_state(provider()) :: {:ok, session_state()} | {:error, term()}

  @doc "Returns exact resolved model route candidates from the provider."
  @callback get_available_models(provider()) ::
              {:ok, [ModelCandidate.t()]} | {:error, term()}

  @doc "Returns available commands (extensions, skills, prompts) from the provider."
  @callback get_commands(provider()) :: {:ok, [map()]} | {:error, term()}

  @doc ~S'Sets the thinking level (e.g. "low", "medium", "high").'
  @callback set_thinking_level(provider(), String.t()) :: :ok | {:error, term()}

  @doc "Cycles to the next thinking level and returns the new level."
  @callback cycle_thinking_level(provider()) :: {:ok, term()} | {:error, term()}

  @doc "Requests cycling; Session-owned resolvers should normally perform this transition."
  @callback cycle_model(provider()) :: {:ok, map()} | {:error, term()}

  @doc "Installs an already-resolved model selection without resetting conversation context."
  @callback set_model(provider(), ModelSelection.t()) :: :ok | {:error, term()}

  @optional_callbacks [
    get_available_models: 1,
    get_commands: 1,
    set_thinking_level: 2,
    cycle_thinking_level: 1,
    cycle_model: 1,
    set_model: 2,
    continue: 2,
    compact: 2
  ]
end
