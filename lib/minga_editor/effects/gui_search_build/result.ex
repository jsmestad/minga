defmodule MingaEditor.Effects.GuiSearchBuild.Result do
  @moduledoc false

  alias Minga.Editing.Search.Index

  @enforce_keys [:buffer, :version, :sequence, :search_revision, :index]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          buffer: pid(),
          version: non_neg_integer(),
          sequence: non_neg_integer(),
          search_revision: non_neg_integer(),
          index: Index.t()
        }
end
