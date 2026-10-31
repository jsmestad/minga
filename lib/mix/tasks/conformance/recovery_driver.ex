defmodule Mix.Tasks.Conformance.RecoveryDriver do
  @moduledoc "Closed-loop conformance driver over the real Editor, Layout, Renderer.Server and Manager."
  alias MingaEditor.Frontend.{Capabilities, Manager, Protocol}
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.Server

  @type t :: %{
          editor: pid(),
          renderer: pid(),
          manager: pid(),
          port: port(),
          oracle: pid(),
          opts: keyword()
        }

  @doc "Owns an isolated editor and capturing frontend for one transcript."
  @spec with_driver(keyword(), (t() -> result)) :: result when result: var
  def with_driver(opts, fun) do
    parent = self()
    capture = make_ref()

    {:ok, keymaps} =
      Minga.Keymap.Active.start_link(
        name: nil,
        scope_modules: Minga.Keymap.Scope.builtin_modules()
      )

    {:ok, options} = Minga.Config.Options.start_link(name: nil)

    {:ok, manager} =
      Manager.start_link(
        name: nil,
        renderer_path: "/nonexistent",
        port_mode: :connected,
        port_opener: fn _, _ -> Port.open({:spawn, "cat"}, [:binary, {:packet, 4}]) end,
        command_observer: fn commands -> send(parent, {capture, :commands, commands}) end,
        port_commander: fn _, batch, [:nosuspend] ->
          send(parent, {capture, :batch, batch})
          true
        end
      )

    port = :sys.get_state(manager).port
    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)
    capabilities = <<1, 2, 1, 0, 1, 0, 1>>
    version = Minga.Protocol.Opcodes.protocol_version()

    send(
      manager,
      {port, {:data, <<3, cols::16, rows::16, 1, 7, capabilities::binary, version::16>>}}
    )

    true = Manager.ready?(manager)

    content =
      Keyword.get_lazy(opts, :content, fn ->
        Enum.map_join(0..63, "\n", &"recovery line #{&1}")
      end)

    {:ok, buffer} =
      Minga.Buffer.start_link(
        content: content,
        buffer_name: "Conformance",
        options_server: options
      )

    {:ok, 0} = Minga.Buffer.set_option(buffer, :auto_save_delay_ms, 0)
    pane_generations = :atomics.new(1, signed: false)

    {:ok, generation} =
      MingaEditor.GenerationSupervisor.start_editor_generation_link(
        name: nil,
        backend: :headless,
        rendering: :disabled,
        port_manager: manager,
        buffer: buffer,
        options_server: options,
        keymap_server: keymaps,
        width: cols,
        height: rows,
        project_root: nil,
        editing_model: :vim,
        pane_generation_allocator: fn -> :atomics.add_get(pane_generations, 1, 1) end,
        shell: :traditional,
        suppress_tool_prompts: true
      )

    {:ok, editor} = MingaEditor.GenerationSupervisor.editor_owner(generation)
    send(editor, {:minga_input, {:ready, cols, rows}})
    _ = :sys.get_state(editor)
    epochs = :atomics.new(1, signed: false)
    generations = :atomics.new(1, signed: false)

    {:ok, renderer} =
      Server.start_link(
        name: nil,
        editor_pid: nil,
        frontend_manager: manager,
        require_ack?: true,
        ack_timeout_ms: 60_000,
        recovery_reserver: fn -> {:atomics.add_get(generations, 1, 1), 1} end,
        content_epoch_allocator: fn -> :atomics.add_get(epochs, 1, 1) end
      )

    {:ok, oracle} = Agent.start_link(&Mix.Tasks.Conformance.RecoveryOracle.empty/0)

    opts =
      Keyword.put_new(opts, :capabilities, %Capabilities{
        frontend_type: :native_gui,
        semantic_ui: true
      })

    driver = %{
      editor: editor,
      renderer: renderer,
      manager: manager,
      port: port,
      oracle: oracle,
      opts: Keyword.put(opts, :capture, capture)
    }

    try do
      fun.(driver)
    after
      GenServer.stop(renderer)
      Agent.stop(oracle)
      Supervisor.stop(generation)
      GenServer.stop(buffer)
      GenServer.stop(manager)
      GenServer.stop(options)
      GenServer.stop(keymaps)
      flush(capture)
    end
  end

  @doc "Renders a real EditorState submission synchronously, retaining its acknowledgement lease."
  @spec render(t(), non_neg_integer()) :: map()
  def render(driver, seq) do
    state = :sys.get_state(driver.editor)

    intent =
      state |> Intent.from_editor_state(seq) |> Intent.for_frontend(driver.manager, driver.opts)

    {_render, submission} = MingaEditor.State.Render.prepare_submission(state.render, intent, %{})
    {:ok, _receipt} = Server.render_sync(driver.renderer, submission, seq)
    capture(driver)
  end

  @doc "Records the frontend oracle's actual state after an altered delivery."
  @spec record_delivery(t(), map()) :: :ok
  def record_delivery(driver, %{"expect" => expect}) do
    Agent.update(driver.oracle, fn _ -> expect end)
  end

  @doc "Records the next verbatim transport batch produced by recovery."
  @spec capture(t()) :: map()
  def capture(driver) do
    tag = Keyword.fetch!(driver.opts, :capture)

    commands =
      receive do
        {^tag, :commands, commands} -> commands
      after
        5_000 -> raise "renderer did not submit a recovery batch"
      end

    batch =
      receive do
        {^tag, :batch, <<0x10, _::binary>> = batch} -> batch
      after
        5_000 -> raise "Manager did not admit the recovery batch"
      end

    ^batch = IO.iodata_to_binary(commands)
    sizes = Enum.map(commands, &byte_size/1)
    _ = :sys.get_state(driver.renderer)
    side_channels = side_channels(tag, [])
    decoded = Protocol.decode_recorded_frame(batch, sizes)
    previous = Agent.get(driver.oracle, & &1)
    expect = Mix.Tasks.Conformance.RecoveryOracle.apply_frame(previous, decoded)

    expect =
      Mix.Tasks.Conformance.RecoveryOracle.apply_side_channels(
        expect,
        Enum.map(side_channels, &Base.decode64!/1)
      )

    lease = MingaEditor.Renderer.State.awaiting_lease(:sys.get_state(driver.renderer))
    expect = Map.put(expect, "force_keyframe", lease.attempt.intent.frame.force_keyframe?)
    Agent.update(driver.oracle, fn _ -> expect end)

    %{
      "kind" => "framed",
      "payload_base64" => Base.encode64(batch),
      "command_sizes" => sizes,
      "after_commands_base64" => side_channels,
      "expect" => expect
    }
  end

  @doc "Injects an acknowledgement at both real connection owners and records the return edge."
  @spec acknowledge(t(), map()) :: map()
  def acknowledge(driver, frame) do
    result = frame["expect"]["transaction_result"]
    status(driver, {:frame_applied, result["generation"], result["frame_seq"]})
  end

  @doc "Injects one decoded frontend status; timeout is a local renderer event."
  @spec status(t(), tuple()) :: map()
  def status(driver, {:frame_applied, generation, seq} = status) do
    send(driver.manager, {driver.port, {:data, <<0x0A, generation::32, seq::32>>}})
    _ = Manager.output_pressure(driver.manager)
    Server.frame_status(driver.renderer, status)
    _ = Server.acknowledgement_state(driver.renderer)

    %{
      "kind" => "frame_status",
      "event" => "frame_applied",
      "generation" => generation,
      "frame_seq" => seq
    }
  end

  def status(driver, {:frame_rejected, generation, seq, base, reason, disposition} = status) do
    Server.frame_status(driver.renderer, status)

    %{
      "kind" => "frame_status",
      "event" => "frame_rejected",
      "generation" => generation,
      "frame_seq" => seq,
      "last_applied_frame_seq" => base,
      "reason" => reason_code(reason),
      "disposition" => disposition_code(disposition)
    }
  end

  def status(driver, {:window_ref_miss, generation, seq, base, window_id} = status) do
    Server.frame_status(driver.renderer, status)

    %{
      "kind" => "frame_status",
      "event" => "window_reference_miss",
      "generation" => generation,
      "frame_seq" => seq,
      "last_applied_frame_seq" => base,
      "window_id" => window_id
    }
  end

  @doc "Reports a frontend-owned row fit through the actual Editor resize handler."
  @spec resize(t(), pos_integer(), pos_integer()) :: map()
  def resize(driver, rows, cols) do
    send(driver.editor, {:minga_input, {:resize, cols, rows}})
    state = :sys.get_state(driver.editor)
    ^rows = state.frontend.terminal_viewport.rows
    ^cols = state.frontend.terminal_viewport.cols
    %{"kind" => "resize", "rows" => rows, "cols" => cols}
  end

  @doc "Expires exactly the outstanding lease without sleeping or racing a wall clock."
  @spec timeout(t(), map()) :: map()
  def timeout(driver, frame) do
    result = frame["expect"]["transaction_result"]
    send(driver.renderer, {:frame_ack_timeout, result["generation"], result["frame_seq"]})

    %{
      "kind" => "frame_status",
      "event" => "ack_timeout",
      "generation" => result["generation"],
      "frame_seq" => result["frame_seq"]
    }
  end

  defp reason_code(:base_sequence_mismatch), do: 4
  defp reason_code(:window_epoch_mismatch), do: 8
  defp disposition_code(:retryable_recovery), do: 1

  defp flush(tag) do
    receive do
      {^tag, _, _} -> flush(tag)
    after
      0 -> :ok
    end
  end

  defp side_channels(tag, acc) do
    receive do
      {^tag, :batch, batch} -> side_channels(tag, [Base.encode64(batch) | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
