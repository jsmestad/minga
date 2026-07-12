defmodule MingaEditor.Frontend do
  @moduledoc """
  Frontend communication domain facade.

  External callers tell the frontend WHAT to do through semantic
  operations. The Frontend domain handles HOW (binary encoding,
  batching, protocol versioning) internally.

  ## Render frames

  The Editor builds a `Frame` struct (display list of styled text
  runs). `send_render_frame/2` encodes and sends it to the frontend.

  ## Parser commands

  Tree-sitter parsing runs in a separate Zig process. Parser commands
  (setup_buffer, update_buffer, set_queries) encode the appropriate
  wire messages and send them to the parser port.

  ## Configuration

  Font, title, theme, and window background are set through
  individual semantic operations.
  """

  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  # ── Manager operations ───────────────────────────────────────────────────

  @doc "Sends a list of pre-encoded commands to the frontend process."
  @spec send_commands(GenServer.server(), [binary()]) :: :ok
  def send_commands(server \\ MingaEditor.Frontend.Manager, commands),
    do: MingaEditor.Frontend.Manager.send_commands(server, commands)

  @doc """
  Sends the per-frame render batch and stamps a monotonic send time so the
  frontend emits a `[:minga, :render, :hop_latency]` (`hop: :send_commands`)
  sample for the Renderer.Server → Port.Manager scheduling delay.
  """
  @spec send_render_commands(GenServer.server(), [binary()]) :: :ok
  def send_render_commands(server \\ MingaEditor.Frontend.Manager, commands),
    do: MingaEditor.Frontend.Manager.send_render_commands(server, commands)

  @doc "Subscribes the calling process to frontend events."
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ MingaEditor.Frontend.Manager),
    do: MingaEditor.Frontend.Manager.subscribe(server)

  @doc "Returns the terminal dimensions {width, height}."
  @spec terminal_size(GenServer.server()) :: {pos_integer(), pos_integer()} | nil
  def terminal_size(server \\ MingaEditor.Frontend.Manager),
    do: MingaEditor.Frontend.Manager.terminal_size(server)

  @doc "Returns true if the frontend is ready to receive commands."
  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server \\ MingaEditor.Frontend.Manager),
    do: MingaEditor.Frontend.Manager.ready?(server)

  @doc "Returns the frontend capabilities struct."
  @spec capabilities(GenServer.server()) :: MingaEditor.Frontend.Capabilities.t()
  def capabilities(server \\ MingaEditor.Frontend.Manager),
    do: MingaEditor.Frontend.Manager.capabilities(server)

  # ── Capabilities ─────────────────────────────────────────────────────────

  @doc "Returns true if the frontend supports GUI chrome opcodes."
  @spec gui?(MingaEditor.Frontend.Capabilities.t()) :: boolean()
  def gui?(caps), do: MingaEditor.Frontend.Capabilities.gui?(caps)

  @doc "Returns true if the frontend supports semantic render-model opcodes."
  @spec semantic_ui?(MingaEditor.Frontend.Capabilities.t()) :: boolean()
  def semantic_ui?(caps), do: MingaEditor.Frontend.Capabilities.semantic_ui?(caps)

  @doc "Returns the default capabilities struct."
  @spec default_capabilities() :: MingaEditor.Frontend.Capabilities.t()
  def default_capabilities, do: MingaEditor.Frontend.Capabilities.default()

  @doc """
  Sends a bare, content-free frame transaction to the frontend (#2219).

  Used by frame-synchronization contracts that must emit a frame boundary without
  re-rendering (the operator-pending no-op optimization). Brackets nothing with
  `begin_frame ++ commit_frame`. `frame_seq` is the strictly monotonic global frame
  sequence; `base_frame_seq` names the previously emitted frame (0 for the first).
  `input_seq` is the echoed input correlation sequence (ticket #2215, default 0).
  """
  @spec send_frame_boundary(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok
  def send_frame_boundary(port, frame_seq, base_frame_seq, input_seq \\ 0) do
    send_commands(port, [
      Protocol.encode_begin_frame(frame_seq, base_frame_seq, 1),
      Protocol.encode_commit_frame(frame_seq, input_seq)
    ])
  end

  # ── Configuration ────────────────────────────────────────────────────────

  @doc "Sets the window title."
  @spec set_title(GenServer.server(), String.t()) :: :ok
  def set_title(port \\ MingaEditor.Frontend.Manager, title) do
    send_commands(port, [Protocol.encode_set_title(title)])
  end

  @doc "Sets the window background color."
  @spec set_window_bg(GenServer.server(), non_neg_integer()) :: :ok
  def set_window_bg(port \\ MingaEditor.Frontend.Manager, color) do
    send_commands(port, [Protocol.encode_set_window_bg(color)])
  end

  @doc """
  Toggles the GUI go-to-definition link cursor (#2630).

  Emitted out-of-band (post-commit) like `set_title`, so it joins the frontend
  out-of-band allowlist. The GUI shows `NSCursor.pointingHand` while `active`.
  """
  @spec set_link_cursor(GenServer.server(), boolean()) :: :ok
  def set_link_cursor(port \\ MingaEditor.Frontend.Manager, active) do
    send_commands(port, [Protocol.encode_set_link_cursor(active)])
  end

  @doc "Configures the editor font."
  @spec configure_font(GenServer.server(), String.t(), pos_integer(), boolean(), atom(), [
          String.t()
        ]) ::
          :ok
  def configure_font(port, family, size, ligatures, weight, fallbacks \\ []) do
    cmds = [Protocol.encode_set_font(family, size, ligatures, weight)]

    cmds =
      if fallbacks != [] do
        Enum.concat(cmds, [Protocol.encode_set_font_fallback(fallbacks)])
      else
        cmds
      end

    send_commands(port, cmds)
  end

  # line_spacing, cursor_animation, and config_state are no longer pushed
  # out-of-band (#2119). They are emitted in-frame as semantic models by
  # Minga.Frontend.Adapter.GUI (LineSpacingEncoder / CursorAnimationEncoder /
  # ConfigStateEncoder), so a late-attaching client's keyframe carries them.

  @doc "Decodes a binary event from the frontend or parser process."
  @spec decode_event(binary()) ::
          {:ok, MingaEditor.Frontend.Protocol.input_event()}
          | {:error, :unknown_opcode | :malformed}
  def decode_event(data), do: Protocol.decode_event(data)

  # ── GUI Chrome ───────────────────────────────────────────────────────────

  @doc "Sends a clipboard write command to the GUI frontend."
  @spec clipboard_write(GenServer.server(), String.t(), atom()) :: :ok
  def clipboard_write(port, text, pasteboard \\ :general) do
    send_commands(port, [ProtocolGUI.encode_clipboard_write(text, pasteboard)])
  end
end
