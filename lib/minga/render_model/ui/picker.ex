defmodule Minga.RenderModel.UI.Picker do
  @moduledoc """
  Semantic picker model for GUI adapters.
  """

  alias Minga.RenderModel.UI.Picker.ActionMenu

  @type load_status :: :ready | :loading | {:error, String.t()}
  @type preview_segment :: {String.t(), non_neg_integer(), boolean()}

  @typedoc """
  A wire-shaped picker item. The Layer 2 builder normalizes each source item
  into this map (flags packed, nil-vs-empty defaulted, match_positions clamped),
  so the adapter passes it straight to the generated `encode_picker_item/1`.
  """
  @type item :: %{
          icon_color: non_neg_integer(),
          flags: non_neg_integer(),
          label: String.t(),
          description: String.t(),
          annotation: String.t(),
          match_positions: [non_neg_integer()]
        }

  @type t :: %__MODULE__{
          visible?: boolean(),
          title: String.t(),
          query: String.t(),
          query_generation: non_neg_integer(),
          acknowledged_query_edit_seq: non_neg_integer(),
          selected_index: non_neg_integer(),
          filtered_count: non_neg_integer(),
          total_count: non_neg_integer(),
          marked_count: non_neg_integer(),
          has_preview?: boolean(),
          items: [item()],
          action_menu: ActionMenu.t() | nil,
          mode_prefix: String.t(),
          load_status: load_status(),
          preview_lines: [[preview_segment()]] | nil
        }

  defstruct visible?: false,
            title: "",
            query: "",
            query_generation: 0,
            acknowledged_query_edit_seq: 0,
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
