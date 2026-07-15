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

  test "targeted finalization runs one family and full cleanup remains idempotent", %{
    keymap: keymap
  } do
    source = {:extension, :cleanup_test}
    test_pid = self()

    callbacks = %{
      editor_effects: fn callback_source ->
        send(test_pid, {:editor_effects_finalized, callback_source})
        :ok
      end,
      later_family: fn callback_source ->
        send(test_pid, {:later_family_cleaned, callback_source})
        :ok
      end
    }

    assert :ok =
             ContributionCleanup.finalize_source(source, :editor_effects, callbacks: callbacks)

    assert_receive {:editor_effects_finalized, ^source}
    refute_received {:later_family_cleaned, ^source}

    assert :ok =
             ContributionCleanup.unregister_source(source,
               command_registry: Minga.Command.Registry,
               keymap: keymap,
               callbacks: callbacks
             )

    assert_receive {:editor_effects_finalized, ^source}
    assert_receive {:later_family_cleaned, ^source}
  end

  test "contextual finalizers receive authority only during targeted finalization", %{
    keymap: keymap
  } do
    source = {:extension, :cleanup_test}
    token = make_ref()
    test_pid = self()

    callbacks = %{
      editor_extension_unload: fn callback_source, context ->
        send(test_pid, {:extension_unload, callback_source, context})
        :ok
      end
    }

    assert :ok =
             ContributionCleanup.finalize_source(source, :editor_extension_unload,
               callbacks: callbacks,
               context: %{token: token}
             )

    assert_receive {:extension_unload, ^source, %{token: ^token}}

    assert :ok =
             ContributionCleanup.unregister_source(source,
               command_registry: Minga.Command.Registry,
               keymap: keymap,
               callbacks: callbacks
             )

    refute_receive {:extension_unload, ^source, _context}
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
