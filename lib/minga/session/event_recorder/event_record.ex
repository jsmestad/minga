defmodule Minga.Session.EventRecorder.EventRecord do
  @moduledoc """
  A single recorded event from the editor's event stream.

  This struct represents one row in the event log. It carries both
  monotonic and wall-clock timestamps: monotonic for ordering and
  duration math, wall-clock for human display and retention queries.

  The `payload` field stores event-specific data as a map, serialized
  to JSON in SQLite. The `source` field uses the string representation
  of `EditSource.t()` for queryability (you can't store Elixir terms
  in SQLite and query them with SQL).
  """

  @enforce_keys [:timestamp, :wall_clock, :source, :scope, :event_type]
  defstruct [:id, :timestamp, :wall_clock, :source, :scope, :event_type, payload: %{}]

  @type scope :: {:buffer, String.t()} | {:session, String.t()} | :global

  @type t :: %__MODULE__{
          id: integer() | nil,
          timestamp: integer(),
          wall_clock: DateTime.t(),
          source: String.t(),
          scope: scope(),
          event_type: atom(),
          payload: map()
        }

  @doc """
  Encodes an `EditSource.t()` to a string for SQLite storage.

  Returns a human-readable string that's also queryable with SQL LIKE/=.
  """
  @spec encode_source(Minga.Buffer.EditSource.t()) :: String.t()
  def encode_source(:user), do: "user"
  def encode_source(:formatter), do: "formatter"
  def encode_source(:unknown), do: "unknown"

  def encode_source({:agent, session_pid, tool_call_id}) do
    "agent:#{inspect(session_pid)}:#{tool_call_id}"
  end

  def encode_source({:lsp, server_name}) do
    "lsp:#{server_name}"
  end

  @doc """
  Encodes a scope to a string for SQLite storage.
  """
  @spec encode_scope(scope()) :: String.t()
  def encode_scope(:global), do: "global"
  def encode_scope({:buffer, path}) when is_binary(path), do: "buffer:#{path}"
  def encode_scope({:session, id}) when is_binary(id), do: "session:#{id}"

  @doc """
  Decodes a scope string from SQLite back to the Elixir type.
  """
  @spec decode_scope(String.t()) :: scope()
  def decode_scope("global"), do: :global

  def decode_scope("buffer:" <> path), do: {:buffer, path}

  def decode_scope("session:" <> id), do: {:session, id}
end
