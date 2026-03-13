defmodule Minga.Agent.Provider do
  @moduledoc """
  Behaviour for AI agent provider backends.

  A provider manages the connection to an AI agent (LLM API, subprocess,
  etc.) and translates between the provider's native protocol and Minga's
  internal `Agent.Event` structs. The provider process runs under the
  agent supervisor and is crash-isolated from the editor.

  ## Implementing a provider

      defmodule MyProvider do
        @behaviour Minga.Agent.Provider

        use GenServer

        @impl Minga.Agent.Provider
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

        @impl Minga.Agent.Provider
        def send_prompt(pid, text), do: GenServer.cast(pid, {:prompt, text})

        # ... other callbacks
      end

  Events are delivered to the subscriber (typically `Agent.Session`) as
  `{:agent_provider_event, event}` messages where `event` is an
  `Agent.Event` struct.
  """

  alias Minga.Agent.Event

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
          model: model_info() | nil,
          is_streaming: boolean(),
          token_usage: Event.token_usage() | nil
        }

  @doc """
  Starts the provider process.

  Options must include `:subscriber` (the pid that receives events).
  Provider-specific options (model, binary path, etc.) are also passed here.
  """
  @callback start_link(opts()) :: GenServer.on_start()

  @doc "Sends a user prompt to the agent. Returns immediately; responses arrive as events."
  @callback send_prompt(provider(), String.t()) :: :ok | {:error, term()}

  @doc "Aborts the current agent operation."
  @callback abort(provider()) :: :ok

  @doc "Starts a fresh agent session, clearing conversation history."
  @callback new_session(provider()) :: :ok | {:error, term()}

  @doc "Returns the current session state (model info, streaming status, etc.)."
  @callback get_state(provider()) :: {:ok, session_state()} | {:error, term()}

  @doc "Returns available models from the provider."
  @callback get_available_models(provider()) :: {:ok, [map()]} | {:error, term()}

  @doc "Returns available commands (extensions, skills, prompts) from the provider."
  @callback get_commands(provider()) :: {:ok, [map()]} | {:error, term()}

  @doc ~S'Sets the thinking level (e.g. "low", "medium", "high").'
  @callback set_thinking_level(provider(), String.t()) :: :ok | {:error, term()}

  @doc "Cycles to the next thinking level and returns the new level."
  @callback cycle_thinking_level(provider()) :: {:ok, term()} | {:error, term()}

  @doc "Cycles to the next model in the configured model rotation."
  @callback cycle_model(provider()) :: {:ok, map()} | {:error, term()}

  @doc "Sets the model without resetting conversation context."
  @callback set_model(provider(), String.t()) :: :ok | {:error, term()}

  @optional_callbacks [
    get_available_models: 1,
    get_commands: 1,
    set_thinking_level: 2,
    cycle_thinking_level: 1,
    cycle_model: 1,
    set_model: 2
  ]
end
