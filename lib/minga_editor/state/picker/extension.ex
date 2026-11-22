defmodule MingaEditor.State.Picker.Extension do
  @moduledoc false

  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.PublicSource

  @type preview ::
          nil
          | {:pending, reference(), term()}
          | {:resolved, term(), PublicSource.preview_result()}

  @type t :: %__MODULE__{
          args: term(),
          preview?: boolean(),
          live_origin: pid() | nil,
          preview: preview(),
          page: PublicSource.page(),
          item_ids: MapSet.t()
        }

  @enforce_keys [:args, :preview?, :live_origin]
  defstruct [:args, :preview?, :live_origin, :preview, page: :done, item_ids: MapSet.new()]

  @spec new(term(), boolean(), pid() | nil) :: t()
  def new(args, preview?, live_origin) do
    %__MODULE__{args: args, preview?: preview?, live_origin: live_origin}
  end

  @spec put_preview(t(), preview()) :: t()
  def put_preview(%__MODULE__{} = extension, preview), do: %{extension | preview: preview}

  @spec accept_page(t(), [Item.t()], PublicSource.page()) :: {:ok, t()} | :duplicate
  def accept_page(%__MODULE__{} = extension, items, page) do
    case add_item_ids(items, extension.item_ids) do
      {:ok, ids} -> {:ok, %{extension | page: page, item_ids: ids}}
      :duplicate -> :duplicate
    end
  end

  @spec add_item_ids([Item.t()], MapSet.t()) :: {:ok, MapSet.t()} | :duplicate
  defp add_item_ids([%Item{id: {:extension_item, id}} | rest], ids) do
    if MapSet.member?(ids, id), do: :duplicate, else: add_item_ids(rest, MapSet.put(ids, id))
  end

  defp add_item_ids(_continuation_or_empty, ids), do: {:ok, ids}
end
