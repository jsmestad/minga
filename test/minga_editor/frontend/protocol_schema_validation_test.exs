defmodule MingaEditor.Frontend.ProtocolSchemaValidationTest do
  @moduledoc """
  Validates that the protocol schema field definitions match what the Elixir
  encoders actually produce.

  This is the safety net that catches encoder/schema drift in CI. If someone
  adds a field to an encoder without updating the schema (or vice versa),
  these tests fail.
  """

  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.StatusBarEncoder
  alias Minga.Frontend.Adapter.GUI.WindowEncoder
  alias Minga.RenderModel.Window, as: RenderWindow
  alias Minga.RenderModel.Window.DiagnosticRange
  alias Minga.RenderModel.Window.DocumentHighlight
  alias Minga.RenderModel.Window.Gutter
  alias Minga.RenderModel.Window.GutterEntry
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.SearchMatch
  alias Minga.RenderModel.Window.Span

  @schema_path Path.join([File.cwd!(), "docs", "protocol_schema.toml"])

  # Type primitives to byte sizes, matching the schema header comment.
  @type_sizes %{
    "u8" => 1,
    "u16" => 2,
    "u24" => 3,
    "u32" => 4,
    "u64" => 8,
    "rgb" => 3
  }

  setup_all do
    {:ok, schema} = @schema_path |> File.read!() |> Toml.decode()

    structures =
      schema["structures"]
      |> Enum.map(fn s -> {s["name"], s} end)
      |> Map.new()

    sections =
      schema["sections"]
      |> Enum.group_by(fn s -> s["opcode"] end)

    %{schema: schema, structures: structures, sections: sections}
  end

  # ── Fixed-size structure size validation ──────────────────────────────────

  describe "fixed-size structure sizes" do
    @expected_sizes %{
      "span" => 13,
      "rect" => 8,
      "search_match" => 7,
      "diagnostic_range" => 9,
      "document_highlight" => 9,
      "gutter_entry" => 10
    }

    for {name, expected_size} <- @expected_sizes do
      test "#{name} is #{expected_size} bytes", %{structures: structures} do
        structure = Map.fetch!(structures, unquote(name))
        computed = compute_fixed_size(structure["fields"], structures)

        assert computed == unquote(expected_size),
               "schema #{unquote(name)} computes to #{computed} bytes, expected #{unquote(expected_size)}"
      end
    end
  end

  # ── Span encoding matches schema ─────────────────────────────────────────

  describe "span encoding matches schema" do
    test "encoded span byte size matches schema span size", %{structures: structures} do
      schema_span_size = compute_fixed_size(structures["span"]["fields"], structures)

      # Build a row with exactly one span and extract the span bytes.
      span = %Span{
        start_col: 10,
        end_col: 20,
        fg: 0xFF8800,
        bg: 0x112233,
        attrs: 5,
        font_weight: 2,
        font_id: 1
      }

      row = %Row{
        row_id: 1,
        row_type: :normal,
        buf_line: 0,
        text: "hello",
        spans: [span],
        content_hash: 0
      }

      # Encode a full window to get a valid binary, then extract span bytes.
      # The row wire format is: row_type(1) + row_id(8) + buf_line(4) +
      # content_hash(4) + text_len(4) + text(N) + span_count(2) + spans.
      # For "hello" (5 bytes): 1 + 8 + 4 + 4 + 4 + 5 + 2 = 28 bytes before spans.
      window = minimal_render_window(rows: [row])
      binary = WindowEncoder.encode_window_content(window)

      # Parse the sectioned binary to extract the rows section.
      <<0x80, section_count::8, sections_binary::binary>> = binary
      rows_payload = extract_section_payload(sections_binary, section_count, 0x02)

      # The rows section starts with row_count(u16), then the row data.
      <<1::16, row_binary::binary>> = rows_payload

      # Extract the span from the row binary.
      text = "hello"
      text_len = byte_size(text)
      prefix_size = 1 + 8 + 4 + 4 + 4 + text_len + 2

      <<_row_prefix::binary-size(^prefix_size), span_binary::binary>> = row_binary
      actual_span_size = byte_size(span_binary)

      assert actual_span_size == schema_span_size,
             "encoder produces #{actual_span_size}-byte spans, schema declares #{schema_span_size}-byte spans"
    end

    test "span field values round-trip correctly through encoding" do
      span = %Span{
        start_col: 0x0102,
        end_col: 0x0304,
        fg: 0xAA_BB_CC,
        bg: 0x11_22_33,
        attrs: 0x07,
        font_weight: 3,
        font_id: 2
      }

      row = %Row{
        row_id: 1,
        row_type: :normal,
        buf_line: 0,
        text: "",
        spans: [span],
        content_hash: 0
      }

      window = minimal_render_window(rows: [row])
      binary = WindowEncoder.encode_window_content(window)

      <<0x80, section_count::8, sections_binary::binary>> = binary
      rows_payload = extract_section_payload(sections_binary, section_count, 0x02)

      # row_count(2) + row_type(1) + row_id(8) + buf_line(4) + content_hash(4) + text_len(4) + text(0) + span_count(2)
      prefix_size = 2 + 1 + 8 + 4 + 4 + 4 + 0 + 2

      <<_prefix::binary-size(^prefix_size), span_binary::binary>> = rows_payload

      assert <<0x01, 0x02, 0x03, 0x04, 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33, 0x07, 3, 2>> =
               span_binary
    end
  end

  # ── Gutter entry encoding matches schema ─────────────────────────────────

  describe "gutter_entry encoding matches schema" do
    test "non-annotation gutter entry byte size matches schema", %{structures: structures} do
      schema_size = compute_fixed_size(structures["gutter_entry"]["fields"], structures)

      entry = %GutterEntry{buf_line: 42, display_type: :normal, sign_type: :none}

      gutter = %Gutter{
        window_id: 1,
        content_row: 0,
        content_col: 0,
        content_height: 10,
        is_active: true,
        content_width: 4,
        cursor_line: 1,
        line_number_style: :hybrid,
        line_number_width: 4,
        sign_col_width: 2,
        entries: [entry]
      }

      window = minimal_render_window(gutter: gutter)
      [_content_binary | rest] = WindowEncoder.encode(window)

      # Find the gutter binary in the remaining commands.
      gutter_binary = Enum.find(rest, fn <<opcode, _::binary>> -> opcode == 0x7B end)
      assert gutter_binary != nil, "no gui_gutter (0x7B) command found in encode output"

      # Parse the sectioned gutter binary: opcode(1) + section_count(1) + sections.
      <<0x7B, gutter_section_count::8, gutter_sections::binary>> = gutter_binary

      # Extract the entries section (section ID 0x03).
      entries_payload = extract_section_payload(gutter_sections, gutter_section_count, 0x03)

      # entries_payload starts with count(u16), then entries.
      <<1::16, entry_binary::binary>> = entries_payload
      actual_entry_size = byte_size(entry_binary)

      assert actual_entry_size == schema_size,
             "encoder produces #{actual_entry_size}-byte gutter entries, schema declares #{schema_size}-byte entries"
    end
  end

  # ── Section existence validation ─────────────────────────────────────────

  describe "gui_window_content section IDs" do
    test "all schema-declared sections exist in encoder output", %{sections: sections} do
      schema_section_ids =
        sections["gui_window_content"]
        |> Enum.map(fn s -> {s["id"], s["name"]} end)
        |> Enum.into(%{})

      window = full_render_window()
      binary = WindowEncoder.encode_window_content(window)

      <<0x80, section_count::8, sections_binary::binary>> = binary
      actual_ids = extract_section_ids(sections_binary, section_count)

      for {id, name} <- schema_section_ids do
        assert id in actual_ids,
               "schema declares gui_window_content section 0x#{Integer.to_string(id, 16)} (#{name}) " <>
                 "but encoder did not emit it. Actual IDs: #{inspect(Enum.map(actual_ids, &hex/1))}"
      end
    end
  end

  describe "gui_status_bar section IDs" do
    test "all schema-declared sections exist in encoder output", %{sections: sections} do
      schema_section_ids =
        sections["gui_status_bar"]
        |> Enum.map(fn s -> {s["id"], s["name"]} end)
        |> Enum.into(%{})

      model = full_status_bar_model()
      binary = StatusBarEncoder.encode_command(model)

      <<0x76, section_count::8, sections_binary::binary>> = binary
      actual_ids = extract_section_ids(sections_binary, section_count)

      for {id, name} <- schema_section_ids do
        assert id in actual_ids,
               "schema declares gui_status_bar section 0x#{Integer.to_string(id, 16)} (#{name}) " <>
                 "but encoder did not emit it. Actual IDs: #{inspect(Enum.map(actual_ids, &hex/1))}"
      end
    end
  end

  describe "gui_gutter section IDs" do
    test "all schema-declared sections exist in encoder output", %{sections: sections} do
      schema_section_ids =
        sections["gui_gutter"]
        |> Enum.map(fn s -> {s["id"], s["name"]} end)
        |> Enum.into(%{})

      gutter = %Gutter{
        window_id: 1,
        content_row: 0,
        content_col: 0,
        content_height: 10,
        is_active: true,
        content_width: 4,
        cursor_line: 1,
        line_number_style: :hybrid,
        line_number_width: 4,
        sign_col_width: 2,
        entries: [%GutterEntry{buf_line: 1, display_type: :normal, sign_type: :none}]
      }

      window = minimal_render_window(gutter: gutter)
      commands = WindowEncoder.encode(window)

      gutter_binary = Enum.find(commands, fn <<opcode, _::binary>> -> opcode == 0x7B end)
      assert gutter_binary != nil, "no gui_gutter (0x7B) command found in encode output"

      <<0x7B, section_count::8, sections_binary::binary>> = gutter_binary
      actual_ids = extract_section_ids(sections_binary, section_count)

      for {id, name} <- schema_section_ids do
        assert id in actual_ids,
               "schema declares gui_gutter section 0x#{Integer.to_string(id, 16)} (#{name}) " <>
                 "but encoder did not emit it. Actual IDs: #{inspect(Enum.map(actual_ids, &hex/1))}"
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec compute_fixed_size([map()], map()) :: non_neg_integer()
  defp compute_fixed_size(fields, structures) do
    Enum.reduce(fields, 0, fn field, acc ->
      acc + field_byte_size(field, structures)
    end)
  end

  @spec field_byte_size(map(), map()) :: non_neg_integer()
  defp field_byte_size(%{"type" => "struct", "element" => struct_name}, structures) do
    structure = Map.fetch!(structures, struct_name)
    compute_fixed_size(structure["fields"], structures)
  end

  defp field_byte_size(%{"type" => type}, _structures) do
    Map.fetch!(@type_sizes, type)
  end

  @spec extract_section_payload(binary(), non_neg_integer(), non_neg_integer()) :: binary()
  defp extract_section_payload(binary, section_count, target_id) do
    do_extract_section_payload(binary, section_count, target_id)
  end

  defp do_extract_section_payload(_binary, 0, target_id) do
    raise "section 0x#{Integer.to_string(target_id, 16)} not found"
  end

  defp do_extract_section_payload(
         <<section_id::8, payload_len::16, payload::binary-size(payload_len), rest::binary>>,
         remaining,
         target_id
       ) do
    if section_id == target_id do
      payload
    else
      do_extract_section_payload(rest, remaining - 1, target_id)
    end
  end

  @spec extract_section_ids(binary(), non_neg_integer()) :: [non_neg_integer()]
  defp extract_section_ids(binary, section_count) do
    do_extract_section_ids(binary, section_count, [])
  end

  defp do_extract_section_ids(_binary, 0, acc), do: Enum.reverse(acc)

  defp do_extract_section_ids(
         <<section_id::8, payload_len::16, _payload::binary-size(payload_len), rest::binary>>,
         remaining,
         acc
       ) do
    do_extract_section_ids(rest, remaining - 1, [section_id | acc])
  end

  @spec hex(non_neg_integer()) :: String.t()
  defp hex(n), do: "0x" <> Integer.to_string(n, 16)

  @spec minimal_render_window(keyword()) :: RenderWindow.t()
  defp minimal_render_window(overrides) do
    defaults = %{
      window_id: 1,
      content_kind: :buffer,
      rect: {0, 0, 80, 24},
      rows: [],
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block,
      cursor_visible: true,
      scroll_left: 0,
      selection: nil,
      search_matches: [],
      diagnostic_ranges: [],
      document_highlights: [],
      annotations: [],
      gutter: nil,
      cursorline: nil,
      indent_guides: nil,
      geometry: nil,
      content_epoch: 1,
      full_refresh: true
    }

    struct!(RenderWindow, Map.merge(defaults, Map.new(overrides)))
  end

  @spec full_render_window() :: RenderWindow.t()
  defp full_render_window do
    alias Minga.RenderModel.Window.Annotation
    alias Minga.RenderModel.Window.Cursorline
    alias Minga.RenderModel.Window.HitRegion
    alias Minga.RenderModel.Window.PaneGeometry
    alias Minga.RenderModel.Window.Selection
    alias Minga.RenderModel.Window.Viewport

    span = %Span{
      start_col: 0,
      end_col: 5,
      fg: 0xFFFFFF,
      bg: 0x000000,
      attrs: 0,
      font_weight: 2,
      font_id: 0
    }

    row = %Row{
      row_id: Row.stable_id(:normal, 1),
      row_type: :normal,
      buf_line: 1,
      text: "hello",
      spans: [span],
      content_hash: 12345
    }

    geometry = %PaneGeometry{
      window_id: 1,
      total_rect: {0, 0, 80, 24},
      content_rect: {1, 4, 76, 22},
      text_rect: {1, 4, 76, 22},
      gutter_rect: {1, 0, 4, 22},
      clip_rect: {0, 0, 80, 24},
      viewport: %Viewport{
        top: 0,
        left: 0,
        rows: 22,
        cols: 76,
        total_lines: 100,
        visual_row_offset: 0,
        total_visual_rows: 100
      },
      gutter_metrics: %Minga.RenderModel.Window.GutterMetrics{
        line_number_width: 4,
        sign_col_width: 2
      },
      hit_regions: [%HitRegion{kind: :text, rect: {1, 4, 76, 22}, window_id: 1}]
    }

    minimal_render_window(
      rows: [row],
      selection: %Selection{type: :char, start_row: 0, start_col: 0, end_row: 0, end_col: 5},
      search_matches: [%SearchMatch{row: 0, start_col: 0, end_col: 5, is_current: true}],
      diagnostic_ranges: [
        %DiagnosticRange{start_row: 0, start_col: 0, end_row: 0, end_col: 5, severity: :error}
      ],
      document_highlights: [
        %DocumentHighlight{start_row: 0, start_col: 0, end_row: 0, end_col: 5, kind: :text}
      ],
      annotations: [
        %Annotation{row: 0, kind: :inline_pill, fg: 0xFFFFFF, bg: 0x000000, text: "ann"}
      ],
      geometry: geometry,
      cursorline: %Cursorline{row: 0, bg_rgb: 0x1A1A2E}
    )
  end

  @spec full_status_bar_model() :: Minga.RenderModel.UI.StatusBar.t()
  defp full_status_bar_model do
    alias Minga.RenderModel.UI.StatusBar
    alias Minga.RenderModel.UI.StatusBar.Agent
    alias Minga.RenderModel.UI.StatusBar.Cursor
    alias Minga.RenderModel.UI.StatusBar.Data
    alias Minga.RenderModel.UI.StatusBar.Diagnostics
    alias Minga.RenderModel.UI.StatusBar.File, as: StatusFile
    alias Minga.RenderModel.UI.StatusBar.Git
    alias Minga.RenderModel.UI.StatusBar.Indent
    alias Minga.RenderModel.UI.StatusBar.Language
    alias Minga.RenderModel.UI.StatusBar.Selection
    alias Minga.RenderModel.UI.StatusBar.Workspace

    data = %Data{
      mode: :normal,
      cursor: %Cursor{line: 10, col: 5, line_count: 100},
      diagnostics: %Diagnostics{counts: {1, 2, 0, 0}, hint: "test hint"},
      language: %Language{lsp_status: :ready, parser_status: :available},
      git: %Git{branch: "main", diff_summary: {1, 2, 0}},
      file: %StatusFile{name: "test.ex", filetype: :elixir, icon: "", icon_color: 0xAA00FF},
      message: "test message",
      recording: false,
      dirty?: true,
      safe_mode?: false,
      indent: %Indent{type: :spaces, size: 2},
      modeline_segments: %{
        left: [{:mode, "NORMAL", 0xFFFFFF, 0x000000, [bold: true], nil}],
        right: [{:file, "test.ex", 0xCCCCCC, 0x000000, [], nil}]
      },
      selection: %Selection{mode: :chars, size: 10},
      agent: %Agent{
        agent_status: :idle,
        session_status: :idle,
        model_name: "gpt-4",
        message_count: 0,
        background_count: 0,
        background_label: "",
        active_tool_name: ""
      }
    }

    %StatusBar{
      content_kind: :buffer,
      data: data,
      workspace: %Workspace{
        id: 1,
        kind: :manual,
        status: :idle,
        attention?: false,
        closeable?: true,
        draft_count: 0,
        conflict_count: 0,
        running_background_count: 0,
        attention_count: 0,
        label: "default",
        icon: ""
      }
    }
  end
end
