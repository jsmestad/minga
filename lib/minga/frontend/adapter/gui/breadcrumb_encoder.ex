defmodule Minga.Frontend.Adapter.GUI.BreadcrumbEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.Breadcrumb
  alias Minga.Protocol.Opcodes

  @op_gui_breadcrumb Opcodes.gui_breadcrumb()

  @spec encode(Breadcrumb.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Breadcrumb{} = model, %Caches{} = caches) do
    fp = :erlang.phash2({model.file_path, model.root})

    if fp != caches.last_breadcrumb_fp do
      cmd = encode_breadcrumb_binary(model.file_path, model.root)
      {cmd, %{caches | last_breadcrumb_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_breadcrumb_binary(String.t() | nil, String.t()) :: binary()
  defp encode_breadcrumb_binary(nil, _root), do: <<@op_gui_breadcrumb, 0::8>>

  defp encode_breadcrumb_binary(file_path, root) do
    segments = file_path |> Path.relative_to(root) |> Path.split()

    entries =
      Enum.map(segments, fn seg ->
        seg_bytes = :erlang.iolist_to_binary([seg])
        <<byte_size(seg_bytes)::16, seg_bytes::binary>>
      end)

    IO.iodata_to_binary([@op_gui_breadcrumb, <<length(segments)::8>> | entries])
  end
end
