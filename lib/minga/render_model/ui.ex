defmodule Minga.RenderModel.UI do
  @moduledoc false

  @type t :: %__MODULE__{
          theme: term(),
          breadcrumb: term(),
          which_key: term(),
          notifications: term(),
          search_state: term(),
          git_status: term(),
          agent_context: term(),
          status_bar: term(),
          observatory: term(),
          board: term(),
          tab_bar: term()
        }

  defstruct [
    :theme,
    :breadcrumb,
    :which_key,
    :notifications,
    :search_state,
    :git_status,
    :agent_context,
    :status_bar,
    :observatory,
    :board,
    :tab_bar
  ]
end
