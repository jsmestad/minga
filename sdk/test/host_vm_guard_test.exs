defmodule MingaSdk.HostVmGuardTest do
  # Defines the editor's host-only marker module, which is global to the VM.
  use ExUnit.Case, async: false

  @marker Minga.Extension.Supervisor

  test "the SDK compiles its stubs outside a Minga editor" do
    refute Code.ensure_loaded?(@marker)
    assert MingaSdk.MixProject.project()[:elixirc_paths] == ["lib"]
  end

  test "the SDK compiles no modules inside a Minga editor" do
    Code.compile_string("defmodule #{inspect(@marker)} do\nend")

    on_exit(fn ->
      :code.purge(@marker)
      :code.delete(@marker)
    end)

    assert MingaSdk.MixProject.project()[:elixirc_paths] == []
  end
end
