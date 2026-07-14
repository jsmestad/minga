defmodule MingaEditor.State.AgentConnection do
  @moduledoc """
  Agent provider configuration and live editor ingest connection.

  Provider configuration is immutable after startup; the ingest process may be
  replaced as the editor's supervised agent integration restarts.
  """

  @type t :: %__MODULE__{
          agent_ingest: pid() | nil,
          agent_provider_module: module() | nil,
          agent_provider_opts: keyword()
        }

  defstruct agent_ingest: nil,
            agent_provider_module: nil,
            agent_provider_opts: []

  @doc "Creates agent connection state from startup provider configuration."
  @spec new(module() | nil, keyword()) :: t()
  def new(provider_module \\ nil, provider_opts \\ []) when is_list(provider_opts) do
    %__MODULE__{
      agent_provider_module: provider_module,
      agent_provider_opts: provider_opts
    }
  end

  @doc "Records the supervised stream-ingest process serving this editor."
  @spec connect_ingest(t(), pid() | nil) :: t()
  def connect_ingest(%__MODULE__{} = connection, ingest)
      when is_pid(ingest) or is_nil(ingest),
      do: %{connection | agent_ingest: ingest}
end
