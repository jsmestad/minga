defmodule Minga.Extension.CallbackRegistryCleanupTest do
  # Serial because ContributionCleanup always touches application-wide core registries.
  use ExUnit.Case, async: false

  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.ArtifactGenerationState
  alias Minga.Extension.CallbackRegistry
  alias Minga.Extension.ContributionCleanup
  alias MingaEditor.Test.ExtensionEventHandlerOne, as: HandlerOne
  alias MingaEditor.Test.ExtensionEventHandlerTwo, as: HandlerTwo

  setup do
    registry = unique_name(:cleanup_registry)
    admission = unique_name(:cleanup_admission)
    generation = unique_name(:cleanup_generation)
    persistence_key = {__MODULE__, make_ref()}

    start_supervised!({CallbackRegistry, name: registry})

    start_supervised!(
      {ArtifactGenerationState, name: generation, persistence_key: persistence_key}
    )

    start_supervised!({ArtifactAdmission, name: admission, state_owner: generation})
    on_exit(fn -> ArtifactGenerationState.reset_for_test(persistence_key) end)

    %{registry: registry, admission: admission}
  end

  test "cleanup removes only one extension source across every retained family", ctx do
    removed = register(ctx, HandlerOne, [:buffer_saved, :editor_action, :source_unload])
    retained = register(ctx, HandlerTwo, [:buffer_saved])

    callbacks = %{
      extension_callbacks: fn source ->
        CallbackRegistry.unregister_source(source, ctx.registry)
      end
    }

    assert :ok = ContributionCleanup.unregister_source(removed, callbacks: callbacks)

    assert CallbackRegistry.callbacks(:buffer_saved, ctx.registry) == [{retained, HandlerTwo}]
    assert CallbackRegistry.callbacks(:editor_action, ctx.registry) == []
    assert CallbackRegistry.callbacks(:source_unload, ctx.registry) == []
  end

  test "removed worker-result and process-down families are rejected", ctx do
    source = admit(ctx, HandlerOne)
    {:extension, name} = source

    assert {:error, {:invalid_callback_families, [:remote_result, :process_down]}} =
             CallbackRegistry.register_extension(
               name,
               [{HandlerOne, [:remote_result, :process_down], []}],
               registry: ctx.registry,
               artifact_admission: ctx.admission
             )
  end

  test "registry exposes no trusted registration path" do
    refute function_exported?(CallbackRegistry, :register_trusted, 4)
    refute function_exported?(CallbackRegistry, :register, 4)
  end

  defp register(ctx, handler, families) do
    source = admit(ctx, handler)
    {:extension, name} = source

    :ok =
      CallbackRegistry.register_extension(name, [{handler, families, []}],
        registry: ctx.registry,
        artifact_admission: ctx.admission
      )

    source
  end

  defp admit(ctx, handler) do
    name = unique_name(:cleanup_source)
    source = {:extension, name}

    {:ok, claim} =
      ArtifactAdmission.claim_source_modules(
        source,
        [handler],
        :crypto.hash(:sha256, inspect(source)),
        server: ctx.admission,
        trusted_application: :minga
      )

    :ok = ArtifactAdmission.commit_attempt(claim, server: ctx.admission)
    source
  end

  defp unique_name(prefix),
    do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
