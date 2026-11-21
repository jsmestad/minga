defmodule MingaAgent.Tools.RetainedShellCaptureTest do
  # Runs real shell producers and the canonical callback uses the global Buffer.Registry.
  use ExUnit.Case, async: false

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Spec
  alias MingaAgent.Tools
  alias MingaAgent.Tools.FetchOutput
  alias MingaAgent.Tools.OutputLimit
  alias MingaAgent.Tools.ProcessBackend.System, as: SystemBackend
  alias MingaAgent.Tools.Shell

  @moduletag :tmp_dir

  test "canonical shell retains all 135168 bytes with bounded previews and one producer", %{
    tmp_dir: root
  } do
    store = start_store(root)
    bytes = String.duplicate("0123456789abcdef retained-output\n", 4096)
    assert byte_size(bytes) == 135_168
    File.write!(Path.join(root, "producer-output"), bytes)
    parent = self()

    context =
      Context.new(
        project_root: root,
        artifact_store: store,
        capture_key: {:delivery, "checkpoint", "large-output"},
        metadata: %{
          shell_output_callback: fn chunk ->
            send(parent, {:chunk, chunk})
            :ok
          end
        }
      )

    shell = Enum.find(Tools.all(), &(&1.name == "shell"))
    callback = Spec.build_callback(shell, context)

    assert {:ok, %Output{} = output} =
             callback.(%{"command" => "printf x >> producer-count; cat producer-output"})

    assert output.capture == :complete
    assert output.reference.bytes == 135_168

    assert output.reference.sha256 ==
             "eaa4d3845aacc50b2183d297f70a5f917c717ae06961fabff337ace060ac5219"

    assert output.view == binary_part(bytes, 0, 51_200)
    assert output.presentation == {:truncated, 83_968}
    assert output.selection.kind == :full
    assert output.selection.count == 135_168
    assert output.selection.total == 135_168
    streamed = chunks()
    marker = "\n\n[stream truncated at 51KB]\n"
    assert streamed == binary_part(bytes, 0, 51_200) <> marker

    File.write!(Path.join(root, "producer-output"), "source changed")
    assert fetch_all(context, output.reference) == bytes
    assert File.read!(Path.join(root, "producer-count")) == "x"

    assert {:ok, %{reference: reference, capture: :complete}} =
             ArtifactStore.lookup_delivery(store, context.capture_key)

    assert reference == output.reference
  end

  # Let ExUnit detect a transport hang before the shell deadline. This test checks byte identity, not speed.
  @tag timeout: 60_000
  test "retained raw stdout and stderr preserve whitespace, Unicode and binary identity", %{
    tmp_dir: root
  } do
    store = start_store(root)

    for {id, bytes} <- [
          {"whitespace", "hello λ\t \r\n\n"},
          {"binary", <<0, 255, "💾"::binary, 254, 9, 32, 10>>}
        ] do
      File.write!(Path.join(root, id), bytes)
      ctx = context(root, store, id)
      parent = self()

      assert {:ok, output} =
               SystemBackend.shell("cat #{id}; printf 'stderr \\t\\n' >&2; exit 42", root, 120,
                 artifact_store: store,
                 capture_key: ctx.capture_key,
                 on_output: fn chunk ->
                   send(parent, {:chunk, chunk})
                   :ok
                 end
               )

      expected = bytes <> "stderr \t\n"
      assert output.capture == :complete
      assert output.reference.bytes == byte_size(expected)
      assert String.valid?(output.view)
      assert output.view =~ "[exit code: 42]"
      assert byte_size(output.view) <= OutputLimit.default_max_bytes()
      assert fetch_all(ctx, output.reference) == expected
      assert chunks() =~ "[exit code: 42]"
    end
  end

  test "quota crossing stops the producer and exposes only its retained prefix", %{tmp_dir: root} do
    store = start_store(root, limits: [capture_bytes: 65_536, image_bytes: 65_536])
    bytes = String.duplicate("abcdef \n", 30_000)
    File.write!(Path.join(root, "quota-output"), bytes)
    ctx = context(root, store, "quota")

    assert {:error,
            %Output{capture: {:incomplete, :capture_byte_limit}, selection: selection} = output} =
             Shell.capture("cat quota-output; while :; do :; done", root, 5,
               artifact_store: store,
               capture_key: ctx.capture_key
             )

    assert selection.kind == :captured_prefix
    assert selection.total == :unknown
    assert output.reference.bytes > 0
    assert output.reference.bytes <= 65_536
    assert byte_size(output.view) <= 51_200
    assert output.view =~ "capture incomplete: :capture_byte_limit"

    assert fetch_all(ctx, output.reference, :error) ==
             binary_part(bytes, 0, output.reference.bytes)
  end

  test "retained output includes a background writer after the shell exits", %{tmp_dir: root} do
    store = start_store(root)
    ctx = context(root, store, "background")

    assert {:ok, %Output{capture: :complete} = output} =
             Shell.capture("printf head; (sleep 0.1; printf tail) & exit 0", root, 5,
               artifact_store: store,
               capture_key: ctx.capture_key
             )

    assert fetch_all(ctx, output.reference, :ok) == "headtail"
  end

  test "timeout returns exact retained prefix without storing the timeout notice", %{
    tmp_dir: root
  } do
    store = start_store(root)
    ctx = context(root, store, "timeout")

    command = """
    printf 'before timeout \\t\\n'
    (trap '' TERM; printf ready > retained-child-ready; sleep 2; printf late > retained-late-effect) &
    wait
    """

    assert {:error, %Output{capture: {:incomplete, :timeout}} = output} =
             Shell.capture(command, root, 1,
               artifact_store: store,
               capture_key: ctx.capture_key
             )

    assert output.view == "before timeout \t\n\n[command timed out]"
    assert output.selection.kind == :captured_prefix
    assert fetch_all(ctx, output.reference, :error) == "before timeout \t\n"
    assert File.read!(Path.join(root, "retained-child-ready")) == "ready"

    # The external child would write after the timeout reply if cleanup missed it.
    Process.sleep(2_000)
    refute File.exists?(Path.join(root, "retained-late-effect"))
  end

  test "an append crossing the deadline cannot accept a queued successful exit", %{tmp_dir: root} do
    parent = self()

    injector = fn
      :before_blob_write ->
        send(parent, {:append_waiting, self()})

        receive do
          :release_append -> :ok
        end

      _point ->
        :ok
    end

    store = start_store(root, fault_injector: injector)
    ctx = context(root, store, "slow-append")
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Shell.capture("printf 'slow durable prefix'", root, 1, capture_opts(ctx))
      end)

    assert_receive {:append_waiting, ^store}, 1_000
    Process.send_after(store, :release_append, 1_100)

    assert {:error, %Output{capture: {:incomplete, :timeout}} = output} = Task.await(task, 5_000)
    assert output.view == "slow durable prefix\n[command timed out]"
    assert output.selection.kind == :captured_prefix
    assert fetch_all(ctx, output.reference, :error) == "slow durable prefix"
  end

  test "missing or dead retention refuses before the producer runs", %{tmp_dir: root} do
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _}

    for opts <- [
          [],
          [artifact_store: nil, capture_key: {:delivery, "cp", "nil"}],
          [artifact_store: dead, capture_key: {:delivery, "cp", "dead"}]
        ] do
      assert {:error, :retention_unavailable} =
               Shell.capture("touch producer-ran", root, 5, opts)
    end

    refute File.exists?(Path.join(root, "producer-ran"))
  end

  test "quota refusal before startup does not execute the producer", %{tmp_dir: root} do
    store = start_store(root, limits: [session_artifacts: 1])
    ctx = context(root, store, "first")
    assert {:ok, _} = Shell.capture("printf first", root, 5, capture_opts(ctx))
    ctx = context(root, store, "second")

    assert {:error, :session_artifact_limit} =
             Shell.capture("touch producer-ran", root, 5, capture_opts(ctx))

    refute File.exists?(Path.join(root, "producer-ran"))
  end

  test "disk full returns a fetchable incomplete prefix instead of success", %{tmp_dir: root} do
    store = start_store(root, fault_injector: %{before_blob_write: {:error, :enospc}})
    ctx = context(root, store, "disk-full")

    assert {:error, %Output{capture: {:incomplete, :disk_full}} = output} =
             Shell.capture(
               "printf 'not durable'; while :; do :; done",
               root,
               5,
               capture_opts(ctx)
             )

    assert output.reference.bytes == 0
    assert output.view =~ "capture incomplete: :disk_full"
    assert fetch_all(ctx, output.reference, :error) == ""
  end

  test "storage failure after producer startup is not a successful retained output", %{
    tmp_dir: root
  } do
    store = start_store(root, fault_injector: %{before_blob_write: {:error, :eio}})
    ctx = context(root, store, "io-failure")

    assert {:error, %Output{capture: {:incomplete, :capture_failed}} = output} =
             Shell.capture("printf bytes; while :; do :; done", root, 5, capture_opts(ctx))

    assert output.reference.bytes == 0
    assert fetch_all(ctx, output.reference, :error) == ""
  end

  test "bootstrap failure reports an incomplete empty capture without invented stdout", %{
    tmp_dir: root
  } do
    store = start_store(root)
    ctx = context(root, store, "bad-cwd")

    assert {:error, %Output{capture: {:incomplete, :capture_failed}} = output} =
             Shell.capture(
               "printf should-not-run",
               Path.join(root, "missing"),
               5,
               capture_opts(ctx)
             )

    assert output.view =~ "output_bootstrap"
    assert output.reference.bytes == 0
    assert fetch_all(ctx, output.reference, :error) == ""
  end

  test "a blocked store backpressures a fast producer instead of filling the worker mailbox", %{
    tmp_dir: root
  } do
    parent = self()

    injector = fn
      :before_blob_write ->
        unless Process.get(:blocked_first_append, false) do
          Process.put(:blocked_first_append, true)
          send(parent, {:append_waiting, self()})

          receive do
            :release_append -> :ok
          end
        end

        :ok

      _point ->
        :ok
    end

    store =
      start_store(root,
        limits: [capture_bytes: 65_536, image_bytes: 65_536],
        fault_injector: injector
      )

    bytes = :binary.copy("fast producer output\n", 400_000)
    File.write!(Path.join(root, "fast-output"), bytes)
    ctx = context(root, store, "backpressure")
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Shell.capture(
          "cat fast-output; printf done > producer-finished",
          root,
          5,
          capture_opts(ctx)
        )
      end)

    assert_receive {:append_waiting, ^store}, 1_000
    # The store latch stays closed while the real producer has a scheduling turn.
    Process.send_after(self(), :sample_blocked_mailbox, 100)
    assert_receive :sample_blocked_mailbox
    assert {:messages, messages} = Process.info(task.pid, :messages)

    queued_bytes =
      Enum.reduce(messages, 0, fn
        {_port, {:data, data}}, count when is_binary(data) -> count + byte_size(data)
        _message, count -> count
      end)

    assert queued_bytes <= 65_537
    assert length(messages) <= 4
    refute File.exists?(Path.join(root, "producer-finished"))
    send(store, :release_append)

    assert {:error, %Output{capture: {:incomplete, :capture_byte_limit}} = output} =
             Task.await(task, 5_000)

    assert output.reference.bytes > 0

    assert fetch_all(ctx, output.reference, :error) ==
             binary_part(bytes, 0, output.reference.bytes)
  end

  test "small output is visible before command exit rather than waiting for a full reader chunk",
       %{
         tmp_dir: root
       } do
    store = start_store(root)
    ctx = context(root, store, "incremental")
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Shell.capture(
          "printf 'early\\n'; while [ ! -f release-output ]; do :; done; printf 'late\\n'",
          root,
          5,
          capture_opts(ctx) ++
            [
              on_output: fn chunk ->
                send(parent, {:chunk, chunk})
                :ok
              end
            ]
        )
      end)

    assert_receive {:chunk, "early\n"}, 1_000
    assert Task.yield(task, 0) == nil
    File.write!(Path.join(root, "release-output"), "")
    assert {:ok, output} = Task.await(task, 5_000)
    assert output.view == "early\nlate\n"
    assert fetch_all(ctx, output.reference) == "early\nlate\n"
  end

  test "reader EOF alone cannot complete a producer that is still running", %{tmp_dir: root} do
    store = start_store(root)
    ctx = context(root, store, "eof-first")
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Shell.capture(
          "printf 'before eof\\n'; exec 1>&- 2>&-; while [ ! -f release-exit ]; do :; done; exit 42",
          root,
          5,
          capture_opts(ctx) ++
            [
              on_output: fn chunk ->
                send(parent, {:chunk, chunk})
                :ok
              end
            ]
        )
      end)

    assert_receive {:chunk, "before eof\n"}, 1_000
    assert Task.yield(task, 0) == nil
    File.write!(Path.join(root, "release-exit"), "")
    assert {:ok, output} = Task.await(task, 5_000)
    assert output.view == "before eof\n\n[exit code: 42]"
    assert fetch_all(ctx, output.reference) == "before eof\n"
  end

  test "missing or non-speaking companion refuses before the producer starts", %{tmp_dir: root} do
    store = start_store(root)

    for {id, helper} <- [
          {"missing-helper", Path.join(root, "missing-helper")},
          {"dead-helper", "/bin/true"}
        ] do
      ctx = context(root, store, id)

      assert {:error, %Output{capture: {:incomplete, :capture_failed}} = output} =
               Shell.capture(
                 "touch producer-ran",
                 root,
                 5,
                 capture_opts(ctx) ++ [helper_path: helper]
               )

      assert output.reference.bytes == 0
      assert output.view =~ "output_reader"
      refute File.exists?(Path.join(root, "producer-ran"))
      assert fetch_all(ctx, output.reference, :error) == ""
    end
  end

  test "reader death after an admitted append preserves the exact durable prefix", %{
    tmp_dir: root
  } do
    parent = self()

    injector = fn
      :before_blob_write ->
        send(parent, {:append_waiting, self()})

        receive do
          :release_append -> :ok
        end

      _point ->
        :ok
    end

    store = start_store(root, fault_injector: injector)
    bytes = :binary.copy("retained prefix λ\n", 10_000)
    File.write!(Path.join(root, "reader-death-output"), bytes)
    ctx = context(root, store, "reader-death")
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Shell.capture("cat reader-death-output", root, 5, capture_opts(ctx))
      end)

    assert_receive {:append_waiting, ^store}, 1_000
    assert {:links, links} = Process.info(task.pid, :links)

    helper =
      Enum.find(links, fn
        port when is_port(port) ->
          case Port.info(port, :name) do
            {:name, name} ->
              List.to_string(name) |> String.ends_with?("minga-shell-output-reader")

            nil ->
              false
          end

        _link ->
          false
      end)

    assert is_port(helper)
    assert Port.close(helper)
    send(store, :release_append)

    assert {:error, %Output{capture: {:incomplete, :capture_failed}} = output} =
             Task.await(task, 5_000)

    assert output.reference.bytes > 0
    assert output.view =~ "output_reader"

    assert fetch_all(ctx, output.reference, :error) ==
             binary_part(bytes, 0, output.reference.bytes)
  end

  defp start_store(root, opts \\ []) do
    limits = Keyword.get(opts, :limits, [])

    quota =
      start_supervised!(
        Supervisor.child_spec({ArtifactQuota, root: root, limits: limits},
          id: {:quota, make_ref()},
          restart: :temporary
        )
      )

    start_supervised!(
      Supervisor.child_spec(
        {ArtifactStore, [root: root, quota: quota, session_id: "retained-shell"] ++ opts},
        id: {:store, make_ref()},
        restart: :temporary
      )
    )
  end

  defp context(root, store, id) do
    Context.new(
      project_root: root,
      artifact_store: store,
      capture_key: {:delivery, "checkpoint", id}
    )
  end

  defp capture_opts(ctx), do: [artifact_store: ctx.artifact_store, capture_key: ctx.capture_key]

  defp fetch_all(ctx, reference, tag \\ :ok) do
    starts =
      if reference.bytes == 0, do: [0], else: Enum.to_list(0..(reference.bytes - 1)//51_200)

    Enum.map_join(starts, fn start ->
      assert {^tag, output} =
               FetchOutput.execute(ctx, %{
                 "reference" =>
                   Map.new(Map.from_struct(reference), fn {key, value} ->
                     {Atom.to_string(key), value}
                   end),
                 "unit" => "bytes",
                 "start" => start,
                 "count" => min(51_200, reference.bytes - start)
               })

      case output.view do
        "[base64; bytes=" <> _ ->
          output.view |> String.split("\n", parts: 2) |> List.last() |> Base.decode64!()

        text ->
          text
      end
    end)
  end

  defp chunks(acc \\ []) do
    receive do
      {:chunk, chunk} -> chunks([chunk | acc])
    after
      0 -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end
