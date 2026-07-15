defmodule Minga.Extension.CallbackInvokerTest do
  # capture_log replaces Logger handlers while asserting centralized diagnostics.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CodeLease
  alias Minga.Test.ExtensionCallbackProbe, as: Probe

  setup do
    admission = Module.concat(__MODULE__, "Admission#{System.unique_integer([:positive])}")
    start_supervised!({CodeLease, name: admission})

    source =
      {:extension, String.to_atom("callback_invoker_#{System.unique_integer([:positive])}")}

    :ok = CodeLease.activate_source(source, [Probe], server: admission)

    %{admission: admission, source: source}
  end

  test "returns a successful callback value and installs source identity", %{
    admission: admission,
    source: source
  } do
    assert {:ok, {:ok, ^source}} =
             CallbackInvoker.invoke(
               source,
               Probe,
               :source_identity,
               [],
               :test_callback,
               admission
             )
  end

  test "keeps a successful decline distinct from failure", %{admission: admission, source: source} do
    assert {:ok, :not_matched} =
             CallbackInvoker.invoke(
               source,
               Probe,
               :return,
               [:not_matched],
               :editor_action,
               admission
             )
  end

  test "reports unavailable sources without entering the callback", %{
    admission: admission,
    source: source
  } do
    {:ok, _token} = CodeLease.quiesce_source(source, server: admission)

    assert {:error, {:source_unavailable, ^source, Probe, :notify_and_return, _reason}} =
             CallbackInvoker.invoke(
               source,
               Probe,
               :notify_and_return,
               [self(), :rejected],
               :test_callback,
               admission
             )

    refute_receive {:extension_callback_entered, :rejected}
    assert CodeLease.active_leases(server: admission, source: source) == []
  end

  test "reports unavailable callback code and releases admission", %{
    admission: admission,
    source: source
  } do
    assert {:error,
            {:source_unavailable, ^source, Probe, :missing_callback, {:function_unavailable, 0}}} =
             CallbackInvoker.invoke(
               source,
               Probe,
               :missing_callback,
               [],
               :test_callback,
               admission
             )

    assert CodeLease.active_leases(server: admission, source: source) == []
  end

  test "contains callback exceptions and logs semantics with stacktrace", %{
    admission: admission,
    source: source
  } do
    log =
      capture_log(fn ->
        assert {:error, failure} =
                 CallbackInvoker.invoke(
                   source,
                   Probe,
                   :raise_error,
                   [],
                   :exception_semantics,
                   admission
                 )

        assert {:callback_failed, ^source, Probe, :raise_error, :exception, %RuntimeError{}} =
                 failure

        assert tuple_size(failure) == 6
        refute inspect(failure) =~ "extension_callback_probe.ex"
      end)

    assert log =~ "semantics=:exception_semantics"
    assert log =~ "raise_error"
    assert log =~ "extension_callback_probe.ex"
    assert CodeLease.active_leases(server: admission, source: source) == []
  end

  test "contains callback throws and logs semantics with stacktrace", %{
    admission: admission,
    source: source
  } do
    log =
      capture_log(fn ->
        assert {:error, failure} =
                 CallbackInvoker.invoke(
                   source,
                   Probe,
                   :throw_error,
                   [],
                   :throw_semantics,
                   admission
                 )

        assert {:callback_failed, ^source, Probe, :throw_error, :throw, :callback_thrown} =
                 failure

        assert tuple_size(failure) == 6
        refute inspect(failure) =~ "extension_callback_probe.ex"
      end)

    assert log =~ "semantics=:throw_semantics"
    assert log =~ "throw_error"
    assert log =~ "extension_callback_probe.ex"
    assert CodeLease.active_leases(server: admission, source: source) == []
  end

  test "contains callback exits and logs semantics with stacktrace", %{
    admission: admission,
    source: source
  } do
    log =
      capture_log(fn ->
        assert {:error, failure} =
                 CallbackInvoker.invoke(
                   source,
                   Probe,
                   :exit_error,
                   [],
                   :exit_semantics,
                   admission
                 )

        assert {:callback_failed, ^source, Probe, :exit_error, :exit, :callback_exited} = failure
        assert tuple_size(failure) == 6
        refute inspect(failure) =~ "extension_callback_probe.ex"
      end)

    assert log =~ "semantics=:exit_semantics"
    assert log =~ "exit_error"
    assert log =~ "extension_callback_probe.ex"
    assert CodeLease.active_leases(server: admission, source: source) == []
  end

  test "unload invocation accepts only the quiescing source token", %{
    admission: admission,
    source: source
  } do
    {:ok, token} = CodeLease.quiesce_source(source, server: admission)

    assert {:ok, :unloaded} =
             CallbackInvoker.invoke_unload(
               source,
               token,
               Probe,
               :return,
               [:unloaded],
               :source_unload,
               admission
             )

    assert {:error, {:source_unavailable, ^source, Probe, :return, _reason}} =
             CallbackInvoker.invoke_unload(
               source,
               make_ref(),
               Probe,
               :return,
               [:not_run],
               :source_unload,
               admission
             )

    assert CodeLease.active_leases(server: admission, source: source) == []
  end

  test "unload invocation contains failures and rejects a token for another source", %{
    admission: admission,
    source: source
  } do
    {:ok, token} = CodeLease.quiesce_source(source, server: admission)

    assert {:error, {:callback_failed, ^source, Probe, :raise_error, :exception, %RuntimeError{}}} =
             CallbackInvoker.invoke_unload(
               source,
               token,
               Probe,
               :raise_error,
               [],
               :source_unload,
               admission
             )

    other_source = {:extension, :wrong_unload_source}

    assert {:error,
            {:source_unavailable, ^other_source, Probe, :return,
             {:unload_source_mismatch, ^source}}} =
             CallbackInvoker.invoke_unload(
               other_source,
               token,
               Probe,
               :return,
               [:not_run],
               :source_unload,
               admission
             )

    assert CodeLease.active_leases(server: admission, source: source) == []
  end

  test "completed unload authority denies later invocation", %{
    admission: admission,
    source: source
  } do
    {:ok, token} = CodeLease.quiesce_source(source, server: admission)
    assert :ok = CodeLease.complete_unload(token, server: admission)

    assert {:error, {:source_unavailable, ^source, Probe, :return, _reason}} =
             CallbackInvoker.invoke_unload(
               source,
               token,
               Probe,
               :return,
               [:not_run],
               :source_unload,
               admission
             )

    assert CodeLease.active_leases(server: admission, source: source) == []
  end

  test "entry points reject non-extension sources" do
    assert_raise FunctionClauseError, fn ->
      :erlang.apply(CallbackInvoker, :invoke, [
        :builtin,
        Probe,
        :return,
        [:not_run],
        :test_callback
      ])
    end
  end
end
