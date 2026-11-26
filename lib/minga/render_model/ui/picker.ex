defmodule Minga.RenderModel.UI.Picker do
  @moduledoc """
  Semantic picker model for GUI adapters.
  """

  alias Minga.RenderModel.UI.EmptyList
  alias Minga.RenderModel.UI.Picker.ActionMenu

  @type load_status :: :ready | :loading | {:error, String.t()}
  @type preview_segment :: {String.t(), non_neg_integer(), boolean()}

  @typedoc "The tone a frontend draws a picker item's status chip in. `:none` means the item has no chip."
  @type status_tone :: :none | :ready | :warn | :error | :checking | :neutral

  @typedoc """
  A wire-shaped picker item. The Layer 2 builder normalizes each source item
  into this map (flags packed, nil-vs-empty defaulted, match_positions clamped),
  so the adapter passes it straight to the generated `encode_picker_item/1`.

  `flags` bit 1 marks a multi-select item and bit 3 marks the current value. `status` is the chip text (empty when `status_tone` is `:none`). `group` is the item's section header text (empty when the item has no section).
  """
  @type item :: %{
          icon_color: non_neg_integer(),
          flags: non_neg_integer(),
          label: String.t(),
          description: String.t(),
          annotation: String.t(),
          match_positions: [non_neg_integer()],
          activation_id: non_neg_integer(),
          status: String.t(),
          status_tone: status_tone(),
          group: String.t()
        }

  @typedoc """
  A wire-shaped key that moves the highlighted row by one. `codepoint` and `modifiers` are the key press values the picker keymap scope resolves, so a frontend previews the move only for the exact key it sends.
  """
  @type movement_key :: %{
          codepoint: non_neg_integer(),
          modifiers: non_neg_integer(),
          movement: :next | :previous
        }

  @typedoc """
  The picker. `empty` is set when nothing matches and the source offers next steps: it holds the empty-state header, and `items` are the next-step rows, each with its key in `annotation`. `list_keys?` is true when there is nothing to filter, so the picker takes no text and its list keys apply.

  `hints` are the footer's key hints of an empty picker, `{keys, word}` pairs such as `{"j k", "move"}`, resolved from the live picker keymap so frontends hold no key literals.
  """
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
          activation_generation: non_neg_integer(),
          selected_item_id: non_neg_integer(),
          selected_action_id: non_neg_integer(),
          has_preview?: boolean(),
          items: [item()],
          action_menu: ActionMenu.t() | nil,
          mode_prefix: String.t(),
          load_status: load_status(),
          movement_keys: [movement_key()],
          enter_selects?: boolean(),
          preview_lines: [[preview_segment()]] | nil,
          empty: EmptyList.t() | nil,
          list_keys?: boolean(),
          hints: [{String.t(), String.t()}]
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
            activation_generation: 0,
            selected_item_id: 0,
            selected_action_id: 0,
            has_preview?: false,
            items: [],
            action_menu: nil,
            mode_prefix: "",
            load_status: :ready,
            movement_keys: [],
            enter_selects?: false,
            preview_lines: nil,
            empty: nil,
            list_keys?: false,
            hints: []
end
