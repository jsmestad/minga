defmodule Minga.Extension.ContributionCleanupTest do
  # Not async: uses process-global Minga.Language.Registry.
  use ExUnit.Case, async: false

  alias Minga.Extension.ContributionCleanup
  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Language
  alias Minga.Language.Registry, as: LanguageRegistry

  setup do
    keymap_name = :"cleanup_keymap_#{System.unique_integer([:positive])}"
    keymap = start_supervised!({KeymapActive, name: keymap_name})

    on_exit(fn ->
      LanguageRegistry.unregister_source({:extension, :cleanup_test})
    end)

    {:ok, keymap: keymap}
  end

  test "continues cleanup after one family fails and reports the failure", %{keymap: keymap} do
    source = {:extension, :cleanup_test}
    test_pid = self()

    assert :ok =
             LanguageRegistry.register(
               %Language{
                 name: :cleanup_test_language,
                 label: "Cleanup Test",
                 comment_token: "// ",
                 extensions: ["cleanup_test_language"]
               },
               source
             )

    callbacks = %{
      cleanup_followup: fn callback_source ->
        send(test_pid, {:cleanup_followup, callback_source})
        :ok
      end
    }

    assert {:error, failures} =
             ContributionCleanup.unregister_source(source,
               command_registry: :missing_cleanup_registry,
               keymap: keymap,
               callbacks: callbacks
             )

    assert Enum.any?(failures, fn
             %{family: :command_registry, source: ^source} -> true
             _ -> false
           end)

    assert_receive {:cleanup_followup, ^source}
    assert LanguageRegistry.get(:cleanup_test_language) == nil
  end
end
