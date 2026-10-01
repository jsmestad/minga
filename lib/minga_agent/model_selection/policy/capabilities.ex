defmodule MingaAgent.ModelSelection.Policy.Capabilities do
  @moduledoc "Explicit supported, unsupported, or unknown execution capabilities."
  @enforce_keys [:tools, :images, :tool_result_images, :streaming]
  defstruct @enforce_keys

  @type capability :: boolean() | :unknown
  @type t :: %__MODULE__{
          tools: capability(),
          images: capability(),
          tool_result_images: capability(),
          streaming: capability()
        }

  @doc "Preserves unknown capabilities instead of treating them as supported."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_capabilities}
  def new(%{
        tools: tools,
        images: images,
        tool_result_images: tool_result_images,
        streaming: streaming
      })
      when tools in [true, false, :unknown] and images in [true, false, :unknown] and
             tool_result_images in [true, false, :unknown] and
             streaming in [true, false, :unknown] do
    {:ok,
     %__MODULE__{
       tools: tools,
       images: images,
       tool_result_images: tool_result_images,
       streaming: streaming
     }}
  end

  def new(_attrs), do: {:error, :invalid_capabilities}
end
