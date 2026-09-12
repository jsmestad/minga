defmodule Minga.Session.Swap.Prepared do
  @moduledoc "A complete swap file awaiting atomic publication."

  @enforce_keys [:temporary_path, :target_path]
  defstruct [:temporary_path, :target_path]

  @type t :: %__MODULE__{
          temporary_path: String.t(),
          target_path: String.t()
        }
end
