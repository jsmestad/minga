defmodule MingaEditor.State.RegistersTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Registers

  describe "put/4 and get/2" do
    test "stores charwise entry by default" do
      reg = %Registers{} |> Registers.put("a", "hello")
      assert Registers.get(reg, "a") == {"hello", :charwise}
    end

    test "stores linewise entry when type is :linewise" do
      reg = %Registers{} |> Registers.put("a", "hello\n", :linewise)
      assert Registers.get(reg, "a") == {"hello\n", :linewise}
    end

    test "overwrites previous entry" do
      reg =
        %Registers{}
        |> Registers.put("a", "first", :charwise)
        |> Registers.put("a", "second", :linewise)

      assert Registers.get(reg, "a") == {"second", :linewise}
    end

    test "returns nil for unset register" do
      assert Registers.get(%Registers{}, "z") == nil
    end

    test "independent registers don't interfere" do
      reg =
        %Registers{}
        |> Registers.put("a", "alpha", :charwise)
        |> Registers.put("b", "beta\n", :linewise)

      assert Registers.get(reg, "a") == {"alpha", :charwise}
      assert Registers.get(reg, "b") == {"beta\n", :linewise}
    end
  end

  describe "bare string migration" do
    test "get/2 migrates a bare string to {:charwise}" do
      reg = %Registers{registers: %{"a" => "legacy"}}
      assert Registers.get(reg, "a") == {"legacy", :charwise}
    end

    test "get/2 returns nil for missing key even with legacy data" do
      reg = %Registers{registers: %{"a" => "legacy"}}
      assert Registers.get(reg, "b") == nil
    end
  end

  describe "unnamed register" do
    test "empty string key is the unnamed register" do
      reg = %Registers{} |> Registers.put("", "unnamed content", :linewise)
      assert Registers.get(reg, "") == {"unnamed content", :linewise}
    end
  end

  describe "reset_active/1" do
    test "resets active register to empty string" do
      reg = %Registers{active: "a"} |> Registers.reset_active()
      assert reg.active == ""
    end
  end

  describe "set_active/2" do
    test "sets the active register" do
      reg = %Registers{} |> Registers.set_active("z")
      assert reg.active == "z"
    end
  end
end
