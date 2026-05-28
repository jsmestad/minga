defmodule Minga.Frontend.Adapter.GUI.EncodedFrame do
  @moduledoc """
  GUI adapter output for one render model.

  Metal-critical commands are sent in the frame batch before `batch_end`. SwiftUI chrome commands are sent separately because they do not participate in the Metal render pass. Keeping the split in the adapter makes command ordering an adapter concern instead of an emit-stage concern.
  """

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.WindowEncoder

  @type metrics :: %{
          window: WindowEncoder.metrics(),
          metal_ui_bytes: non_neg_integer(),
          chrome_bytes: non_neg_integer()
        }

  @enforce_keys [:metal_commands, :chrome_commands, :caches, :metrics]
  defstruct metal_commands: [],
            chrome_commands: [],
            caches: Caches.new(),
            metrics: %{
              window: %{
                row_bytes: 0,
                overlay_bytes: 0,
                gutter_bytes: 0,
                annotation_bytes: 0,
                metadata_bytes: 0
              },
              metal_ui_bytes: 0,
              chrome_bytes: 0
            }

  @type t :: %__MODULE__{
          metal_commands: [binary()],
          chrome_commands: [binary()],
          caches: Caches.t(),
          metrics: metrics()
        }

  @doc "Creates encoded GUI frame output."
  @spec new([binary()], [binary()], Caches.t(), metrics()) :: t()
  def new(metal_commands, chrome_commands, %Caches{} = caches, metrics)
      when is_list(metal_commands) and is_list(chrome_commands) do
    %__MODULE__{
      metal_commands: metal_commands,
      chrome_commands: chrome_commands,
      caches: caches,
      metrics: metrics
    }
  end
end
