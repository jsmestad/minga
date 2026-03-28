defmodule Minga.UI.Theme.Slots do
  @moduledoc """
  Maps theme color fields to GUI color slot IDs.

  The GUI frontend (Swift/GTK) receives theme colors as a flat list of
  `{slot_id, rgb}` pairs. This module owns the mapping from semantic
  `Theme.t()` fields to those integer slot IDs, so the protocol encoder
  doesn't need to know about the Theme struct's internal layout.

  ## Slot ID ranges

  | Range     | Domain        |
  |-----------|---------------|
  | 0x01-0x0F | Editor + Tree |
  | 0x10-0x17 | Tab bar       |
  | 0x20-0x29 | Popups + Breadcrumb |
  | 0x30-0x3A | Modeline + Status bar |
  | 0x40      | Accent        |
  | 0x50-0x5B | Gutter + Git + Highlights |
  | 0x5C-0x61 | Agent status  |
  """

  # ── Editor + Tree ──
  @editor_bg 0x01
  @editor_fg 0x02
  @tree_bg 0x03
  @tree_fg 0x04
  @tree_selection_bg 0x05
  @tree_dir_fg 0x06
  @tree_active_fg 0x07
  @tree_header_bg 0x08
  @tree_header_fg 0x09
  @tree_separator_fg 0x0A
  @tree_git_modified 0x0B
  @tree_git_staged 0x0C
  @tree_git_untracked 0x0D
  @tree_selection_fg 0x0E
  @tree_guide_fg 0x0F

  # ── Tab bar ──
  @tab_bg 0x10
  @tab_active_bg 0x11
  @tab_active_fg 0x12
  @tab_inactive_fg 0x13
  @tab_modified_fg 0x14
  @tab_separator_fg 0x15
  @tab_close_hover_fg 0x16
  @tab_attention_fg 0x17

  # ── Popups + Breadcrumb ──
  @popup_bg 0x20
  @popup_fg 0x21
  @popup_border 0x22
  @popup_sel_bg 0x23
  @popup_key_fg 0x24
  @popup_group_fg 0x25
  @popup_desc_fg 0x26
  @breadcrumb_bg 0x27
  @breadcrumb_fg 0x28
  @breadcrumb_separator_fg 0x29

  # ── Modeline + Status bar ──
  @modeline_bar_bg 0x30
  @modeline_bar_fg 0x31
  @modeline_info_bg 0x32
  @modeline_info_fg 0x33
  @mode_normal_bg 0x34
  @mode_normal_fg 0x35
  @mode_insert_bg 0x36
  @mode_insert_fg 0x37
  @mode_visual_bg 0x38
  @mode_visual_fg 0x39
  @statusbar_accent_fg 0x3A

  # ── Gutter ──
  @gutter_fg 0x50
  @gutter_current_fg 0x51
  @gutter_error_fg 0x52
  @gutter_warning_fg 0x53
  @gutter_info_fg 0x54
  @gutter_hint_fg 0x55
  @git_added_fg 0x56
  @git_modified_fg 0x57
  @git_deleted_fg 0x58

  # ── Document highlights + Selection ──
  @highlight_read_bg 0x59
  @highlight_write_bg 0x5A
  @selection_bg 0x5B

  # ── Agent status (shared across Board cards, tab badges, chat header) ──
  @agent_status_idle 0x5C
  @agent_status_working 0x5D
  @agent_status_iterating 0x5E
  @agent_status_needs_you 0x5F
  @agent_status_done 0x60
  @agent_status_errored 0x61

  # ── Accent ──
  @accent 0x40

  @typedoc "A color slot pair: `{slot_id, rgb_color | nil}`."
  @type color_pair :: {non_neg_integer(), non_neg_integer() | nil}

  @doc """
  Converts a theme into a list of `{slot_id, rgb}` pairs for the GUI frontend.

  Nil colors are included in the output (callers can filter them as needed).
  """
  @spec to_color_pairs(Minga.UI.Theme.t()) :: [color_pair()]
  def to_color_pairs(%Minga.UI.Theme{} = theme) do
    e = theme.editor
    t = theme.tree
    tb = theme.tab_bar
    p = theme.popup
    ml = theme.modeline

    {normal_fg, normal_bg} = mode_color(ml, :normal)
    {insert_fg, insert_bg} = mode_color(ml, :insert)
    {visual_fg, visual_bg} = mode_color(ml, :visual)

    [
      {@editor_bg, e.bg},
      {@editor_fg, e.fg},
      {@tree_bg, t.bg},
      {@tree_fg, t.fg},
      {@tree_selection_bg, t.cursor_bg},
      {@tree_dir_fg, t.dir_fg},
      {@tree_active_fg, t.active_fg},
      {@tree_header_bg, t.header_bg},
      {@tree_header_fg, t.header_fg},
      {@tree_separator_fg, t.separator_fg},
      {@tree_git_modified, t.git_modified_fg},
      {@tree_git_staged, t.git_staged_fg},
      {@tree_git_untracked, t.git_untracked_fg},
      {@tree_selection_fg, e.fg},
      {@tree_guide_fg, t.separator_fg},
      {@tab_bg, tb && tb.bg},
      {@tab_active_bg, tb && tb.active_bg},
      {@tab_active_fg, tb && tb.active_fg},
      {@tab_inactive_fg, tb && tb.inactive_fg},
      {@tab_modified_fg, tb && tb.modified_fg},
      {@tab_separator_fg, tb && tb.separator_fg},
      {@tab_close_hover_fg, tb && tb.close_hover_fg},
      {@tab_attention_fg, tb && tb.attention_fg},
      {@popup_bg, p.bg},
      {@popup_fg, p.fg},
      {@popup_border, p.border_fg},
      {@popup_sel_bg, p.sel_bg},
      {@popup_key_fg, p.key_fg},
      {@popup_group_fg, p.group_fg},
      {@popup_desc_fg, p.fg},
      {@breadcrumb_bg, ml.bar_bg},
      {@breadcrumb_fg, ml.info_fg},
      {@breadcrumb_separator_fg, t.separator_fg},
      {@modeline_bar_bg, ml.bar_bg},
      {@modeline_bar_fg, ml.bar_fg},
      {@modeline_info_bg, ml.info_bg},
      {@modeline_info_fg, ml.info_fg},
      {@mode_normal_bg, normal_bg},
      {@mode_normal_fg, normal_fg},
      {@mode_insert_bg, insert_bg},
      {@mode_insert_fg, insert_fg},
      {@mode_visual_bg, visual_bg},
      {@mode_visual_fg, visual_fg},
      {@statusbar_accent_fg, t.active_fg},
      {@accent, t.active_fg},
      {@gutter_fg, theme.gutter.fg},
      {@gutter_current_fg, theme.gutter.current_fg},
      {@gutter_error_fg, theme.gutter.error_fg},
      {@gutter_warning_fg, theme.gutter.warning_fg},
      {@gutter_info_fg, theme.gutter.info_fg},
      {@gutter_hint_fg, theme.gutter.hint_fg},
      {@git_added_fg, theme.git.added_fg},
      {@git_modified_fg, theme.git.modified_fg},
      {@git_deleted_fg, theme.git.deleted_fg},
      {@highlight_read_bg, e.highlight_read_bg || 0x3A3F4B},
      {@highlight_write_bg, e.highlight_write_bg || 0x4A3F2B},
      {@selection_bg, e.selection_bg || 0x264F78}
    ] ++ agent_status_pairs(theme, tb)
  end

  @spec agent_status_pairs(Minga.UI.Theme.t(), Minga.UI.Theme.TabBar.t() | nil) :: [color_pair()]
  defp agent_status_pairs(theme, tb) do
    [
      {@agent_status_idle, theme.gutter.fg},
      {@agent_status_working, theme.git.added_fg},
      {@agent_status_iterating, theme.git.added_fg},
      {@agent_status_needs_you, tb && tb.modified_fg},
      {@agent_status_done, theme.tree.active_fg},
      {@agent_status_errored, theme.gutter.error_fg}
    ]
  end

  @spec mode_color(Minga.UI.Theme.Modeline.t(), atom()) ::
          {Minga.UI.Theme.color(), Minga.UI.Theme.color()}
  defp mode_color(ml, mode) do
    case Map.get(ml.mode_colors || %{}, mode) do
      {fg, bg} -> {fg, bg}
      _ -> {ml.bar_fg, ml.bar_bg}
    end
  end
end
