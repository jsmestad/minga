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
  defdelegate send_commands(server \\ MingaEditor.Frontend.Manager, commands),
    to: MingaEditor.Frontend.Manager

  @doc """
  Sends the per-frame render batch and stamps a monotonic send time so the
  frontend emits a `[:minga, :render, :hop_latency]` (`hop: :send_commands`)
  sample for the Renderer.Server → Port.Manager scheduling delay.
  """
  @spec send_render_commands(GenServer.server(), [binary()]) :: :ok
  defdelegate send_render_commands(server \\ MingaEditor.Frontend.Manager, commands),
    to: MingaEditor.Frontend.Manager

  @doc "Subscribes the calling process to frontend events."
  @spec subscribe(GenServer.server()) :: :ok
  defdelegate subscribe(server \\ MingaEditor.Frontend.Manager), to: MingaEditor.Frontend.Manager

  @doc "Returns the terminal dimensions {width, height}."
  @spec terminal_size(GenServer.server()) :: {pos_integer(), pos_integer()} | nil
  defdelegate terminal_size(server \\ MingaEditor.Frontend.Manager),
    to: MingaEditor.Frontend.Manager

  @doc "Returns true if the frontend is ready to receive commands."
  @spec ready?(GenServer.server()) :: boolean()
  defdelegate ready?(server \\ MingaEditor.Frontend.Manager), to: MingaEditor.Frontend.Manager

  @doc "Returns the frontend capabilities struct."
  @spec capabilities(GenServer.server()) :: MingaEditor.Frontend.Capabilities.t()
  defdelegate capabilities(server \\ MingaEditor.Frontend.Manager),
    to: MingaEditor.Frontend.Manager

  # ── Capabilities ─────────────────────────────────────────────────────────

  @doc "Returns true if the frontend supports GUI chrome opcodes."
  @spec gui?(MingaEditor.Frontend.Capabilities.t()) :: boolean()
  defdelegate gui?(caps), to: MingaEditor.Frontend.Capabilities

  @doc "Returns true if the frontend supports semantic render-model opcodes."
  @spec semantic_ui?(MingaEditor.Frontend.Capabilities.t()) :: boolean()
  defdelegate semantic_ui?(caps), to: MingaEditor.Frontend.Capabilities

  @doc "Returns the default capabilities struct."
  @spec default_capabilities() :: MingaEditor.Frontend.Capabilities.t()
  defdelegate default_capabilities, to: MingaEditor.Frontend.Capabilities, as: :default

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
      Protocol.encode_begin_frame(frame_seq, base_frame_seq),
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

  @doc "Configures the editor font."
  @spec configure_font(GenServer.server(), String.t(), pos_integer(), boolean(), atom(), [
          String.t()
        ]) ::
          :ok
  def configure_font(port, family, size, ligatures, weight, fallbacks \\ []) do
    cmds = [Protocol.encode_set_font(family, size, ligatures, weight)]

    cmds =
      if fallbacks != [] do
        cmds ++ [Protocol.encode_set_font_fallback(fallbacks)]
      else
        cmds
      end

    send_commands(port, cmds)
  end

  # line_spacing, cursor_animation, and config_state are no longer pushed
  # out-of-band (#2119). They are emitted in-frame as semantic models by
  # Minga.Frontend.Adapter.GUI (LineSpacingEncoder / CursorAnimationEncoder /
  # ConfigStateEncoder), so a late-attaching client's keyframe carries them.

  # ── Parser/Highlight commands ────────────────────────────────────────────

  @doc """
  Sets up a buffer in the parser with language and initial content.

  Combines set_language + parse_buffer into a single batch.
  """
  @spec setup_parser_buffer(
          GenServer.server(),
          non_neg_integer(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) ::
          :ok
  def setup_parser_buffer(port, buffer_id, language, content, version) do
    cmds = [
      Protocol.encode_set_language(buffer_id, language),
      Protocol.encode_parse_buffer(buffer_id, version, content)
    ]

    send_commands(port, cmds)
  end

  @doc "Sends a full reparse of a buffer's content."
  @spec parse_buffer(GenServer.server(), non_neg_integer(), non_neg_integer(), String.t()) :: :ok
  def parse_buffer(port, buffer_id, version, content) do
    send_commands(port, [Protocol.encode_parse_buffer(buffer_id, version, content)])
  end

  @doc "Sends an incremental edit to a buffer."
  @spec edit_buffer(GenServer.server(), non_neg_integer(), non_neg_integer(), [map()]) :: :ok
  def edit_buffer(port, buffer_id, version, deltas) do
    send_commands(port, [Protocol.encode_edit_buffer(buffer_id, version, deltas)])
  end

  @doc "Sets the language for a parser buffer."
  @spec set_buffer_language(GenServer.server(), non_neg_integer(), String.t()) :: :ok
  def set_buffer_language(port, buffer_id, language) do
    send_commands(port, [Protocol.encode_set_language(buffer_id, language)])
  end

  @doc "Closes a parser buffer."
  @spec close_parser_buffer(GenServer.server(), non_neg_integer()) :: :ok
  def close_parser_buffer(port, buffer_id) do
    send_commands(port, [Protocol.encode_close_buffer(buffer_id)])
  end

  @doc "Loads a tree-sitter grammar from a shared library."
  @spec load_grammar(GenServer.server(), String.t(), String.t()) :: :ok
  def load_grammar(port, name, lib_path) do
    send_commands(port, [Protocol.encode_load_grammar(name, lib_path)])
  end

  @doc "Requests textobject positions for a buffer location."
  @spec request_textobject(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) :: :ok
  def request_textobject(port, buffer_id, request_id, row, col, capture_name) do
    send_commands(port, [
      Protocol.encode_request_textobject(buffer_id, request_id, row, col, capture_name)
    ])
  end

  @doc """
  Sets tree-sitter queries for a parser buffer.

  Accepts a keyword list of query types and their text:
  `[highlight: "...", injection: "...", fold: "...", textobject: "..."]`
  """
  @spec set_parser_queries(GenServer.server(), non_neg_integer(), keyword()) :: :ok
  def set_parser_queries(port, buffer_id, queries) do
    cmds =
      Enum.flat_map(queries, fn
        {:highlight, text} -> [Protocol.encode_set_highlight_query(buffer_id, text)]
        {:injection, text} -> [Protocol.encode_set_injection_query(buffer_id, text)]
        {:fold, text} -> [Protocol.encode_set_fold_query(buffer_id, text)]
        {:textobject, text} -> [Protocol.encode_set_textobject_query(buffer_id, text)]
      end)

    if cmds != [], do: send_commands(port, cmds), else: :ok
  end

  @doc "Decodes a binary event from the frontend or parser process."
  @spec decode_event(binary()) ::
          {:ok, MingaEditor.Frontend.Protocol.input_event()}
          | {:error, :unknown_opcode | :malformed}
  defdelegate decode_event(data), to: Protocol

  # ── GUI Chrome ───────────────────────────────────────────────────────────

  @doc "Sends a clipboard write command to the GUI frontend."
  @spec clipboard_write(GenServer.server(), String.t(), atom()) :: :ok
  def clipboard_write(port, text, pasteboard \\ :general) do
    send_commands(port, [ProtocolGUI.encode_clipboard_write(text, pasteboard)])
  end
end
