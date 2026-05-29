defmodule Minga.RenderModel.UI.StatusBar do
  @moduledoc """
  Semantic status bar model for GUI adapters.

  The model carries status bar facts and modeline segments. The GUI adapter owns section encoding and protocol byte layout.
  """

  alias Minga.RenderModel.UI.StatusBar.Data
  alias Minga.RenderModel.UI.StatusBar.Workspace

  @type content_kind :: :buffer | :agent

  @type t :: %__MODULE__{
          content_kind: content_kind(),
          data: Data.t(),
          workspace: Workspace.t() | nil
        }

  @enforce_keys [:content_kind, :data]
  defstruct [:content_kind, :data, :workspace]
end
