defmodule MingaAgent.Session.FileChange do
  @moduledoc "A committed file mutation with Session-owned references to its exact content."

  alias MingaAgent.ArtifactStore
  alias MingaAgent.Tool.Output.Codec
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.Tool.FileMutationResult
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tools.OutputCapture

  @type side :: :absent | :unavailable | Reference.t()
  @type identity :: {String.t(), String.t(), String.t()}
  @type t :: %__MODULE__{identity: identity(), path: String.t(), before: side(), after: side()}

  @enforce_keys [:identity, :path, :before, :after]
  defstruct @enforce_keys

  @doc "Captures both committed sides under delivery keys distinct from the tool output."
  @spec capture(GenServer.server() | nil, identity(), FileMutationResult.t()) :: t() | nil
  def capture(_store, _identity, %FileMutationResult{
        receipt: %{before: same, after: same}
      }),
      do: nil

  def capture(store, identity, %FileMutationResult{
        path: path,
        receipt: receipt
      }) do
    %__MODULE__{
      identity: identity,
      path: path,
      before: capture_side(store, identity, "before", receipt.before),
      after: capture_side(store, identity, "after", receipt.after)
    }
  end

  defp capture_side(_store, _identity, _side, :absent), do: :absent

  defp capture_side(store, identity, side, bytes) do
    key = delivery_key(identity, side)

    case OutputCapture.bytes(store, key, bytes,
           media_type: "application/octet-stream",
           view: "",
           optional?: true
         ) do
      {:ok, %Output{capture: :complete, reference: %Reference{} = reference}} ->
        reference

      _ ->
        ArtifactStore.release(store, key)
        :unavailable
    end
  catch
    :exit, _reason -> :unavailable
  end

  @doc "Releases temporary delivery pins after Session has answered the final commit attempt."
  @spec release_delivery(GenServer.server() | nil, t() | nil) :: :ok
  def release_delivery(nil, _change), do: :ok
  def release_delivery(_store, nil), do: :ok

  def release_delivery(store, %__MODULE__{} = change) do
    Enum.each([{"before", change.before}, {"after", change.after}], fn
      {side, %Reference{}} -> ArtifactStore.release(store, delivery_key(change.identity, side))
      _side -> :ok
    end)
  catch
    :exit, _reason -> :ok
  end

  @doc "Reclaims staged file sides for a checkpoint whose worker is no longer running."
  @spec reconcile_delivery(GenServer.server(), identity()) :: :ok | {:error, term()}
  def reconcile_delivery(store, identity) do
    with :ok <- reclaim_side(store, delivery_key(identity, "before")) do
      reclaim_side(store, delivery_key(identity, "after"))
    end
  end

  @spec reclaim_side(GenServer.server(), {:delivery, String.t(), String.t()}) ::
          :ok | {:error, term()}
  defp reclaim_side(store, key) do
    case ArtifactStore.lookup_delivery(store, key) do
      {:ok, _artifact} -> ArtifactStore.release(store, key)
      {:error, :unknown_delivery} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec delivery_key(identity(), String.t()) :: {:delivery, String.t(), String.t()}
  defp delivery_key(identity, side) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(identity))
    {:delivery, "file-change:" <> side, Base.url_encode64(digest, padding: false)}
  end

  @doc "Encodes only change metadata and artifact references, not file bytes."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = change) do
    {request, checkpoint, call} = change.identity

    %{
      "identity" => [request, checkpoint, call],
      "path" => change.path,
      "before" => encode_side(change.before),
      "after" => encode_side(change.after)
    }
  end

  @doc "Restores a change without confusing an absent path with unavailable content."
  @spec decode(term()) :: {:ok, t()} | {:error, :invalid_file_change}
  def decode(%{
        "identity" => [request, checkpoint, call],
        "path" => path,
        "before" => before_side,
        "after" => after_side
      })
      when is_binary(request) and is_binary(checkpoint) and is_binary(call) and
             is_binary(path) and byte_size(path) > 0 do
    with {:ok, before_side} <- decode_side(before_side),
         {:ok, after_side} <- decode_side(after_side) do
      {:ok,
       %__MODULE__{
         identity: {request, checkpoint, call},
         path: path,
         before: before_side,
         after: after_side
       }}
    end
  end

  def decode(_invalid), do: {:error, :invalid_file_change}

  @doc "Returns the artifacts that a durable Session snapshot must keep alive."
  @spec references(t()) :: [Reference.t()]
  def references(%__MODULE__{before: before_side, after: after_side}) do
    for %Reference{} = reference <- [before_side, after_side], do: reference
  end

  @doc "Counts attributed mutations by path without reading artifact bytes."
  @spec changed_file_counts([t()]) :: %{String.t() => pos_integer()}
  def changed_file_counts(changes), do: Enum.frequencies_by(changes, & &1.path)

  @doc "Finds the endpoints of an uninterrupted attributed lineage, newest change first."
  @spec cumulative_sides([t()], String.t()) ::
          {:ok, side(), side()} | {:error, :no_file_change | :discontinuous_file_change}
  def cumulative_sides(changes, path) do
    Enum.reduce_while(changes, {:error, :no_file_change}, fn
      %__MODULE__{path: ^path, before: before_side, after: after_side},
      {:error, :no_file_change} ->
        {:cont, {:ok, before_side, after_side}}

      %__MODULE__{path: ^path, before: before_side, after: after_side},
      {:ok, next_before, latest} ->
        if same_content?(after_side, next_before),
          do: {:cont, {:ok, before_side, latest}},
          else: {:halt, {:error, :discontinuous_file_change}}

      _unrelated, acc ->
        {:cont, acc}
    end)
  end

  @spec same_content?(side(), side()) :: boolean()
  defp same_content?(:absent, :absent), do: true
  defp same_content?(%Reference{sha256: hash}, %Reference{sha256: hash}), do: true
  defp same_content?(_first, _second), do: false

  @doc "Fetches a complete bounded review side. Missing content never becomes an empty file."
  @spec read_side(GenServer.server(), side()) :: {:ok, binary() | :absent} | {:error, term()}
  def read_side(_store, :absent), do: {:ok, :absent}
  def read_side(_store, :unavailable), do: {:error, :snapshot_unavailable}

  def read_side(store, %Reference{bytes: size} = reference) when size <= 65_536 do
    with {:ok, range} <- Range.new(:full, :bytes, 0, size, size),
         {:ok, %{bytes: bytes}} <- ArtifactStore.fetch(store, reference, range) do
      {:ok, bytes}
    end
  end

  def read_side(_store, %Reference{}), do: {:error, :snapshot_too_large}

  defp encode_side(:absent), do: "absent"
  defp encode_side(:unavailable), do: "unavailable"
  defp encode_side(%Reference{} = reference), do: Codec.encode_reference(reference)

  defp decode_side("absent"), do: {:ok, :absent}
  defp decode_side("unavailable"), do: {:ok, :unavailable}

  defp decode_side(encoded) do
    case Codec.decode_reference(encoded) do
      {:ok, %Reference{} = reference} -> {:ok, reference}
      _ -> {:error, :invalid_file_change}
    end
  end
end
