defmodule MingaAgent.Session.ChecklistArchive do
  @moduledoc "Keeps checklist facts at resumable transcript boundaries and in frozen branch heads."

  alias MingaAgent.Checklist
  alias MingaAgent.Tool.Output.Reference

  @typep history :: %{optional(pos_integer()) => Checklist.t()}
  @typep branch :: {history(), Checklist.t()}
  @opaque t :: %__MODULE__{
            active: history(),
            last_boundary: non_neg_integer(),
            branches: %{optional(String.t()) => branch()}
          }
  defstruct active: %{}, last_boundary: 0, branches: %{}

  @doc "Returns an archive with no recorded checklist turns."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Records changed task facts at the exact resumable transcript boundary."
  @spec record(t(), pos_integer(), Checklist.t()) :: t()
  def record(%__MODULE__{active: active} = archive, transcript_id, checklist) do
    if Map.get(active, archive.last_boundary, Checklist.new()) == checklist,
      do: archive,
      else: %{
        archive
        | active: Map.put(active, transcript_id, checklist),
          last_boundary: transcript_id
      }
  end

  @doc "Freezes the outgoing checklist history and selects the last write at the fork boundary."
  @spec fork(t(), String.t(), pos_integer(), Checklist.t()) :: {Checklist.t(), t()}
  def fork(%__MODULE__{} = archive, name, transcript_id, outgoing) do
    active = Map.filter(archive.active, fn {turn_id, _} -> turn_id <= transcript_id end)
    branches = Map.put(archive.branches, name, {archive.active, outgoing})
    {last_boundary, checklist} = latest(active)
    {checklist, %{archive | active: active, last_boundary: last_boundary, branches: branches}}
  end

  @doc "Selects the frozen checklist for the branch. Older branches contain no task history."
  @spec switch(t(), String.t()) :: {Checklist.t(), t()}
  def switch(%__MODULE__{} = archive, name) do
    {active, checklist} = Map.get(archive.branches, name, {%{}, Checklist.new()})
    {last_boundary, _recorded} = latest(active)
    {checklist, %{archive | active: active, last_boundary: last_boundary}}
  end

  @doc "Returns the references retained by current and frozen checklist histories."
  @spec references(t()) :: [Reference.t()]
  def references(%__MODULE__{} = archive) do
    Enum.reduce(archive.branches, history_references(archive.active, []), fn
      {_name, {history, head}}, acc ->
        history_references(history, Checklist.references(head) ++ acc)
    end)
  end

  @doc "Encodes a versioned archive under the existing conversation record."
  @spec encode(t()) :: map() | nil
  def encode(%__MODULE__{active: active, branches: branches})
      when map_size(active) == 0 and map_size(branches) == 0,
      do: nil

  def encode(%__MODULE__{active: active, branches: branches}) do
    %{
      "version" => 1,
      "active" => encode_history(active),
      "branches" =>
        Map.new(branches, fn {id, {history, head}} ->
          {id, %{"history" => encode_history(history), "head" => Checklist.encode(head)}}
        end)
    }
  end

  @doc "Decodes a versioned archive without silently dropping invalid saved task facts."
  @spec decode(term()) :: {:ok, t()} | {:error, :invalid_checklist_archive}
  def decode(%{"version" => 1, "active" => active, "branches" => branches})
      when is_map(branches) do
    with {:ok, active} <- decode_history(active),
         {:ok, branches} <- decode_branches(branches) do
      {last_boundary, _recorded} = latest(active)
      {:ok, %__MODULE__{active: active, last_boundary: last_boundary, branches: branches}}
    end
  end

  def decode(_invalid), do: {:error, :invalid_checklist_archive}

  @spec latest(history()) :: {non_neg_integer(), Checklist.t()}
  defp latest(history), do: Enum.max_by(history, &elem(&1, 0), fn -> {0, Checklist.new()} end)

  @spec history_references(history(), [Reference.t()]) :: [Reference.t()]
  defp history_references(history, acc) do
    Enum.reduce(history, acc, fn {_turn, checklist}, refs ->
      Checklist.references(checklist) ++ refs
    end)
  end

  @spec encode_history(history()) :: %{String.t() => map()}
  defp encode_history(history) do
    Map.new(history, fn {turn, checklist} ->
      {Integer.to_string(turn), Checklist.encode(checklist)}
    end)
  end

  @spec decode_history(term()) :: {:ok, history()} | {:error, :invalid_checklist_archive}
  defp decode_history(history) when is_map(history) do
    Enum.reduce_while(history, {:ok, %{}}, fn {key, value}, {:ok, decoded} ->
      with true <- is_binary(key),
           {id, ""} when id > 0 <- Integer.parse(key),
           false <- Map.has_key?(decoded, id),
           {:ok, checklist} <- Checklist.decode(value) do
        {:cont, {:ok, Map.put(decoded, id, checklist)}}
      else
        _invalid -> {:halt, {:error, :invalid_checklist_archive}}
      end
    end)
  end

  defp decode_history(_invalid), do: {:error, :invalid_checklist_archive}

  @spec decode_branches(map()) ::
          {:ok, %{optional(String.t()) => branch()}} | {:error, :invalid_checklist_archive}
  defp decode_branches(branches) do
    Enum.reduce_while(branches, {:ok, %{}}, fn
      {name, %{"history" => history, "head" => head}}, {:ok, decoded} ->
        with {:ok, history} <- decode_history(history),
             {:ok, head} <- Checklist.decode(head) do
          {:cont, {:ok, Map.put(decoded, name, {history, head})}}
        else
          {:error, _reason} -> {:halt, {:error, :invalid_checklist_archive}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_checklist_archive}}
    end)
  end
end
