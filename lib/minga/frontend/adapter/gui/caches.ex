defmodule Minga.Frontend.Adapter.GUI.Caches do
  @moduledoc false

  @type t :: %__MODULE__{
          last_theme_fp: integer() | nil,
          last_breadcrumb_fp: integer() | nil,
          last_which_key_fp: integer() | nil,
          last_notifications_fp: integer() | nil,
          last_search_state_fp: integer() | nil,
          last_git_status_fp: integer() | nil,
          last_agent_context_fp: integer() | nil
        }

  defstruct last_theme_fp: nil,
            last_breadcrumb_fp: nil,
            last_which_key_fp: nil,
            last_notifications_fp: nil,
            last_search_state_fp: nil,
            last_git_status_fp: nil,
            last_agent_context_fp: nil

  @spec new() :: t()
  def new, do: %__MODULE__{}
end
