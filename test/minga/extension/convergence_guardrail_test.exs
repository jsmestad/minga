defmodule Minga.Extension.ConvergenceGuardrailTest do
  use ExUnit.Case, async: true

  @lifecycle_files [
    "lib/minga/extension/supervisor.ex",
    "lib/minga/extension/lazy.ex",
    "lib/minga/extension/instance.ex",
    "lib/minga/extension/root_supervisor.ex",
    "lib/minga_editor.ex"
  ]

  test "extension lifecycle has no legacy coordination paths" do
    source = Enum.map_join(@lifecycle_files, "\n", &File.read!/1)

    for obsolete <- [
          "with_lifecycle_lock",
          "wait_for_restarted_child",
          "lifecycle_ref",
          "editor_extension_event",
          "claim_declared_modules",
          "@authority_retry_attempts",
          "retry_instance_call",
          "test_hooks"
        ] do
      refute source =~ obsolete
    end

    refute File.exists?("lib/minga/extension/source_finalizer.ex")
    refute File.exists?("lib/minga/extension/source_finalizer/state.ex")
    refute File.exists?("lib/minga/extension/dev_reload.ex")
  end

  test "config reload never replaces resident user modules" do
    loader = File.read!("lib/minga/config/loader.ex")

    refute loader =~ ":code.purge"
    refute loader =~ ":code.delete"
  end
end
