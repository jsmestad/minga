defmodule Minga.Frontend.Adapter.GUI.Caches do
  @moduledoc false

  @type t :: %__MODULE__{
          last_theme_fp: integer() | nil,
          last_breadcrumb_fp: integer() | nil,
          last_which_key_fp: integer() | nil,
          last_notifications_fp: integer() | nil,
          last_search_state_fp: integer() | nil,
          last_git_status_fp: integer() | nil,
          last_agent_context_fp: integer() | nil,
          last_observatory_fp: integer() | :hidden | nil,
          last_board_fp: integer() | :dismissed | nil,
          last_tab_bar_fp: integer() | :suppressed | nil,
          last_workspaces_fp: integer() | :suppressed | nil,
          last_sidebars_fp: integer() | nil,
          last_file_tree_fp: Minga.RenderModel.UI.FileTree.fingerprint() | nil
        }

  defstruct last_theme_fp: nil,
            last_breadcrumb_fp: nil,
            last_which_key_fp: nil,
            last_notifications_fp: nil,
            last_search_state_fp: nil,
            last_git_status_fp: nil,
            last_agent_context_fp: nil,
            last_observatory_fp: nil,
            last_board_fp: nil,
            last_tab_bar_fp: nil,
            last_workspaces_fp: nil,
            last_sidebars_fp: nil,
            last_file_tree_fp: nil

  @spec new() :: t()
  def new, do: %__MODULE__{}
end
