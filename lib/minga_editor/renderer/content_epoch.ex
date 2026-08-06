defmodule MingaEditor.Renderer.ContentEpoch do
  @moduledoc """
  Allocates VM-lifetime content epochs for retained renderer identities.

  Epochs are never derived from a renderer process or window cache, so buffer
  replacement and renderer restart cannot accidentally reuse epoch 1 while a
  frontend still retains rows from an earlier owner. Exhaustion fails loudly
  rather than wrapping the u32 wire value into an ambiguous epoch.
  """

  @key {__MODULE__, :counter}
  @max_epoch 0xFFFF_FFFF

  @doc "Allocates the next positive, wire-safe epoch for this VM."
  @spec next() :: pos_integer()
  def next do
    counter = counter()
    epoch = :atomics.add_get(counter, 1, 1)
    validate(epoch)
  end

  @spec counter() :: :atomics.atomics_ref()
  defp counter do
    case :persistent_term.get(@key, nil) do
      nil -> install_counter()
      counter -> counter
    end
  end

  @spec install_counter() :: :atomics.atomics_ref()
  defp install_counter do
    :global.trans({@key, self()}, fn ->
      case :persistent_term.get(@key, nil) do
        nil ->
          counter = :atomics.new(1, signed: false)
          :persistent_term.put(@key, counter)
          counter

        counter ->
          counter
      end
    end)
  end

  @spec validate(non_neg_integer()) :: pos_integer()
  defp validate(epoch) when epoch <= @max_epoch, do: epoch

  defp validate(epoch) do
    raise ArgumentError,
          "renderer content epoch allocator exhausted u32 space at #{inspect(epoch)}"
  end
end
