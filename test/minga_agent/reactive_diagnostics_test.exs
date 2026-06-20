defmodule MingaAgent.ReactiveDiagnosticsTest do
  use ExUnit.Case, async: true

  alias Minga.Config.Options
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.Events
  alias Minga.LSP.SyncServer
  alias MingaAgent.ReactiveDiagnostics

  setup do
    registry = :"reactive_diag_events_#{System.unique_integer([:positive])}"
    diagnostics = :"reactive_diag_store_#{System.unique_integer([:positive])}"
    options = :"reactive_diag_options_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :duplicate, name: registry})
    start_supervised!({Diagnostics, name: diagnostics})
    start_supervised!({Options, name: options})

    parent = self()

    watcher =
      start_supervised!(
        {ReactiveDiagnostics,
         [
           name: nil,
           events_registry: registry,
           diagnostics_server: diagnostics,
           config_server: options,
           session_manager: self(),
           post_fun: fn text, _manager ->
             send(parent, {:suggestion, text})
             :ok
           end
         ]}
      )

    %{registry: registry, diagnostics: diagnostics, options: options, watcher: watcher}
  end

  test "posts a chat suggestion for a new error after save", ctx do
    enable(ctx.options)
    path = "/tmp/reactive_new.ex"
    uri = SyncServer.path_to_uri(path)

    save(ctx.registry, path)
    publish(ctx.diagnostics, ctx.registry, uri, [diag("boom", 2, 4)])

    assert_receive {:suggestion, text}, 200
    assert String.contains?(text, "reactive_new.ex:3:5")
    assert String.contains?(text, "boom")
    assert String.contains?(text, "apply a fix")
    assert String.contains?(text, "open chat")
    assert String.contains?(text, "dismiss")
  end

  test "does not post when the error already existed before save", ctx do
    enable(ctx.options)
    path = "/tmp/reactive_existing.ex"
    uri = SyncServer.path_to_uri(path)
    existing = diag("already broken", 0, 0)

    publish(ctx.diagnostics, ctx.registry, uri, [existing])
    save(ctx.registry, path)
    publish(ctx.diagnostics, ctx.registry, uri, [existing])

    refute_receive {:suggestion, _text}, 100
  end

  test "dedupes the same diagnostic on rapid saves", ctx do
    enable(ctx.options)
    path = "/tmp/reactive_dedupe.ex"
    uri = SyncServer.path_to_uri(path)
    diagnostic = diag("same", 1, 0)

    save(ctx.registry, path)
    publish(ctx.diagnostics, ctx.registry, uri, [diagnostic])
    assert_receive {:suggestion, _text}, 200

    Diagnostics.clear(ctx.diagnostics, :elixir_ls, uri)
    save(ctx.registry, path)
    publish(ctx.diagnostics, ctx.registry, uri, [diagnostic])

    refute_receive {:suggestion, _text}, 100
  end

  test "rate-limits different diagnostics from rapid saves", ctx do
    enable(ctx.options)
    path = "/tmp/reactive_rate_limit.ex"
    uri = SyncServer.path_to_uri(path)

    save(ctx.registry, path)
    publish(ctx.diagnostics, ctx.registry, uri, [diag("first", 1, 0)])
    assert_receive {:suggestion, _text}, 200

    Diagnostics.clear(ctx.diagnostics, :elixir_ls, uri)
    save(ctx.registry, path)
    publish(ctx.diagnostics, ctx.registry, uri, [diag("second", 2, 0)])

    refute_receive {:suggestion, _text}, 100
  end

  test "does nothing until explicitly enabled", ctx do
    path = "/tmp/reactive_disabled.ex"
    uri = SyncServer.path_to_uri(path)

    save(ctx.registry, path)
    publish(ctx.diagnostics, ctx.registry, uri, [diag("disabled", 0, 0)])

    refute_receive {:suggestion, _text}, 100
  end

  defp enable(options), do: Options.set(options, :agent_react_to_lsp_errors_on_save, true)

  defp save(registry, path) do
    Events.broadcast(:buffer_saved, %Events.BufferEvent{buffer: self(), path: path}, registry)
  end

  defp publish(diagnostics, registry, uri, entries) do
    Diagnostics.publish(diagnostics, :elixir_ls, uri, entries)

    Events.broadcast(
      :diagnostics_updated,
      %Events.DiagnosticsUpdatedEvent{uri: uri, source: :elixir_ls},
      registry
    )
  end

  defp diag(message, line, col) do
    %Diagnostic{
      severity: :error,
      message: message,
      source: "elixir_ls",
      range: %{start_line: line, start_col: col, end_line: line, end_col: col + 1}
    }
  end
end
