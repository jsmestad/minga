defmodule MingaEditor.UI.Picker.HelpSourceTest do
  @moduledoc false
  # Uses the global code server and HelpSource persistent_term cache.
  use ExUnit.Case, async: false

  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.HelpSource

  describe "candidates/1" do
    test "includes known modules and public functions" do
      labels = candidate_labels()

      assert "Enum" in labels
      assert "Enum.map/2" in labels
    end

    test "refreshes cached candidates when a new module is loaded" do
      _initial_labels = candidate_labels()
      module = Module.concat(__MODULE__, "Dynamic#{System.unique_integer([:positive])}")

      Code.compile_quoted(
        quote do
          defmodule unquote(module) do
            @moduledoc false
            @spec hello() :: :ok
            def hello, do: :ok
          end
        end
      )

      assert "#{inspect(module)}.hello/0" in candidate_labels()
    end

    test "refreshes cached candidates when a module gains a public function" do
      module = Module.concat(__MODULE__, "Reloaded#{System.unique_integer([:positive])}")

      Code.compile_quoted(
        quote do
          defmodule unquote(module) do
            @moduledoc false
            def before_reload, do: :ok
          end
        end
      )

      _initial_labels = candidate_labels()
      :code.purge(module)
      :code.delete(module)

      Code.compile_quoted(
        quote do
          defmodule unquote(module) do
            @moduledoc false
            def after_reload, do: :ok
            def before_reload, do: :ok
          end
        end
      )

      labels = candidate_labels()
      assert "#{inspect(module)}.after_reload/0" in labels
      assert "#{inspect(module)}.before_reload/0" in labels
    end
  end

  @spec candidate_labels() :: [String.t()]
  defp candidate_labels do
    minimal_context()
    |> HelpSource.candidates()
    |> Enum.map(& &1.label)
  end

  @spec minimal_context() :: Context.t()
  defp minimal_context do
    struct!(Context,
      buffers: nil,
      editing: nil,
      search: nil,
      viewport: nil,
      tab_bar: nil,
      picker_ui: %{},
      capabilities: %{},
      theme: nil
    )
  end
end
