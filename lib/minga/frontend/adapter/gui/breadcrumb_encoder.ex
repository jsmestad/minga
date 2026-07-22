defmodule Minga.Frontend.Adapter.GUI.BreadcrumbEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Encode
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.Breadcrumb

  @op_gui_breadcrumb Opcodes.gui_breadcrumb()

  @spec encode(Breadcrumb.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Breadcrumb{} = model, %Caches{} = caches) do
    fp = :erlang.phash2(model.segments)

    if fp != caches.last_breadcrumb_fp do
      {encode_command(model), %{caches | last_breadcrumb_fp: fp}}
    else
      {nil, caches}
    end
  end

  # The fingerprint/skip-if-unchanged shell stays hand-written; byte production
  # delegates to the schema-generated pure encoder. The builder has already
  # derived the path segment list (Path.relative_to/split), so the shell just
  # passes it to the generated codec.
  @spec encode_command(Breadcrumb.t()) :: binary()
  def encode_command(%Breadcrumb{} = model) do
    :gui_breadcrumb
    |> Writer.new()
    |> Writer.append([
      @op_gui_breadcrumb | Encode.encode_gui_breadcrumb(%{segments: model.segments})
    ])
    |> Writer.finish()
  end
end
