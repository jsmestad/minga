defmodule MingaAgent.EventLog.TouchedFiles do
  @moduledoc """
  Projects the latest admitted file edit for each path in an agent session.

  Durable event ids define recency. Replaying the same event or an older event
  cannot replace a newer touch for the same path.
  """

  alias MingaAgent.EventLog.EventRecord

  @typedoc "How the latest admitted edit changed a file."
  @type action :: :created | :modified | :deleted

  @typedoc "Extension-facing summary of one touched file."
  @type touch :: %{path: String.t(), action: action(), timestamp: integer()}

  @typedoc "Why a file-edit event cannot enter the projection."
  @type rejection ::
          {:invalid_file_edit, :event_id | :path | :before_content | :after_content}

  @typep entry :: {event_id :: pos_integer(), action(), timestamp :: integer()}
  @typep session_entries :: %{String.t() => entry()}

  @type t :: %__MODULE__{by_session: %{String.t() => session_entries()}}

  defstruct by_session: %{}

  @doc "Creates an empty touched-file projection."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Validates fields required to project a file-edit event."
  @spec validate(EventRecord.t()) :: :ok | {:error, rejection()}
  def validate(%EventRecord{event_type: :file_edit_proposed, payload: payload}) do
    with :ok <- validate_binary(payload, "path", :path),
         :ok <- validate_binary(payload, "before_content", :before_content) do
      validate_binary(payload, "after_content", :after_content)
    end
  end

  def validate(%EventRecord{}), do: :ok

  @doc "Applies one durably identified event to the projection."
  @spec record(t(), EventRecord.t(), pos_integer()) :: {:ok, t()} | {:error, rejection()}
  def record(
        %__MODULE__{},
        %EventRecord{event_type: :file_edit_proposed},
        event_id
      )
      when not is_integer(event_id) or event_id <= 0,
      do: {:error, {:invalid_file_edit, :event_id}}

  def record(
        %__MODULE__{} = projection,
        %EventRecord{event_type: :file_edit_proposed} = event,
        event_id
      ) do
    with :ok <- validate(event) do
      {:ok, put_latest(projection, event, event_id)}
    end
  end

  def record(%__MODULE__{} = projection, %EventRecord{}, _event_id), do: {:ok, projection}

  @doc "Rebuilds the projection from persisted events in durable order."
  @spec rebuild([EventRecord.t()]) :: {:ok, t()} | {:error, rejection()}
  def rebuild(events) when is_list(events) do
    Enum.reduce_while(events, {:ok, new()}, fn event, {:ok, projection} ->
      case record(projection, event, event.id) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc "Lists one session's latest file touches, most recent first."
  @spec list(t(), String.t()) :: [touch()]
  def list(%__MODULE__{} = projection, session_id) when is_binary(session_id) do
    projection.by_session
    |> Map.get(session_id, %{})
    |> Enum.sort_by(fn {_path, {event_id, _action, _timestamp}} -> event_id end, :desc)
    |> Enum.map(fn {path, {_event_id, action, timestamp}} ->
      %{path: path, action: action, timestamp: timestamp}
    end)
  end

  @spec validate_binary(map(), String.t(), :path | :before_content | :after_content) ::
          :ok | {:error, rejection()}
  defp validate_binary(payload, key, field) do
    case Map.get(payload, key) do
      value when is_binary(value) -> :ok
      _other -> {:error, {:invalid_file_edit, field}}
    end
  end

  @spec put_latest(t(), EventRecord.t(), pos_integer()) :: t()
  defp put_latest(projection, event, event_id) do
    path = event.payload["path"]
    entries = Map.get(projection.by_session, event.session_id, %{})

    case Map.get(entries, path) do
      {current_id, _action, _timestamp} when current_id >= event_id ->
        projection

      _current ->
        entry = {event_id, action(event.payload), event.monotonic_ts}

        by_session =
          Map.put(projection.by_session, event.session_id, Map.put(entries, path, entry))

        %{projection | by_session: by_session}
    end
  end

  @spec action(map()) :: action()
  defp action(%{"before_content" => "", "after_content" => after_content})
       when byte_size(after_content) > 0,
       do: :created

  defp action(%{"before_content" => before_content, "after_content" => ""})
       when byte_size(before_content) > 0,
       do: :deleted

  defp action(_payload), do: :modified
end
