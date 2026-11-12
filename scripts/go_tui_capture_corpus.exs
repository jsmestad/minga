defmodule Minga.Scripts.GoTUICaptureCorpus do
  @moduledoc """
  Committed semantic packets for production Go terminal-output capture (#3445).

  Regenerate: mix run --no-start scripts/go_tui_capture_corpus.exs
  Verify: mix run --no-start scripts/go_tui_capture_corpus.exs --check

  This only encodes pure models: no application startup, user configuration, or model API calls.
  The renderer sends ready; these are BEAM-to-frontend batches without the outer packet-4 length supplied by the capture driver.
  This is not the model-level conformance corpus (#2101) or the retired Zig snapshots.
  """

  alias Minga.Frontend.Adapter.GUI.AgentChatEncoder
  alias Minga.Frontend.Adapter.GUI.AgentTranscriptEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.StatusBarEncoder
  alias Minga.Frontend.Adapter.GUI.ThemeEncoder
  alias Minga.Frontend.Adapter.GUI.WindowEncoder
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.AgentChat.ApprovalView
  alias Minga.RenderModel.UI.AgentChat.ToolCallView
  alias Minga.RenderModel.UI.StatusBar
  alias Minga.RenderModel.UI.StatusBar.Data
  alias Minga.RenderModel.Window
  alias Minga.RenderModel.Window.GutterMetrics
  alias Minga.RenderModel.Window.PaneGeometry
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.RowDelta
  alias Minga.RenderModel.Window.Viewport
  alias MingaEditor.Frontend.FrameTransaction
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.RenderModel.UI.ThemeBuilder
  alias MingaEditor.UI.Theme.AstroDark

  @path Path.expand("../test/fixtures/go_tui_capture/agent_workspace.json", __DIR__)
  @sizes [{"narrow", 60, 24}, {"default", 80, 24}, {"wide", 140, 40}]
  @neighbors ["NEIGHBOR_TOP", "NEIGHBOR_BOTTOM"]
  @header "CAPTURE_HEADER"
  @old_labels ~w(USER_OLD ASSIST_OLD TOOL_OLD RESULT_OLD APPROVAL_OLD COMPOSE_OLD STATUS_OLD)
  @new_labels ~w(USER_NEW ASSIST_NEW TOOL_NEW RESULT_NEW APPROVAL_NEW COMPOSE_NEW STATUS_NEW)

  @spec run([String.t()]) :: :ok
  def run(args) when args in [[], ["--check"]] do
    bytes = corpus() |> JSON.encode!() |> Kernel.<>("\n")

    case args do
      [] ->
        File.mkdir_p!(Path.dirname(@path))
        File.write!(@path, bytes)
        IO.puts("Wrote #{@path}")

      ["--check"] ->
        if File.read!(@path) != bytes do
          raise "Capture corpus differs; regenerate with mix run --no-start scripts/go_tui_capture_corpus.exs"
        end

        IO.puts("Capture corpus matches canonical encoders (3 sizes, 5 committed steps each)")
    end
  end

  def run(_args),
    do: raise("Usage: mix run --no-start scripts/go_tui_capture_corpus.exs [--check]")

  @spec corpus() :: map()
  defp corpus do
    %{
      "version" => 1,
      "theme" => "astrodark",
      # Idle chrome, completed tools and an unfocused composer need no text-cell masks. No production static/reduced-motion setting is invented here.
      "dynamic_cells" => [],
      "sizes" => Enum.map(@sizes, &size/1)
    }
  end

  @spec size({String.t(), pos_integer(), pos_integer()}) :: map()
  defp size({name, columns, rows}) do
    {workspace, caches} = workspace_commands("OLD", 1, Caches.new())
    base_window = window(columns, rows, "ROW_OLD")
    delta_window = window(columns, rows, "ROW_NEW")
    {hide, _caches} = AgentChatEncoder.encode(%AgentChat{visible?: false}, caches)
    delta = RowDelta.from_snapshots(base_window.rows, delta_window.rows)
    hashes = Map.new(base_window.rows, &{&1.row_id, &1.content_hash})
    {row_delta, false} = WindowEncoder.encode_rows_delta(delta_window, delta, hashes)
    {replacement, _caches} = workspace_commands("NEW", 2, Caches.new())

    # AgentChat.Visible replaces the entire editor body in the production Go renderer.
    # Seed visible editor rows in a separate scene, not hidden rows behind the agent workspace.
    # A2 changes ONLY the middle row in the same content epoch; its neighbors must survive without being resent.
    steps = [
      step("workspace", 1, 0, workspace, @old_labels ++ ["Approval", "y approve"], @new_labels),
      step(
        "row-base",
        2,
        1,
        [hide] ++ WindowEncoder.encode(base_window) ++ [status("STATUS_ROWS")],
        @neighbors ++ ["ROW_OLD", "STATUS_ROWS"],
        @old_labels ++ ["ROW_NEW"]
      ),
      step(
        "row-delta",
        3,
        2,
        [row_delta],
        @neighbors ++ ["ROW_NEW", "STATUS_ROWS"],
        ["ROW_OLD" | @old_labels]
      ),
      step(
        "unknown-opcode",
        4,
        3,
        [unknown_command(), status("UNKNOWN_OK")],
        @neighbors ++ ["ROW_NEW", "UNKNOWN_OK"],
        ["ROW_OLD", "STATUS_ROWS" | @old_labels]
      ),
      step(
        "replacement",
        5,
        0,
        replacement,
        @new_labels ++ ["Approval", "y approve"],
        @old_labels ++ @neighbors ++ ["ROW_OLD", "ROW_NEW", "UNKNOWN_OK", "STATUS_ROWS"]
      )
    ]

    %{"name" => name, "columns" => columns, "rows" => rows, "steps" => steps}
  end

  @spec workspace_commands(String.t(), pos_integer(), Caches.t()) :: {[binary()], Caches.t()}
  defp workspace_commands(suffix, epoch, caches) do
    {theme, caches} = ThemeEncoder.encode(AstroDark.theme() |> ThemeBuilder.build(), caches)
    chat = chat(suffix, epoch)
    {chrome, caches} = AgentChatEncoder.encode(chat, caches)
    {transcript, caches} = AgentTranscriptEncoder.encode(chat, caches)

    {[Protocol.encode_set_title(@header), theme, chrome, transcript, status("STATUS_#{suffix}")],
     caches}
  end

  @spec chat(String.t(), pos_integer()) :: AgentChat.t()
  defp chat(suffix, epoch) do
    %AgentChat{
      visible?: true,
      status: :idle,
      model_name: "capture:fixed",
      prompt: "COMPOSE_#{suffix}",
      prompt_vim_mode: :normal,
      input_focused: false,
      transcript_epoch: epoch,
      resident_messages: [
        {1, {:user, "USER_#{suffix}"}},
        {2, {:assistant, "ASSIST_#{suffix}"}},
        {3,
         {:tool_call,
          %ToolCallView{
            name: "shell",
            summary: "TOOL_#{suffix}",
            result: "RESULT_#{suffix}",
            status: :complete,
            collapsed: false,
            duration_ms: 125
          }}},
        {4,
         {:approval_tool_call,
          %ApprovalView{
            name: "shell",
            tool_call_id: "capture-approval-#{epoch}",
            summary: "APPROVAL_#{suffix}",
            preview_kind: :command
          }}}
      ]
    }
  end

  @spec window(pos_integer(), pos_integer(), String.t()) :: Window.t()
  defp window(columns, rows, middle) do
    height = rows - 2
    rect = {0, 0, columns, height}

    %Window{
      window_id: 1,
      content_kind: :buffer,
      rect: rect,
      rows: Enum.with_index(["NEIGHBOR_TOP", middle, "NEIGHBOR_BOTTOM"], &row/2),
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block,
      cursor_visible: false,
      content_epoch: 1,
      full_refresh: middle == "ROW_OLD",
      contiguous_rows: true,
      geometry: %PaneGeometry{
        window_id: 1,
        total_rect: rect,
        content_rect: rect,
        text_rect: rect,
        gutter_rect: {0, 0, 0, height},
        clip_rect: rect,
        viewport: %Viewport{top: 0, left: 0, rows: height, cols: columns, total_lines: 3},
        gutter_metrics: %GutterMetrics{line_number_width: 0, sign_col_width: 0},
        hit_regions: []
      }
    }
  end

  @spec row(String.t(), non_neg_integer()) :: Row.t()
  defp row(text, index) do
    %Row{
      row_id: Row.stable_id(:normal, index),
      row_type: :normal,
      buf_line: index,
      visual_index: index,
      text: text,
      spans: [],
      content_hash: Row.compute_hash(text, [])
    }
  end

  @spec status(String.t()) :: binary()
  defp status(label) do
    StatusBarEncoder.encode_command(%StatusBar{
      content_kind: :buffer,
      data: %Data{message: label}
    })
  end

  @spec unknown_command() :: binary()
  defp unknown_command do
    # Unknown GUI opcodes >= 0x90 use len16 forward-compatible framing.
    # This is deliberately not a known command encoder; the following status command in the SAME committed batch proves the reader resumes at the right offset.
    Writer.new(:capture_unknown)
    |> Writer.uint8(:opcode, 0xFF)
    |> Writer.payload16(:payload, "SKIP_ME")
    |> Writer.finish()
  end

  @spec step(String.t(), pos_integer(), non_neg_integer(), [binary()], [String.t()], [String.t()]) ::
          map()
  defp step(label, seq, base, body, present, absent) do
    commands =
      [Protocol.encode_begin_frame(seq, base, 1) | body] ++ [Protocol.encode_commit_frame(seq)]

    :ok = FrameTransaction.validate(commands)

    %{
      "label" => label,
      "payload_base64" => commands |> IO.iodata_to_binary() |> Base.encode64(),
      "present" => [@header | Enum.map(present, &with_status_blank/1)],
      "absent" => absent
    }
  end

  @spec with_status_blank(String.t()) :: String.t()
  defp with_status_blank("STATUS_" <> _rest = label), do: label <> " "
  defp with_status_blank("UNKNOWN_OK"), do: "UNKNOWN_OK "
  defp with_status_blank(label), do: label
end

Minga.Scripts.GoTUICaptureCorpus.run(System.argv())
