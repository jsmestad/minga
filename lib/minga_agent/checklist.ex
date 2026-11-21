defmodule MingaAgent.Checklist do
  @moduledoc "The ordered task facts saved with one Agent conversation."

  alias MingaAgent.TodoItem
  alias MingaAgent.Tool.Output.Codec
  alias MingaAgent.Tool.Output.Reference

  @max_items 100
  @max_revision 9_007_199_254_740_991
  @statuses %{
    "pending" => :pending,
    "in_progress" => :in_progress,
    "blocked" => :blocked,
    "done" => :done
  }

  @typep source :: :resolved | :stored

  @opaque t :: %__MODULE__{revision: non_neg_integer(), items: [TodoItem.t()]}
  @type rejection ::
          :invalid_checklist | :revision_exhausted | {:stale_revision, non_neg_integer()}
  defstruct revision: 0, items: []

  @doc "Returns the empty checklist used by older conversations and new sessions."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns the revision and task facts together."
  @spec snapshot(t()) :: {non_neg_integer(), [TodoItem.t()]}
  def snapshot(%__MODULE__{revision: revision, items: items}), do: {revision, items}

  @doc "Returns immutable result references retained by the owning session snapshot."
  @spec references(t()) :: [Reference.t()]
  def references(%__MODULE__{items: items}) do
    for %TodoItem{result_ref: %Reference{} = reference} <- items, do: reference
  end

  @doc "Replaces the ordered list only at the expected revision."
  @spec replace(t(), non_neg_integer(), term()) :: {:ok, t()} | {:error, rejection()}
  def replace(%__MODULE__{revision: @max_revision}, @max_revision, _items),
    do: {:error, :revision_exhausted}

  def replace(%__MODULE__{revision: revision}, revision, items) do
    with {:ok, items} <- parse_items(items, :resolved),
         do: {:ok, %__MODULE__{revision: revision + 1, items: items}}
  end

  def replace(%__MODULE__{revision: revision}, _expected, _items),
    do: {:error, {:stale_revision, revision}}

  @doc "Encodes only durable task facts, never current processes or tool authority."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{revision: revision, items: items}) do
    %{"version" => 1, "revision" => revision, "items" => Enum.map(items, &encode_item/1)}
  end

  @doc "Restores a bounded checklist, rejecting malformed or unknown versions."
  @spec decode(term()) :: {:ok, t()} | {:error, :invalid_checklist}
  def decode(%{"version" => 1, "revision" => revision, "items" => items})
      when is_integer(revision) and revision in 0..@max_revision do
    with {:ok, items} <- parse_items(items, :stored),
         do: {:ok, %__MODULE__{revision: revision, items: items}}
  end

  def decode(_value), do: {:error, :invalid_checklist}

  @spec parse_items(term(), source()) :: {:ok, [TodoItem.t()]} | {:error, :invalid_checklist}
  defp parse_items(items, source), do: parse_items(items, source, @max_items, %{}, [])

  @spec parse_items(term(), source(), non_neg_integer(), %{optional(String.t()) => true}, [
          TodoItem.t()
        ]) ::
          {:ok, [TodoItem.t()]} | {:error, :invalid_checklist}
  defp parse_items([], _source, _remaining, _seen, parsed), do: {:ok, Enum.reverse(parsed)}

  defp parse_items([item | rest], source, remaining, seen, parsed) when remaining > 0 do
    case parse_item(item, source) do
      {:ok, %TodoItem{id: id} = parsed_item} when not is_map_key(seen, id) ->
        parse_items(rest, source, remaining - 1, Map.put(seen, id, true), [parsed_item | parsed])

      _invalid_or_duplicate ->
        {:error, :invalid_checklist}
    end
  end

  defp parse_items(_items, _source, _remaining, _seen, _parsed), do: {:error, :invalid_checklist}

  @spec parse_item(term(), source()) :: {:ok, TodoItem.t()} | {:error, :invalid_checklist}
  defp parse_item(%{"id" => id, "description" => description} = item, source) do
    note = item["note"]

    if valid_text?(id, 64) and valid_text?(description, 512) and
         (is_nil(note) or valid_text?(note, 2_048)) do
      with {:ok, status} <- Map.fetch(@statuses, Map.get(item, "status", "pending")),
           {:ok, result_ref} <- parse_result_ref(item["result_ref"], source) do
        {:ok,
         %TodoItem{
           id: id,
           description: description,
           status: status,
           note: note,
           result_ref: result_ref
         }}
      else
        _invalid_item -> {:error, :invalid_checklist}
      end
    else
      {:error, :invalid_checklist}
    end
  end

  defp parse_item(_item, _source), do: {:error, :invalid_checklist}

  @spec valid_text?(term(), pos_integer()) :: boolean()
  defp valid_text?(text, max) when is_binary(text) and byte_size(text) in 1..max//1,
    do: String.valid?(text) and String.trim(text) != ""

  defp valid_text?(_text, _max), do: false

  @spec parse_result_ref(term(), source()) :: {:ok, Reference.t() | nil} | {:error, term()}
  defp parse_result_ref(nil, :resolved), do: {:ok, nil}
  defp parse_result_ref(%Reference{} = reference, :resolved), do: {:ok, reference}
  defp parse_result_ref(encoded, :stored), do: Codec.decode_reference(encoded)
  defp parse_result_ref(_value, :resolved), do: {:error, :invalid_checklist}

  @spec encode_item(TodoItem.t()) :: map()
  defp encode_item(%TodoItem{} = item) do
    %{
      "id" => item.id,
      "description" => item.description,
      "status" => Atom.to_string(item.status),
      "note" => item.note,
      "result_ref" => Codec.encode_reference(item.result_ref)
    }
  end
end
