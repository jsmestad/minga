defmodule MingaEditor.Frontend.TerminalOverridesTest do
  @moduledoc "The terminal features a user forces, as the terminal frontend is started with them."
  use ExUnit.Case, async: true

  alias Minga.Config.Options
  alias MingaEditor.Frontend.TerminalOverrides

  test "nothing forced sets no variable, so one the user set by hand is inherited" do
    assert TerminalOverrides.env(%{}) == []
  end

  test "forced features become one variable of feature=on and feature=off entries, sorted" do
    assert TerminalOverrides.env(%{
             underline_color: :off,
             true_color: :on,
             styled_underlines: :on
           }) ==
             [
               {~c"MINGA_TERMINAL_FEATURES",
                ~c"styled_underlines=on,true_color=on,underline_color=off"}
             ]
  end

  test "the variable's name is the one the frontend reads" do
    assert TerminalOverrides.variable() == "MINGA_TERMINAL_FEATURES"
  end

  describe "the :terminal_features option" do
    setup do
      %{server: start_supervised!({Options, name: nil})}
    end

    test "forces nothing by default", %{server: server} do
      assert TerminalOverrides.configured(server) == %{}
    end

    test "is what the frontend is started with", %{server: server} do
      assert {:ok, _value} = Options.set(server, :terminal_features, %{styled_underlines: :on})
      assert TerminalOverrides.configured(server) == %{styled_underlines: :on}
    end

    test "rejects a feature that cannot be forced, a mistyped name, and a value other than on or off",
         %{
           server: server
         } do
      for wrong <- [
            %{kitty_keyboard: :off},
            %{styled_underline: :on},
            %{styled_underlines: true},
            %{styled_underlines: :on, hyperlinks: :on},
            [styled_underlines: :on],
            :on
          ] do
        assert {:error, message} = Options.set(server, :terminal_features, wrong)
        assert message =~ "terminal_features"
      end

      assert TerminalOverrides.configured(server) == %{}
    end

    test "accepts each feature the frontend lets a user force", %{server: server} do
      for feature <- [:true_color, :styled_underlines, :underline_color],
          setting <- [:on, :off] do
        assert {:ok, _value} = Options.set(server, :terminal_features, %{feature => setting})
      end
    end
  end

  test "an options server that is not running forces nothing" do
    assert TerminalOverrides.configured(:no_such_options_server) == %{}
  end
end
