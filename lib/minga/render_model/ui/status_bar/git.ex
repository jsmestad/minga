defmodule Minga.RenderModel.UI.StatusBar.Git do
  @moduledoc false

  @type diff_summary :: {non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil

  @type t :: %__MODULE__{
          branch: String.t() | nil,
          diff_summary: diff_summary()
        }

  defstruct branch: nil,
            diff_summary: nil
end
