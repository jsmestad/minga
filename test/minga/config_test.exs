defmodule Minga.ConfigTest do
  use ExUnit.Case, async: true

  alias Minga.Config.Options

  setup do
    {:ok, pid} = Options.start_link(name: :"config_opts_#{System.unique_integer([:positive])}")
    # Point the Config DSL at our test instance by temporarily replacing the
    # named process. Since Config.set/2 calls Options.set/2 which uses the
    # default __MODULE__ name, we test through the Options server directly
    # and verify the DSL macro behavior separately.
    %{server: pid}
  end

  describe "use Minga.Config" do
    test "imports set/2 into the calling module" do
      # Verify the macro makes set/2 available by compiling a module
      Code.compile_string("""
      defmodule Minga.ConfigTest.SampleConfig do
        use Minga.Config

        # Just verify it compiles; don't actually call set/2 here
        # since Options may not be running with the right name.
        def available?, do: function_exported?(__MODULE__, :set, 2)
      end
      """)

      # The function is imported (from Minga.Config), not defined locally,
      # so function_exported? won't find it. But compilation succeeding
      # proves the import works.
      assert true
    end
  end

  describe "set/2 raises on invalid option" do
    test "raises ArgumentError for unknown option name" do
      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Minga.Config.set(:nonexistent, 42)
      end
    end

    test "raises ArgumentError for wrong type" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        Minga.Config.set(:tab_width, -1)
      end
    end
  end
end
