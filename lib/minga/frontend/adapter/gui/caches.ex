defmodule Minga.Frontend.Adapter.GUI.Caches do
  @moduledoc false

  @type t :: %__MODULE__{
          last_theme_fp: integer() | nil,
          last_breadcrumb_fp: integer() | nil
        }

  defstruct last_theme_fp: nil,
            last_breadcrumb_fp: nil

  @spec new() :: t()
  def new, do: %__MODULE__{}
end
