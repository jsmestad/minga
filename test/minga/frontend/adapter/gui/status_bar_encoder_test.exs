defmodule Minga.Frontend.Adapter.GUI.StatusBarEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EncodingError
  alias Minga.Frontend.Adapter.GUI.StatusBarEncoder
  alias Minga.RenderModel.UI.StatusBar
  alias Minga.RenderModel.UI.StatusBar.Agent
  alias Minga.RenderModel.UI.StatusBar.Cursor
  alias Minga.RenderModel.UI.StatusBar.Data
  alias Minga.RenderModel.UI.StatusBar.Diagnostics
  alias Minga.RenderModel.UI.StatusBar.File
  alias Minga.RenderModel.UI.StatusBar.Git
  alias Minga.RenderModel.UI.StatusBar.Indent
  alias Minga.RenderModel.UI.StatusBar.Language
  alias Minga.RenderModel.UI.StatusBar.Operation
  alias Minga.RenderModel.UI.StatusBar.Selection
  alias Minga.RenderModel.UI.StatusBar.Workspace
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.Session.ChromeState.WorkspaceSummary
  alias Minga.Language.Devicon

  @op_gui_status_bar Minga.Protocol.Opcodes.gui_status_bar()

  describe "encode/2" do
    test "matches legacy buffer status wire format" do
      legacy_data = legacy_status_data()
      chrome_state = chrome_state()
      {icon, icon_color} = Devicon.icon_and_color(legacy_data.filetype)

      model = %StatusBar{
        content_kind: :buffer,
        data: %Data{
          mode: legacy_data.mode,
          safe_mode?: legacy_data.safe_mode,
          dirty?: legacy_data.dirty,
          cursor: %Cursor{
            line: legacy_data.cursor_line,
            col: legacy_data.cursor_col,
            line_count: legacy_data.line_count
          },
          diagnostics: %Diagnostics{
            counts: legacy_data.diagnostic_counts,
            hint: legacy_data.diagnostic_hint
          },
          language: %Language{
            lsp_status: legacy_data.lsp_status,
            parser_status: legacy_data.parser_status
          },
          git: %Git{branch: legacy_data.git_branch, diff_summary: legacy_data.git_diff_summary},
          file: %File{
            name: legacy_data.file_name,
            filetype: legacy_data.filetype,
            icon: icon,
            icon_color: icon_color
          },
          message: legacy_data.status_msg,
          recording: legacy_data.macro_recording,
          indent: %Indent{type: legacy_data.indent_type, size: legacy_data.indent_size},
          selection: %Selection{mode: :chars, size: 5},
          agent: %Agent{
            agent_status: legacy_data.agent_status,
            background_count: legacy_data.background_subagent_count,
            background_label: legacy_data.active_background_subagent_label,
            active_tool_name: legacy_data.active_tool_name
          },
          modeline_segments: legacy_data.modeline_segments
        },
        workspace: workspace()
      }

      {cmd, _caches} = StatusBarEncoder.encode(model, Caches.new())

      assert cmd == ProtocolGUI.encode_gui_status_bar({:buffer, legacy_data}, chrome_state)
    end

    test "encodes semantic buffer status sections" do
      model = %StatusBar{content_kind: :buffer, data: status_data(), workspace: workspace()}
      caches = Caches.new()

      {cmd, _caches} = StatusBarEncoder.encode(model, caches)
      sections = decode_sections(cmd)

      assert <<0::8, 0::8, 0x07::8>> = sections[0x01]
      assert <<1::32, 2::32, 10::32>> = sections[0x02]
      assert <<1::16, 0::16, 0::16, 0::16, _hint::binary>> = sections[0x03]
      assert <<1::8, 5::32>> = sections[0x0C]
      assert <<0::8, 0::16, _rest::binary>> = sections[0x09]
      assert Map.has_key?(sections, 0x0D)
    end

    test "omits pending_keys section (0x0E) when empty" do
      model = %StatusBar{content_kind: :buffer, data: status_data(), workspace: workspace()}

      {cmd, _caches} = StatusBarEncoder.encode(model, Caches.new())
      sections = decode_sections(cmd)

      refute Map.has_key?(sections, 0x0E)
    end

    test "encodes pending_keys section (0x0E) when set" do
      data = %{status_data() | pending_keys: "\"a2d"}
      model = %StatusBar{content_kind: :buffer, data: data, workspace: workspace()}

      {cmd, _caches} = StatusBarEncoder.encode(model, Caches.new())
      sections = decode_sections(cmd)

      assert <<len::16, keys::binary-size(len)>> = sections[0x0E]
      assert keys == "\"a2d"
    end

    test "encodes structured-only operation feedback with every optional field" do
      operation = %Operation{
        id: 4_294_967_297,
        kind: :git_commit,
        status: :queued,
        message: "Committing...",
        queue_position: 2,
        queue_total: 5,
        progress_current: 7,
        progress_total: 10,
        cancelable?: true
      }

      data = %{status_data() | message: nil}
      model = %StatusBar{content_kind: :buffer, data: data, operation: operation}
      {cmd, _caches} = StatusBarEncoder.encode(model, Caches.new())
      sections = decode_sections(cmd)

      assert sections[0x07] == <<0::16>>

      assert <<4_294_967_297::64, 7::8, 2::8, 0x07::8, message_len::16,
               message::binary-size(message_len), 2::16, 5::16, 7::32, 10::32>> = sections[0x0F]

      assert message == "Committing..."
    end

    test "operation kind and status bytes do not depend on message punctuation" do
      kinds = [
        external_format: 1,
        git_stage: 2,
        git_unstage: 3,
        git_discard: 4,
        git_stage_all: 5,
        git_unstage_all: 6,
        git_commit: 7,
        lsp_references: 8,
        lsp_rename: 9
      ]

      statuses = [
        pending: 1,
        queued: 2,
        running: 3,
        success: 4,
        error: 5,
        timeout: 6,
        canceled: 7,
        stale: 8
      ]

      for {kind, kind_code} <- kinds, {status, status_code} <- statuses do
        base = %Operation{
          id: 1,
          kind: kind,
          status: status,
          message: "Working...",
          cancelable?: false
        }

        punctuated = operation_payload(base)
        plain = operation_payload(%{base | message: "Working"})

        assert <<1::64, ^kind_code::8, ^status_code::8, _rest::binary>> = punctuated
        assert <<1::64, ^kind_code::8, ^status_code::8, _rest::binary>> = plain
      end
    end

    test "encodes semantic agent status section" do
      data = %{
        status_data()
        | agent: %Agent{
            model_name: "Claude",
            session_status: :thinking,
            message_count: 3,
            agent_status: :thinking
          }
      }

      model = %StatusBar{content_kind: :agent, data: data, workspace: workspace()}

      {cmd, _caches} = StatusBarEncoder.encode(model, Caches.new())
      sections = decode_sections(cmd)

      assert <<model_len::8, model_name::binary-size(model_len), 3::32, 1::8, 1::8,
               _rest::binary>> = sections[0x09]

      assert model_name == "Claude"
    end

    test "encodes every wire-valid modeline segment instead of taking only 128" do
      segment = {:mode, "N", 0xFFFFFF, 0x000000, [], nil}

      data = %{
        status_data()
        | modeline_segments: %{left: List.duplicate(segment, 129), right: []}
      }

      model = %StatusBar{content_kind: :buffer, data: data}

      {cmd, _caches} = StatusBarEncoder.encode(model, Caches.new())
      sections = decode_sections(cmd)

      assert <<2::8, 129::16, 0::16, _segments::binary>> = sections[0x0B]
    end

    test "rejects an out-of-range indent size instead of clamping it" do
      data = %{status_data() | indent: %Indent{type: :spaces, size: 256}}
      model = %StatusBar{content_kind: :buffer, data: data}

      assert %{
               command: :gui_status_bar,
               field: :indent_size,
               actual: 256,
               min: 0,
               max: 255
             } =
               assert_raise(EncodingError, fn -> StatusBarEncoder.encode(model, Caches.new()) end)
    end

    test "rejects an out-of-range icon color instead of masking it" do
      file = Map.put(status_data().file, :icon_color, 0x1000000)
      data = %{status_data() | file: file}
      model = %StatusBar{content_kind: :buffer, data: data}

      assert %{
               command: :gui_status_bar,
               field: :file_icon_color,
               actual: 0x1000000,
               min: 0,
               max: 0xFFFFFF
             } =
               assert_raise(EncodingError, fn -> StatusBarEncoder.encode(model, Caches.new()) end)
    end

    test "always returns a command" do
      model = %StatusBar{content_kind: :buffer, data: status_data()}

      {cmd1, caches} = StatusBarEncoder.encode(model, Caches.new())
      {cmd2, _caches} = StatusBarEncoder.encode(model, caches)

      assert cmd1 == cmd2
    end
  end

  @spec operation_payload(Operation.t()) :: binary()
  defp operation_payload(operation) do
    model = %StatusBar{content_kind: :buffer, data: status_data(), operation: operation}
    {command, _caches} = StatusBarEncoder.encode(model, Caches.new())
    command |> decode_sections() |> Map.fetch!(0x0F)
  end

  @spec legacy_status_data() :: map()
  defp legacy_status_data do
    %{
      mode: :normal,
      safe_mode: true,
      cursor_line: 0,
      cursor_col: 1,
      line_count: 10,
      file_name: "README.md",
      filetype: :markdown,
      dirty: true,
      git_branch: "main",
      git_diff_summary: {1, 2, 3},
      diagnostic_counts: {1, 0, 0, 0},
      diagnostic_hint: "warning",
      indent_type: :spaces,
      indent_size: 2,
      selection_info: {:chars, 5},
      lsp_status: :ready,
      parser_status: :available,
      macro_recording: false,
      agent_status: :idle,
      active_tool_name: "grep",
      background_subagent_count: 2,
      active_background_subagent_label: "tests",
      status_msg: "ok",
      modeline_segments: %{
        left: [{:mode, "NORMAL", 0xFFFFFF, 0x000000, [bold: true], nil}],
        right: []
      }
    }
  end

  @spec chrome_state() :: ChromeState.t()
  defp chrome_state do
    %ChromeState{
      workspaces: [
        WorkspaceSummary.new(
          id: 0,
          kind: :manual,
          label: "Files",
          icon: "folder",
          status: :idle,
          attention?: true,
          draft_count: 3,
          conflict_count: 4,
          running_background_count: 5,
          closeable?: false
        )
      ],
      visible_tabs: [],
      mode: :editor,
      active_workspace_id: 0,
      active_tab_id: nil,
      background_count: 5,
      attention_count: 1,
      draft_count: 3,
      conflict_count: 4
    }
  end

  @spec status_data() :: Data.t()
  defp status_data do
    %Data{
      mode: :normal,
      dirty?: true,
      cursor: %Cursor{line: 0, col: 1, line_count: 10},
      diagnostics: %Diagnostics{counts: {1, 0, 0, 0}, hint: "warning"},
      language: %Language{lsp_status: :ready, parser_status: :available},
      git: %Git{branch: "main", diff_summary: {1, 2, 3}},
      file: %File{name: "README.md", filetype: :markdown, icon: "󰍔", icon_color: 0xFFFFFF},
      message: "ok",
      recording: false,
      indent: %Indent{type: :spaces, size: 2},
      selection: %Selection{mode: :chars, size: 5},
      agent: %Agent{agent_status: :idle}
    }
  end

  @spec workspace() :: Workspace.t()
  defp workspace do
    %Workspace{
      id: 0,
      kind: :manual,
      label: "Files",
      icon: "folder",
      attention_count: 1,
      draft_count: 3,
      conflict_count: 4,
      running_background_count: 5,
      attention?: true
    }
  end

  @spec decode_sections(binary()) :: %{non_neg_integer() => binary()}
  defp decode_sections(<<@op_gui_status_bar, count::8, rest::binary>>) do
    {sections, <<>>} = Enum.map_reduce(1..count, rest, fn _index, acc -> decode_section(acc) end)
    Map.new(sections)
  end

  @spec decode_section(binary()) :: {{non_neg_integer(), binary()}, binary()}
  defp decode_section(<<id::8, len::16, payload::binary-size(len), rest::binary>>) do
    {{id, payload}, rest}
  end
end
