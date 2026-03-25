defmodule Minga.UI.Theme.SlotsTest do
  use ExUnit.Case, async: true

  alias Minga.UI.Theme.Slots

  describe "to_color_pairs/1" do
    test "returns a list of {slot_id, color} tuples for a complete theme" do
      theme = Minga.UI.Theme.get!(:doom_one)
      pairs = Slots.to_color_pairs(theme)

      assert is_list(pairs)
      assert length(pairs) > 30

      # Every entry is a {integer, integer | nil} tuple
      for {slot_id, color} <- pairs do
        assert is_integer(slot_id)
        assert is_nil(color) or is_integer(color)
      end
    end

    test "editor bg/fg map to the correct slot IDs" do
      theme = Minga.UI.Theme.get!(:doom_one)
      pairs = Slots.to_color_pairs(theme)
      pair_map = Map.new(pairs)

      # Slot 0x01 = editor bg, 0x02 = editor fg
      assert pair_map[0x01] == theme.editor.bg
      assert pair_map[0x02] == theme.editor.fg
    end

    test "tree colors map to expected slots" do
      theme = Minga.UI.Theme.get!(:doom_one)
      pairs = Slots.to_color_pairs(theme)
      pair_map = Map.new(pairs)

      assert pair_map[0x03] == theme.tree.bg
      assert pair_map[0x04] == theme.tree.fg
      assert pair_map[0x05] == theme.tree.cursor_bg
      assert pair_map[0x06] == theme.tree.dir_fg
      assert pair_map[0x07] == theme.tree.active_fg
    end

    test "tab bar slots are nil when tab_bar is nil" do
      theme = %{Minga.UI.Theme.get!(:doom_one) | tab_bar: nil}
      pairs = Slots.to_color_pairs(theme)
      pair_map = Map.new(pairs)

      # Tab bar slots 0x10-0x17 should all be nil
      for slot <- 0x10..0x17 do
        assert is_nil(pair_map[slot]),
               "expected slot #{inspect(slot)} to be nil when tab_bar is nil"
      end
    end

    test "mode colors use fallback when mode_colors map is empty" do
      theme = Minga.UI.Theme.get!(:doom_one)
      # Create a theme with empty mode_colors to test fallback
      modeline = %{theme.modeline | mode_colors: %{}}
      theme = %{theme | modeline: modeline}

      pairs = Slots.to_color_pairs(theme)
      pair_map = Map.new(pairs)

      # With empty mode_colors, all mode colors should fall back to bar_fg/bar_bg
      assert pair_map[0x34] == modeline.bar_bg
      assert pair_map[0x35] == modeline.bar_fg
      assert pair_map[0x36] == modeline.bar_bg
      assert pair_map[0x37] == modeline.bar_fg
      assert pair_map[0x38] == modeline.bar_bg
      assert pair_map[0x39] == modeline.bar_fg
    end

    test "mode colors use theme values when present" do
      theme = Minga.UI.Theme.get!(:doom_one)
      pairs = Slots.to_color_pairs(theme)
      pair_map = Map.new(pairs)

      {normal_fg, normal_bg} = theme.modeline.mode_colors[:normal]
      assert pair_map[0x34] == normal_bg
      assert pair_map[0x35] == normal_fg
    end

    test "popup colors map to expected slots" do
      theme = Minga.UI.Theme.get!(:doom_one)
      pairs = Slots.to_color_pairs(theme)
      pair_map = Map.new(pairs)

      assert pair_map[0x20] == theme.popup.bg
      assert pair_map[0x21] == theme.popup.fg
      assert pair_map[0x22] == theme.popup.border_fg
      assert pair_map[0x23] == theme.popup.sel_bg
    end

    test "accent color maps to tree active_fg" do
      theme = Minga.UI.Theme.get!(:doom_one)
      pairs = Slots.to_color_pairs(theme)
      pair_map = Map.new(pairs)

      assert pair_map[0x40] == theme.tree.active_fg
    end

    test "highlight and selection slots map to expected IDs" do
      theme = Minga.UI.Theme.get!(:doom_one)
      pairs = Slots.to_color_pairs(theme)
      pair_map = Map.new(pairs)

      assert pair_map[0x59] == theme.editor.highlight_read_bg
      assert pair_map[0x5A] == theme.editor.highlight_write_bg
      assert pair_map[0x5B] == theme.editor.selection_bg
    end

    test "all themes define highlight and selection colors (no nils)" do
      for theme_name <- [:doom_one, :catppuccin_mocha, :one_dark, :one_light] do
        theme = Minga.UI.Theme.get!(theme_name)
        pair_map = Map.new(Slots.to_color_pairs(theme))

        assert pair_map[0x59] != nil, "#{theme_name} missing highlight_read_bg"
        assert pair_map[0x5A] != nil, "#{theme_name} missing highlight_write_bg"
        assert pair_map[0x5B] != nil, "#{theme_name} missing selection_bg"
      end
    end

    test "all slot IDs are unique" do
      theme = Minga.UI.Theme.get!(:doom_one)
      pairs = Slots.to_color_pairs(theme)
      slot_ids = Enum.map(pairs, fn {slot, _} -> slot end)

      assert length(slot_ids) == length(Enum.uniq(slot_ids)),
             "duplicate slot IDs found: #{inspect(slot_ids -- Enum.uniq(slot_ids))}"
    end

    test "works with all built-in themes" do
      for theme_name <- [:doom_one, :catppuccin_mocha, :one_dark, :one_light] do
        theme = Minga.UI.Theme.get!(theme_name)
        pairs = Slots.to_color_pairs(theme)
        assert length(pairs) > 30, "#{theme_name} should produce 30+ color pairs"
      end
    end
  end
end
