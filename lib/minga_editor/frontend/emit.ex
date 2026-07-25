defmodule MingaEditor.Frontend.Emit do
  @moduledoc """
  Stage 7: Emit.

  Encodes the composed frame as semantic render-model protocol commands, then handles shared title and window-background side channels.
  """

  alias MingaEditor.RenderModel.Builder, as: RenderModelBuilder
  alias MingaEditor.RenderPipeline.Chrome
  alias MingaEditor.RenderPipeline.ComposedFrame
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Renderer.Caches
  alias MingaEditor.UI.FontRegistry
  alias Minga.Telemetry

  @typedoc "Emit context containing only the data emit needs."
  @type ctx :: Context.t()

  @doc """
  Converts the frame to semantic protocol command binaries and sends them to the frontend port.

  Also sends title and window background color when they change
  (side-channel writes). Returns updated caches, the renderer-owned font
  registry, and the message store for write-back to the Editor process.
  """
  @spec emit(ComposedFrame.t(), ctx(), Chrome.t() | nil, Caches.t()) ::
          {Caches.t(), FontRegistry.t(), MingaEditor.UI.Panel.MessageStore.t()}
  def emit(frame, ctx, chrome \\ nil, caches \\ %Caches{}) do
    FontRegistry.with_process_registry(ctx.font_registry, fn ->
      {caches, ctx} = emit_semantic(frame, ctx, chrome, caches)
      {caches, FontRegistry.current_process_registry(ctx.font_registry), ctx.message_store}
    end)
  end

  @spec emit_semantic(ComposedFrame.t(), ctx(), Chrome.t() | nil, Caches.t()) ::
          {Caches.t(), ctx()}
  defp emit_semantic(frame, ctx, chrome, caches) do
    {render_model, ctx} =
      Telemetry.span([:minga, :render, :ui_model_build], %{}, fn ->
        RenderModelBuilder.build(frame, ctx, chrome)
      end)

    # Frame transaction (#2219). frame_seq is the strictly monotonic global frame
    # sequence (Renderer.Server's seq on the async path; a fresh monotonic value on
    # sync/headless paths). A keyframe is forced by an inbound request_keyframe, and
    # is also the first-frame state (no committed base yet). A keyframe drops the
    # adapter delta caches so every window emits full content and every chrome
    # surface re-emits, and brackets the frame with base_frame_seq 0.
    frame_seq = frame_seq(ctx)

    acknowledged_base =
      if ctx.acknowledgement_required?,
        do: caches.last_acknowledged_frame_seq,
        else: caches.last_emitted_frame_seq

    keyframe? = ctx.intent.frame.force_keyframe? or acknowledged_base == 0
    base_frame_seq = if keyframe?, do: 0, else: acknowledged_base

    caches =
      if keyframe? do
        # A keyframe re-establishes the frontend from scratch, so drop every
        # side-channel delta cache too: clearing last_title/last_window_bg forces
        # the title and window background to re-send, restoring a frontend that lost
        # them mid-session (mirrors Caches.reset_frontend_state/1) (#2219).
        %{
          caches
          | adapter_gui_caches: Minga.Frontend.Adapter.GUI.Caches.new(),
            last_title: nil,
            last_window_bg: nil,
            last_link_cursor: nil
        }
      else
        caches
      end

    case encode_adapter_frame(render_model, caches) do
      {:error, error} ->
        Minga.Log.warning(:render, "Discarded invalid GUI frame: #{Exception.message(error)}")

        {Caches.reset_frontend_state(caches), ctx}

      {:ok, encoded_frame} ->
        emit_encoded_frame(
          encoded_frame,
          render_model,
          ctx,
          caches,
          frame_seq,
          base_frame_seq,
          keyframe?
        )
    end
  end

  @spec encode_adapter_frame(Minga.RenderModel.t(), Caches.t()) ::
          {:ok, Minga.Frontend.Adapter.GUI.EncodedFrame.t()} | {:error, Exception.t()}
  defp encode_adapter_frame(render_model, caches) do
    Telemetry.span_with_stop_metadata([:minga, :render, :adapter_encode], %{}, fn ->
      case Minga.Frontend.Adapter.GUI.encode_checked(render_model, caches.adapter_gui_caches) do
        {:ok, encoded_frame} ->
          {{:ok, encoded_frame}, adapter_encode_metadata(encoded_frame.metrics)}

        {:error, error} ->
          {{:error, error}, %{encoding_error: true}}
      end
    end)
  end

  @spec emit_encoded_frame(
          Minga.Frontend.Adapter.GUI.EncodedFrame.t(),
          Minga.RenderModel.t(),
          ctx(),
          Caches.t(),
          non_neg_integer(),
          non_neg_integer(),
          boolean()
        ) :: {Caches.t(), ctx()}
  defp emit_encoded_frame(
         encoded_frame,
         render_model,
         ctx,
         caches,
         frame_seq,
         base_frame_seq,
         keyframe?
       ) do
    caches = %{caches | adapter_gui_caches: encoded_frame.caches}
    input_seq = ctx.intent.frame.last_input_seq

    surface_layout_command =
      Minga.Frontend.Adapter.GUI.SurfaceLayoutEncoder.encode_command(ctx.surface_placements)

    commands =
      [Protocol.encode_begin_frame(frame_seq, base_frame_seq, caches.recovery_generation)] ++
        flush_font_registration_commands() ++
        encoded_frame.metal_commands ++
        encoded_frame.chrome_commands ++
        [surface_layout_command, Protocol.encode_commit_frame(frame_seq, input_seq)]

    if keyframe? do
      Minga.Log.info(
        :render,
        "Emitting keyframe #{frame_seq} in response to frontend recovery or attach"
      )
    end

    caches = %{caches | last_emitted_frame_seq: frame_seq, last_frame_keyframe?: keyframe?}

    caches =
      if ctx.acknowledgement_required?,
        do: caches,
        else: Caches.acknowledge_frame(caches, frame_seq, caches.recovery_generation)

    byte_count = IO.iodata_length(commands)

    Telemetry.span(
      [:minga, :render, :emit_prepare],
      %{byte_count: byte_count, input_seq: input_seq, frame_seq: frame_seq, keyframe?: keyframe?},
      fn ->
        port_manager = ctx.intent.frame.port_manager
        _admission = MingaEditor.Frontend.send_render_commands(port_manager, commands)
        caches = send_title(render_model, port_manager, caches)
        caches = send_window_bg(render_model, port_manager, caches)
        {send_link_cursor(ctx, port_manager, caches), ctx}
      end
    )
  rescue
    error in [Minga.Protocol.EncodingError, Minga.Frontend.Adapter.GUI.EncodingError] ->
      Minga.Log.warning(:render, "Discarded invalid GUI frame: #{Exception.message(error)}")

      {Caches.reset_frontend_state(caches), ctx}
  end

  # The async render path threads Renderer.Server's monotonic seq through the
  # context; sync/headless paths leave it nil, so we mint a fresh monotonic value
  # to keep frame_seq strictly advancing per emit on every path.
  @spec frame_seq(ctx()) :: non_neg_integer()
  defp frame_seq(%{frame_seq: seq}) when is_integer(seq) and seq >= 0, do: seq
  defp frame_seq(_ctx), do: System.unique_integer([:positive, :monotonic])

  @spec adapter_encode_metadata(Minga.Frontend.Adapter.GUI.EncodedFrame.metrics()) :: map()
  defp adapter_encode_metadata(metrics) do
    window_metrics = metrics.window

    %{
      window_row_bytes: window_metrics.row_bytes,
      window_overlay_bytes: window_metrics.overlay_bytes,
      window_gutter_bytes: window_metrics.gutter_bytes,
      window_annotation_bytes: window_metrics.annotation_bytes,
      window_metadata_bytes: window_metrics.metadata_bytes,
      metal_ui_bytes: metrics.metal_ui_bytes,
      chrome_bytes: metrics.chrome_bytes
    }
  end

  # ── Font registry context (shared) ───────────────────────────────────────

  @spec flush_font_registration_commands() :: [binary()]
  defp flush_font_registration_commands do
    registry = FontRegistry.current_process_registry(FontRegistry.new())

    commands =
      registry
      |> FontRegistry.pending_registrations()
      |> Enum.map(fn {font_id, family} -> Protocol.encode_register_font(font_id, family) end)

    registry
    |> FontRegistry.mark_registered()
    |> FontRegistry.put_process_registry()

    commands
  end

  # ── Side-channel writes (shared) ─────────────────────────────────────────

  @spec send_title(Minga.RenderModel.t() | ctx(), GenServer.server() | nil, Caches.t()) ::
          Caches.t()
  defp send_title(%Minga.RenderModel{title: title}, port_manager, caches) do
    if title != caches.last_title do
      case MingaEditor.Frontend.set_title(port_manager, title) do
        :accepted -> %{caches | last_title: title}
        :unwritable -> caches
      end
    else
      caches
    end
  end

  @spec send_window_bg(Minga.RenderModel.t() | ctx(), GenServer.server() | nil, Caches.t()) ::
          Caches.t()
  defp send_window_bg(%Minga.RenderModel{window_bg: bg}, port_manager, caches) do
    if bg != caches.last_window_bg do
      case MingaEditor.Frontend.set_window_bg(port_manager, bg) do
        :accepted -> %{caches | last_window_bg: bg}
        :unwritable -> caches
      end
    else
      caches
    end
  end

  # Edge-triggered out-of-band cursor hint for the Cmd/Ctrl+hover link preview
  # (#2630). Mirrors send_title/send_window_bg: only emits when the navigable
  # state flips, so an unchanged preview never re-sends. GUI-only by construction
  # (ctx.link_cursor is gated on gui? when the context is built).
  @spec send_link_cursor(ctx(), GenServer.server() | nil, Caches.t()) :: Caches.t()
  defp send_link_cursor(%{gui?: true, link_cursor: active}, port_manager, caches) do
    if active != caches.last_link_cursor do
      case MingaEditor.Frontend.set_link_cursor(port_manager, active) do
        :accepted -> %{caches | last_link_cursor: active}
        :unwritable -> caches
      end
    else
      caches
    end
  end

  defp send_link_cursor(_ctx, _port_manager, caches), do: caches
end
