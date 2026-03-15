defmodule Minga.LSP.Client.State do
  @moduledoc """
  Internal state for an `LSP.Client` GenServer.
  """

  alias Minga.LSP.ServerConfig

  @enforce_keys [:server_config, :root_path]
  defstruct [
    :server_config,
    :root_path,
    :port,
    :encoding,
    buffer: "",
    next_id: 1,
    started_at: nil,
    pending: %{},
    open_documents: %{},
    capabilities: %{},
    status: :starting,
    subscribers: []
  ]

  @typedoc "Client lifecycle status."
  @type status :: :starting | :initializing | :ready | :shutdown

  @typedoc "Caller for a pending request: a GenServer reply target, an async caller, or nil."
  @type pending_from :: GenServer.from() | {:async, pid(), reference()} | nil

  @typedoc "A pending request awaiting a response."
  @type pending_entry :: %{
          method: String.t(),
          from: pending_from(),
          timer: reference() | nil
        }

  @typedoc "An open document tracked by version."
  @type open_doc :: %{
          uri: String.t(),
          version: pos_integer()
        }

  @type t :: %__MODULE__{
          server_config: ServerConfig.t(),
          root_path: String.t(),
          port: port() | nil,
          encoding: Minga.LSP.PositionEncoding.encoding(),
          buffer: binary(),
          started_at: integer() | nil,
          next_id: pos_integer(),
          pending: %{integer() => pending_entry()},
          open_documents: %{String.t() => open_doc()},
          capabilities: map(),
          status: status(),
          subscribers: [pid()]
        }
end
