defmodule Minga.RenderModel.UI.Picker do
  @moduledoc """
  Semantic picker model for GUI adapters.
  """

  alias Minga.RenderModel.UI.Picker.ActionMenu
  alias Minga.RenderModel.UI.Picker.Item

  @type load_status :: :ready | :loading | {:error, String.t()}
  @type preview_segment :: {String.t(), non_neg_integer(), boolean()}

  @type t :: %__MODULE__{
          visible?: boolean(),
          title: String.t(),
          query: String.t(),
          selected_index: non_neg_integer(),
          filtered_count: non_neg_integer(),
          total_count: non_neg_integer(),
          marked_count: non_neg_integer(),
          has_preview?: boolean(),
          items: [Item.t()],
          action_menu: ActionMenu.t() | nil,
          mode_prefix: String.t(),
          load_status: load_status(),
          preview_lines: [[preview_segment()]] | nil
        }

  defstruct visible?: false,
            title: "",
            query: "",
            selected_index: 0,
            filtered_count: 0,
            total_count: 0,
            marked_count: 0,
            has_preview?: false,
            items: [],
            action_menu: nil,
            mode_prefix: "",
            load_status: :ready,
            preview_lines: nil
end
