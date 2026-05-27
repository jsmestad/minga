defmodule Minga.RenderModel.UI do
  @moduledoc false

  @type t :: %__MODULE__{
          theme: term(),
          breadcrumb: term(),
          which_key: term(),
          notifications: term(),
          search_state: term(),
          git_status: term()
        }

  defstruct [
    :theme,
    :breadcrumb,
    :which_key,
    :notifications,
    :search_state,
    :git_status
  ]
end
