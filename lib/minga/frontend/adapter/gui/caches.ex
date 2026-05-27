defmodule Minga.Frontend.Adapter.GUI.Caches do
  @moduledoc false

  @type t :: %__MODULE__{}

  defstruct []

  @spec new() :: t()
  def new, do: %__MODULE__{}
end
