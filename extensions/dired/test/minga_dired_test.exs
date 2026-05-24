defmodule MingaDiredTest do
  @moduledoc "Tests for the Dired extension pack lifecycle. async: false because persistent_term is global."
  use ExUnit.Case, async: false

  alias MingaDired
  alias Minga.Keymap.Scope

  setup do
    source = {:extension, :dired}

    on_exit(fn ->
      Minga.Extension.ContributionCleanup.unregister_source(source)
      MingaEditor.Input.unregister_source(source)
    end)

    :ok
  end

  describe "init/1" do
    test "registers commands, keymap scope, and input handler" do
      assert {:ok, %{}} = MingaDired.init(%{})

      assert :dired in Scope.all_scopes()
      assert {:ok, _} = Minga.Command.Registry.lookup(Minga.Command.Registry, :dired_open)

      assert MingaDired.Input in MingaEditor.Input.surface_handlers()
    end
  end
end
