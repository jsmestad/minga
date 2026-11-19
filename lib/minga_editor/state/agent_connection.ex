defmodule MingaEditor.State.AgentConnection do
  @moduledoc """
  Agent provider configuration and live editor ingest connection.

  Provider configuration is immutable after startup; the ingest process may be
  replaced as the editor's supervised agent integration restarts.
  """

  @type t :: %__MODULE__{
          agent_ingest: pid() | nil,
          agent_provider_module: module() | nil,
          agent_provider_opts: keyword(),
          question_receipts: %{pid() => binary()}
        }

  @derive {Inspect, except: [:question_receipts]}
  defstruct agent_ingest: nil,
            agent_provider_module: nil,
            agent_provider_opts: [],
            question_receipts: %{}

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

  @doc "Keeps the private remote driver receipt only in live editor memory."
  @spec remember_question_receipt(t(), pid(), binary()) :: t()
  def remember_question_receipt(%__MODULE__{} = connection, session, receipt)
      when is_pid(session) and is_binary(receipt) and byte_size(receipt) == 32 do
    %{connection | question_receipts: Map.put(connection.question_receipts, session, receipt)}
  end

  @doc "Drops a remote driver's local receipt when its session goes away."
  @spec forget_question_receipt(t(), pid()) :: t()
  def forget_question_receipt(%__MODULE__{} = connection, session) when is_pid(session),
    do: %{connection | question_receipts: Map.delete(connection.question_receipts, session)}
end
