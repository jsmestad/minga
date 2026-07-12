defmodule Minga.Parser.BufferRegistration do
  @moduledoc """
  Crash-recovery metadata for one editor buffer tracked by the parser manager.
  """

  @type t :: %__MODULE__{
          id: pos_integer(),
          language: String.t(),
          content_fn: (-> String.t()),
          setup_commands_fn: (non_neg_integer() -> [binary()]) | nil
        }

  @enforce_keys [:id, :language, :content_fn]
  defstruct [:id, :language, :content_fn, setup_commands_fn: nil]
end
