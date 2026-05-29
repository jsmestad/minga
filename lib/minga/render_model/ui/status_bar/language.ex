defmodule Minga.RenderModel.UI.StatusBar.Language do
  @moduledoc false

  @type lsp_status :: :ready | :initializing | :starting | :error | :none | nil
  @type parser_status :: :available | :unavailable | :restarting | nil

  @type t :: %__MODULE__{
          lsp_status: lsp_status(),
          parser_status: parser_status()
        }

  defstruct lsp_status: :none,
            parser_status: :available
end
