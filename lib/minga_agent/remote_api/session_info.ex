defmodule MingaAgent.RemoteAPI.SessionInfo do
  @moduledoc "Session record returned by the remote API broker."

  alias MingaAgent.SessionListing
  alias MingaAgent.SessionMetadata

  @typedoc "Metadata accepted from current and compatible older remote nodes."
  @type metadata :: SessionMetadata.t() | map()

  @typedoc "Explicit metadata availability for a remote session."
  @type details :: {:available, metadata()} | {:unavailable, SessionListing.unavailable_reason()}

  @metadata_keys [
    :id,
    :title,
    :model_name,
    :provider_name,
    :created_at,
    :last_message_at,
    :message_count,
    :turn_count,
    :first_prompt,
    :cost,
    :status,
    :workdir
  ]

  @enforce_keys [:session_id, :pid, :token, :details, :metadata]
  defstruct [:session_id, :pid, :token, :details, :metadata]

  @type t :: %__MODULE__{
          session_id: String.t(),
          pid: pid(),
          token: String.t(),
          details: details(),
          metadata: metadata() | nil
        }

  @doc "Creates a session info record with available metadata."
  @spec new(String.t(), pid(), String.t(), SessionMetadata.t()) :: t()
  def new(session_id, pid, token, %SessionMetadata{} = metadata)
      when is_binary(session_id) and is_pid(pid) and is_binary(token) do
    listing = SessionListing.available(session_id, pid, metadata)
    from_listing(listing, token)
  end

  @doc "Creates a remote session record from a manager-owned listing and token."
  @spec from_listing(SessionListing.t(), String.t()) :: t()
  def from_listing(%SessionListing{id: session_id, pid: pid, details: details}, token)
      when is_binary(token) do
    %__MODULE__{
      session_id: session_id,
      pid: pid,
      token: token,
      details: details,
      metadata: available_metadata(details)
    }
  end

  @doc "Normalizes a remote session listing while preserving its order."
  @spec normalize_all(term()) :: {:ok, [t()]} | {:error, :unsupported_session_listing}
  def normalize_all(sessions) when is_list(sessions) do
    sessions
    |> Enum.reduce_while({:ok, []}, &normalize_entry/2)
    |> reverse_normalized()
  end

  def normalize_all(_sessions), do: {:error, :unsupported_session_listing}

  @doc "Normalizes current and supported older remote listing records."
  @spec normalize(term()) :: {:ok, t()} | {:error, :unsupported_session_listing}
  def normalize(%__MODULE__{} = info), do: normalize_map(info)

  def normalize(%{session_id: _session_id, pid: _pid, token: _token} = info),
    do: normalize_map(info)

  def normalize(_info), do: {:error, :unsupported_session_listing}

  @spec normalize_map(map()) :: {:ok, t()} | {:error, :unsupported_session_listing}
  defp normalize_map(%{session_id: session_id, pid: pid, token: token, details: details})
       when is_binary(session_id) and is_pid(pid) and is_binary(token) do
    normalize_details(session_id, pid, token, details)
  end

  defp normalize_map(%{session_id: session_id, pid: pid, token: token, metadata: metadata})
       when is_binary(session_id) and is_pid(pid) and is_binary(token) do
    normalize_available_metadata(session_id, pid, token, metadata)
  end

  defp normalize_map(_info), do: {:error, :unsupported_session_listing}

  @spec normalize_details(String.t(), pid(), String.t(), term()) ::
          {:ok, t()} | {:error, :unsupported_session_listing}
  defp normalize_details(session_id, pid, token, {:available, metadata}) do
    normalize_available_metadata(session_id, pid, token, metadata)
  end

  defp normalize_details(session_id, pid, token, {:unavailable, reason})
       when reason in [:timeout, :unreachable, :invalid_details] do
    {:ok,
     %__MODULE__{
       session_id: session_id,
       pid: pid,
       token: token,
       details: {:unavailable, reason},
       metadata: nil
     }}
  end

  defp normalize_details(_session_id, _pid, _token, _details),
    do: {:error, :unsupported_session_listing}

  @spec normalize_available_metadata(String.t(), pid(), String.t(), term()) ::
          {:ok, t()} | {:error, :unsupported_session_listing}
  defp normalize_available_metadata(session_id, pid, token, %SessionMetadata{} = metadata) do
    {:ok, new(session_id, pid, token, metadata)}
  end

  defp normalize_available_metadata(session_id, pid, token, metadata) when is_map(metadata) do
    normalize_metadata_map(session_id, pid, token, metadata, supported_metadata_map?(metadata))
  end

  defp normalize_available_metadata(_session_id, _pid, _token, _metadata),
    do: {:error, :unsupported_session_listing}

  @spec normalize_metadata_map(String.t(), pid(), String.t(), map(), boolean()) ::
          {:ok, t()} | {:error, :unsupported_session_listing}
  defp normalize_metadata_map(session_id, pid, token, %{id: session_id} = metadata, true) do
    {:ok,
     %__MODULE__{
       session_id: session_id,
       pid: pid,
       token: token,
       details: {:available, metadata},
       metadata: metadata
     }}
  end

  defp normalize_metadata_map(session_id, pid, token, _metadata, true) do
    {:ok,
     %__MODULE__{
       session_id: session_id,
       pid: pid,
       token: token,
       details: {:unavailable, :invalid_details},
       metadata: nil
     }}
  end

  defp normalize_metadata_map(_session_id, _pid, _token, _metadata, false),
    do: {:error, :unsupported_session_listing}

  @spec supported_metadata_map?(map()) :: boolean()
  defp supported_metadata_map?(metadata) do
    Enum.all?(@metadata_keys, &Map.has_key?(metadata, &1))
  end

  @spec available_metadata(details()) :: metadata() | nil
  defp available_metadata({:available, metadata}), do: metadata
  defp available_metadata({:unavailable, _reason}), do: nil

  @spec normalize_entry(term(), {:ok, [t()]}) ::
          {:cont, {:ok, [t()]}} | {:halt, {:error, :unsupported_session_listing}}
  defp normalize_entry(session, {:ok, normalized}) do
    case normalize(session) do
      {:ok, info} -> {:cont, {:ok, [info | normalized]}}
      {:error, :unsupported_session_listing} = error -> {:halt, error}
    end
  end

  @spec reverse_normalized({:ok, [t()]} | {:error, :unsupported_session_listing}) ::
          {:ok, [t()]} | {:error, :unsupported_session_listing}
  defp reverse_normalized({:ok, sessions}), do: {:ok, Enum.reverse(sessions)}
  defp reverse_normalized({:error, :unsupported_session_listing} = error), do: error
end
