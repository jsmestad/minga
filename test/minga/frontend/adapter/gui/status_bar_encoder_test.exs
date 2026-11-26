defmodule Minga.Frontend.Adapter.GUI.StatusBarEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Design.Tokens
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
  alias Minga.RenderModel.UI.StatusBar.Review
  alias Minga.RenderModel.UI.StatusBar.Segment
  alias Minga.RenderModel.UI.StatusBar.Workspace

  @op_gui_status_bar Minga.Protocol.Opcodes.gui_status_bar()

  describe "encode/2" do
    test "encodes complete buffer status sections directly from the canonical model" do
      model = %StatusBar{content_kind: :buffer, data: status_data(), workspace: workspace()}

      {cmd, _caches} = StatusBarEncoder.encode(model, Caches.new())
      sections = decode_sections(cmd)

      assert <<0::8, 0::8, 0x07::8>> = sections[0x01]
      assert <<1::32, 2::32, 10::32>> = sections[0x02]
      assert <<1::16, 0::16, 0::16, 0::16, 7::16, "warning">> = sections[0x03]
      assert <<1::8, 0::8>> = sections[0x04]
      assert <<4::8, "main", 1::16, 2::16, 3::16>> = sections[0x05]

      assert <<icon_len::8, icon::binary-size(icon_len), 0xFFFFFF::24, file_len::16,
               file::binary-size(file_len), filetype_len::8, filetype::binary-size(filetype_len)>> =
               sections[0x06]

      assert icon == "󰍔"
      assert file == "README.md"
      assert filetype == "markdown"
      assert sections[0x07] == <<2::16, "ok">>
      assert sections[0x08] == <<0>>
      assert sections[0x0A] == <<0, 2>>
      assert sections[0x0C] == <<1::8, 5::32>>

      assert <<0::8, 2::16, 5::16, "tests", 4::8, "grep">> = sections[0x09]

      assert <<0::16, 0::8, 0::8, flags::16, 3::16, 4::16, 5::16, 1::16, 5::8, "Files", 6::8,
               "folder">> = sections[0x0D]

      assert Bitwise.band(flags, 0x01) == 0x01
    end

    test "encodes format 3 modeline segments exactly, with drop rank, state, compact form, key and label" do
      minga = %Segment{
        id: :minga,
        text: "Minga working 2/3",
        fg: 0xC678DD,
        bg: 0x282C34,
        style: [bold: true],
        target: :toggle_agent_split,
        drop: 5,
        compact: "2/3",
        state: :working,
        key: "SPC a v",
        label: "Minga is working, step 2 of 3"
      }

      data = %{
        status_data()
        | modeline_segments: %{
            left: [
              %Segment{id: :mode, text: "NORMAL", fg: 0xBBC2CF, bg: 0x51AFEF, style: [bold: true]}
            ],
            right: [
              minga,
              %Segment{id: :filetype, text: "Elixir", fg: 1, bg: 2, drop: 2, compact: ""}
            ]
          }
      }

      model = %StatusBar{content_kind: :buffer, data: data}

      {cmd, _caches} = StatusBarEncoder.encode(model, Caches.new())
      entries = decode_section_entries(cmd)
      assert Enum.map(entries, &elem(&1, 0)) == [1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 9]

      <<3::8, 1::16, 2::16, segments::binary>> = entries |> Map.new() |> Map.fetch!(0x0B)
      {mode, rest} = take_modeline_segment(segments)
      {minga, rest} = take_modeline_segment(rest)
      {filetype, ""} = take_modeline_segment(rest)

      assert mode == %{
               name: "mode",
               fg: 0xBBC2CF,
               bg: 0x51AFEF,
               attrs: 0x01,
               text: "NORMAL",
               target: "",
               drop: 0,
               flags: 0,
               state: 0,
               compact: "",
               key: "",
               label: ""
             }

      assert minga == %{
               name: "minga",
               fg: 0xC678DD,
               bg: 0x282C34,
               attrs: 0x01,
               text: "Minga working 2/3",
               target: "toggle_agent_split",
               drop: 5,
               flags: 0x01,
               state: Tokens.state_wire(:working),
               compact: "2/3",
               key: "SPC a v",
               label: "Minga is working, step 2 of 3"
             }

      # An empty compact form still collapses (to the mark alone); nil means the segment drops.
      assert {filetype.flags, filetype.compact} == {0x01, ""}
    end

    test "encodes the notice's next steps (0x13) only while it names some" do
      action = %Minga.RenderModel.UI.EmptyList.Action{
        id: "inline_ask",
        key: "SPC a ?",
        label: "ask Minga"
      }

      data = %{status_data() | message: "No code actions here", message_actions: [action]}
      model = %StatusBar{content_kind: :buffer, data: data, workspace: workspace()}

      {cmd, _caches} = StatusBarEncoder.encode(model, Caches.new())
      sections = decode_sections(cmd)

      assert sections[0x13] ==
               <<1::8, 10::8, "inline_ask", 7::16, "SPC a ?", 9::16, "ask Minga">>

      {plain, _caches} =
        StatusBarEncoder.encode(%{model | data: %{data | message_actions: []}}, Caches.new())

      refute Map.has_key?(decode_sections(plain), 0x13)
    end

    test "encodes the needs-you count (0x14) only while a task needs you" do
      model = %StatusBar{
        content_kind: :buffer,
        data: %{status_data() | needs_you_count: 2},
        workspace: workspace()
      }

      {cmd, _caches} = StatusBarEncoder.encode(model, Caches.new())
      assert decode_sections(cmd)[0x14] == <<2::16>>

      {none, _caches} = StatusBarEncoder.encode(%{model | data: status_data()}, Caches.new())
      refute Map.has_key?(decode_sections(none), 0x14)
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

    test "omits operation section (0x0F) when operation is nil" do
      model = %StatusBar{content_kind: :buffer, data: status_data(), operation: nil}

      {cmd, _caches} = StatusBarEncoder.encode(model, Caches.new())
      sections = decode_sections(cmd)

      refute Map.has_key?(sections, 0x0F)
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

    test "keeps message section independent from structured operation feedback" do
      operation = %Operation{
        id: 9,
        kind: :external_format,
        status: :running,
        message: "Formatting",
        cancelable?: false
      }

      model = %StatusBar{content_kind: :buffer, data: status_data(), operation: operation}
      {cmd, _caches} = StatusBarEncoder.encode(model, Caches.new())
      sections = decode_sections(cmd)

      assert sections[0x07] == <<2::16, "ok">>

      assert <<9::64, 1::8, 3::8, 0::8, 10::16, "Formatting", 0::16, 0::16, 0::32, 0::32>> =
               sections[0x0F]
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

    test "encodes complete agent status section" do
      data = %{
        status_data()
        | agent: %Agent{
            model_name: "Agent",
            session_status: :thinking,
            message_count: 4,
            agent_status: :thinking,
            background_count: 2,
            background_label: "session-3: tests",
            active_tool_name: "shell"
          }
      }

      model = %StatusBar{content_kind: :agent, data: data, workspace: workspace()}

      {cmd, _caches} = StatusBarEncoder.encode(model, Caches.new())
      sections = decode_sections(cmd)

      assert <<5::8, "Agent", 4::32, 1::8, 1::8, 2::16, 16::16, "session-3: tests", 5::8,
               "shell">> = sections[0x09]
    end

    test "encodes nil active tool names as zero-length strings in buffer and agent variants" do
      buffer_data = %{status_data() | agent: %{status_data().agent | active_tool_name: nil}}
      agent_data = %{buffer_data | agent: %{buffer_data.agent | session_status: :thinking}}

      buffer_model = %StatusBar{content_kind: :buffer, data: buffer_data}
      agent_model = %StatusBar{content_kind: :agent, data: agent_data}

      {buffer_cmd, _caches} = StatusBarEncoder.encode(buffer_model, Caches.new())
      {agent_cmd, _caches} = StatusBarEncoder.encode(agent_model, Caches.new())

      assert <<0::8, 2::16, 5::16, "tests", 0::8>> =
               buffer_cmd |> decode_sections() |> Map.fetch!(0x09)

      assert <<model_len::8, _model::binary-size(model_len), 0::32, 1::8, 0::8, 2::16, 5::16,
               "tests", 0::8>> = agent_cmd |> decode_sections() |> Map.fetch!(0x09)
    end

    test "safe mode sets identity flag bit 3" do
      data = %{status_data() | safe_mode?: true}
      model = %StatusBar{content_kind: :buffer, data: data}

      {cmd, _caches} = StatusBarEncoder.encode(model, Caches.new())
      <<_content_kind::8, _mode::8, flags::8>> = cmd |> decode_sections() |> Map.fetch!(0x01)

      assert Bitwise.band(flags, 0x08) == 0x08
    end

    test "nil modeline data is omitted and explicit empty data emits an empty format 3 section" do
      nil_model = %StatusBar{content_kind: :buffer, data: status_data()}
      empty_data = %{status_data() | modeline_segments: %{left: [], right: []}}
      empty_model = %StatusBar{content_kind: :buffer, data: empty_data}

      {nil_cmd, _caches} = StatusBarEncoder.encode(nil_model, Caches.new())
      {empty_cmd, _caches} = StatusBarEncoder.encode(empty_model, Caches.new())

      refute nil_cmd |> decode_sections() |> Map.has_key?(0x0B)
      assert <<3, 0::16, 0::16>> = empty_cmd |> decode_sections() |> Map.fetch!(0x0B)
    end

    test "encodes every wire-valid modeline segment instead of taking only 128" do
      segment = %Segment{id: :mode, text: "N", fg: 0xFFFFFF, bg: 0x000000}

      data = %{
        status_data()
        | modeline_segments: %{left: List.duplicate(segment, 129), right: []}
      }

      model = %StatusBar{content_kind: :buffer, data: data}

      {cmd, _caches} = StatusBarEncoder.encode(model, Caches.new())
      sections = decode_sections(cmd)

      assert <<3::8, 129::16, 0::16, _segments::binary>> = sections[0x0B]
    end

    test "rejects oversized modeline strings and sections instead of truncating or dropping entries" do
      oversized_text =
        %{
          status_data()
          | modeline_segments: %{
              left: [
                %Segment{
                  id: :custom,
                  text: String.duplicate("x", 65_536),
                  fg: 0xBBC2CF,
                  bg: 0x51AFEF
                }
              ],
              right: []
            }
        }

      assert %{
               command: :gui_status_bar,
               field: :modeline_segment_text,
               actual: 65_536,
               min: 0,
               max: 65_535
             } =
               assert_raise(EncodingError, fn ->
                 StatusBarEncoder.encode(
                   %StatusBar{content_kind: :buffer, data: oversized_text},
                   Caches.new()
                 )
               end)

      segment = %Segment{id: :custom, text: "x", fg: 0xBBC2CF, bg: 0x51AFEF}

      oversized_section = %{
        status_data()
        | modeline_segments: %{left: List.duplicate(segment, 4_000), right: []}
      }

      assert %{
               command: :gui_status_bar,
               field: :section_payload,
               actual: 108_005,
               min: 0,
               max: 65_535
             } =
               assert_raise(EncodingError, fn ->
                 StatusBarEncoder.encode(
                   %StatusBar{content_kind: :buffer, data: oversized_section},
                   Caches.new()
                 )
               end)
    end

    test "validates segment fields before checking the combined modeline section length" do
      segment = %Segment{
        id: :custom,
        text: String.duplicate("x", 65_535),
        fg: 0xBBC2CF,
        bg: 0x51AFEF
      }

      invalid = %Segment{id: :custom, text: "x", fg: 0x1000000, bg: 0x51AFEF}

      data = %{
        status_data()
        | modeline_segments: %{left: [segment], right: [invalid]}
      }

      model = %StatusBar{content_kind: :buffer, data: data}

      assert %{
               command: :gui_status_bar,
               field: :modeline_segment_fg,
               actual: 0x1000000,
               min: 0,
               max: 0xFFFFFF
             } =
               assert_raise(EncodingError, fn -> StatusBarEncoder.encode(model, Caches.new()) end)
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

    test "Review carries complete Unicode source offers and disappears when no longer selected" do
      path = "lib/é/界.ex"
      item_id = "r1.opaque-source"

      model = %StatusBar{
        content_kind: :buffer,
        data: status_data(),
        review: %Review{path: path, freshness: :stale, generation: 42, item_id: item_id}
      }

      {command, caches} = StatusBarEncoder.encode(model, Caches.new())

      assert decode_sections(command)[0x10] ==
               <<byte_size(path)::16, path::binary, 1, 42::32, byte_size(item_id)::16,
                 item_id::binary>>

      {ordinary, _caches} = StatusBarEncoder.encode(%{model | review: nil}, caches)
      refute Map.has_key?(decode_sections(ordinary), 0x10)
    end

    test "a fork conflict carries the key hints for its two decisions after the conflict index" do
      model = %StatusBar{
        content_kind: :agent,
        data: status_data(),
        review: %Review{
          path: "note.txt",
          freshness: :current,
          generation: 7,
          item_id: "r1.conflict",
          conflict_index: 2,
          keep_mine_key: "Ctrl+Backspace",
          use_agent_key: "Ctrl+Enter"
        }
      }

      {command, _caches} = StatusBarEncoder.encode(model, Caches.new())
      sections = decode_sections(command)

      assert sections[0x11] == <<2::32>>
      assert sections[0x12] == <<14::16, "Ctrl+Backspace", 10::16, "Ctrl+Enter">>

      {read_only, _caches} =
        StatusBarEncoder.encode(
          %{model | review: %{model.review | conflict_index: nil}},
          Caches.new()
        )

      refute Map.has_key?(decode_sections(read_only), 0x12)
    end
  end

  @spec operation_payload(Operation.t()) :: binary()
  defp operation_payload(operation) do
    model = %StatusBar{content_kind: :buffer, data: status_data(), operation: operation}
    {command, _caches} = StatusBarEncoder.encode(model, Caches.new())
    command |> decode_sections() |> Map.fetch!(0x0F)
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
      agent: %Agent{
        agent_status: :idle,
        background_count: 2,
        background_label: "tests",
        active_tool_name: "grep"
      }
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

  @spec take_modeline_segment(binary()) :: {map(), binary()}
  defp take_modeline_segment(
         <<name_len::8, name::binary-size(name_len), fg::24, bg::24, attrs::8, text_len::16,
           text::binary-size(text_len), target_len::16, target::binary-size(target_len), drop::8,
           flags::8, state::8, compact_len::16, compact::binary-size(compact_len), key_len::8,
           key::binary-size(key_len), label_len::16, label::binary-size(label_len), rest::binary>>
       ) do
    {%{
       name: name,
       fg: fg,
       bg: bg,
       attrs: attrs,
       text: text,
       target: target,
       drop: drop,
       flags: flags,
       state: state,
       compact: compact,
       key: key,
       label: label
     }, rest}
  end

  @spec decode_sections(binary()) :: %{non_neg_integer() => binary()}
  defp decode_sections(command), do: command |> decode_section_entries() |> Map.new()

  @spec decode_section_entries(binary()) :: [{non_neg_integer(), binary()}]
  defp decode_section_entries(<<@op_gui_status_bar, count::8, rest::binary>>) do
    {sections, <<>>} = Enum.map_reduce(1..count, rest, fn _index, acc -> decode_section(acc) end)
    sections
  end

  @spec decode_section(binary()) :: {{non_neg_integer(), binary()}, binary()}
  defp decode_section(<<id::8, len::16, payload::binary-size(len), rest::binary>>) do
    {{id, payload}, rest}
  end
end
