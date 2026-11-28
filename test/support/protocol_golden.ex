defmodule Minga.Test.ProtocolGolden do
  @moduledoc """
  Cross-language golden fixtures for the generated protocol decoders.

  Each fixture encodes a piece of fixture editor state with the production GUI
  adapter encoders (the same code path the BEAM uses to talk to frontends),
  strips the on-wire framing down to the payload unit a generated decoder
  consumes, and records the field values the decoder must produce.

  The companion Go test `go/tui/internal/protocol/golden_cross_lang_test.go`
  decodes each payload with the schema-generated Go decoder and compares the
  result field-by-field against the expected values here. Because both the
  payload bytes and the expected values come from the same Elixir model, any
  drift between the hand-written encoders and the generated decoders fails CI:
  exactly the structural guarantee ticket #2225 is after.

  The expected map for a fixture is keyed by schema field names. `manifest/0`
  normalizes those into the Go struct's PascalCase field names using the
  generated `Minga.Protocol.GoldenFields` metadata, so the manifest the Go test
  reads speaks the same field names the generated structs marshal to.

  Boundary coverage per family: empty payloads, typical payloads, and boundary
  payloads (max-length strings, unicode, zero-item and populated lists).
  """

  alias Minga.Frontend.Adapter.GUI.ActMenuEncoder
  alias Minga.Frontend.Adapter.GUI.AgentQueueEncoder
  alias Minga.Frontend.Adapter.GUI.BreadcrumbEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.CompletionEncoder
  alias Minga.Frontend.Adapter.GUI.FocusOwnerEncoder
  alias Minga.Frontend.Adapter.GUI.GitStatusEncoder
  alias Minga.Frontend.Adapter.GUI.PickerEncoder
  alias Minga.Frontend.Adapter.GUI.SearchStateEncoder
  alias Minga.Protocol.Encode
  alias Minga.Protocol.GoldenFields
  alias Minga.RenderModel.UI.ActMenu
  alias Minga.RenderModel.UI.ActMenu.Row, as: ActMenuRow
  alias Minga.RenderModel.UI.Breadcrumb
  alias Minga.RenderModel.UI.Completion
  alias Minga.RenderModel.UI.FocusOwner
  alias Minga.RenderModel.UI.GitStatus
  alias Minga.RenderModel.UI.EmptyList
  alias Minga.RenderModel.UI.EmptyList.Action
  alias Minga.RenderModel.UI.Queue
  alias Minga.RenderModel.UI.Picker
  alias Minga.RenderModel.UI.SearchState
  alias MingaEditor.RenderModel.UI.GitStatusBuilder

  @typedoc """
  One golden fixture: a human name, the generated decoder unit name (matches a
  `case` in the generated `GoldenDecode`), the payload bytes a frontend decodes,
  and the expected decoded fields keyed by schema field name.
  """
  @type fixture :: %{
          name: String.t(),
          decoder: String.t(),
          payload: binary(),
          expected: map() | [map()]
        }

  @doc """
  All golden fixtures across the covered opcode families.
  """
  @spec fixtures() :: [fixture()]
  def fixtures do
    completion_fixtures() ++
      picker_header_fixtures() ++
      picker_item_fixtures() ++
      act_menu_fixtures() ++
      picker_load_status_fixtures() ++
      picker_movement_key_fixtures() ++
      picker_query_fixtures() ++
      breadcrumb_fixtures() ++
      git_status_fixtures() ++
      search_state_fixtures() ++
      focus_owner_fixtures() ++
      queue_fixtures() ++
      surface_layout_fixtures() ++
      theme_fixtures()
  end

  @doc """
  Build the manifest the Go golden test consumes: a list of maps with the
  decoder name, base64-encoded payload, and expected fields normalized to the
  generated Go struct's PascalCase field names.
  """
  @spec manifest() :: [map()]
  def manifest do
    Enum.map(fixtures(), fn fixture ->
      %{
        "name" => fixture.name,
        "decoder" => fixture.decoder,
        "payload" => Base.encode64(fixture.payload),
        "expected" => normalize_expected(fixture.decoder, fixture.expected)
      }
    end)
  end

  # ── Expected-value normalization (schema names -> Go PascalCase) ──────────

  @spec normalize_expected(String.t(), map() | [map()]) :: map() | [map()]
  defp normalize_expected(decoder, expected) when is_list(expected) do
    # Counted-array sections decode to a bare slice; the unit metadata holds a
    # single {array} field describing the element. Normalize each element.
    [{_schema, _go, {:array, element_shape}}] = GoldenFields.fields(decoder)
    Enum.map(expected, &normalize_value(element_shape, &1))
  end

  defp normalize_expected(decoder, expected) when is_map(expected) do
    decoder
    |> GoldenFields.fields()
    |> normalize_fields(expected)
  end

  @spec normalize_fields([tuple()], map()) :: map()
  defp normalize_fields(fields, source) do
    Enum.reduce(fields, %{}, fn {schema_name, go_name, shape}, acc ->
      value = Map.fetch!(source, String.to_atom(schema_name))
      Map.put(acc, go_name, normalize_value(shape, value))
    end)
  end

  @spec normalize_value(term(), term()) :: term()
  defp normalize_value(:scalar, value), do: value
  defp normalize_value(:string, value), do: value

  defp normalize_value({:struct, fields}, value) when is_map(value),
    do: normalize_fields(fields, value)

  defp normalize_value({:array, element_shape}, values) when is_list(values),
    do: Enum.map(values, &normalize_value(element_shape, &1))

  # ── Payload extraction helpers ───────────────────────────────────────────

  # gui_completion is a custom-framed command: opcode(1) then the
  # GuiCompletionFields payload. Strip the opcode byte.
  @spec completion_payload(Completion.t()) :: binary()
  defp completion_payload(model) do
    <<_op::8, payload::binary>> = CompletionEncoder.encode_command(model)
    payload
  end

  # A sectioned opcode wraps each section as id(1) + len(u16) + body. Pull the
  # body of the section with the given id out of the full encoded command.
  @spec section_body(binary(), non_neg_integer()) :: binary()
  defp section_body(<<_op::8, count::8, sections::binary>>, target_id) do
    find_section(sections, count, target_id)
  end

  @spec find_section(binary(), non_neg_integer(), non_neg_integer()) :: binary()
  defp find_section(_data, 0, target_id),
    do: raise("section #{target_id} not found in encoded command")

  defp find_section(
         <<id::8, len::16, body::binary-size(len), rest::binary>>,
         remaining,
         target_id
       ) do
    if id == target_id do
      body
    else
      find_section(rest, remaining - 1, target_id)
    end
  end

  @spec picker_command(Picker.t()) :: binary()
  defp picker_command(model), do: PickerEncoder.encode_command(model)

  @spec focus_owner_fixtures() :: [fixture()]
  defp focus_owner_fixtures do
    for {name, surface, responder, surface_byte, responder_byte} <- [
          {"picker", :picker, :picker_query, 8, 1},
          {"hover", :hover_popup, :editor_view, 12, 0},
          {"empty_state", :empty_state, :editor_view, 13, 0},
          {"queue", :queue, :editor_view, 15, 0}
        ] do
      owner = %FocusOwner{
        responder: responder,
        surface: surface,
        window_id: 70_000,
        generation: 4_294_967_295
      }

      {<<0xAA, 10::16, payload::binary-size(10)>>, _caches} =
        FocusOwnerEncoder.encode(owner, Caches.new())

      %{
        name: "focus_owner_#{name}",
        decoder: "GuiFocusOwnerFields",
        payload: payload,
        expected: %{
          responder: responder_byte,
          surface: surface_byte,
          window_id: 70_000,
          generation: 4_294_967_295
        }
      }
    end
  end

  @spec queue_fixtures() :: [fixture()]
  defp queue_fixtures do
    blank = %{glyph: "", title: "", why: "", selected: 0, actions: []}

    hidden = %{
      visible: 0,
      focused: 0,
      workspace_id: 0,
      record_id: "",
      title: "",
      summary: "",
      removed_note: "",
      selected_id: 0,
      hints: [],
      pending: [],
      removed: [],
      empty: blank
    }

    scope = %Queue{
      visible?: true,
      focused?: true,
      workspace_id: 70_000,
      record_id: "conversation",
      title: "*minga-queue*"
    }

    shown = %{
      hidden
      | visible: 1,
        focused: 1,
        workspace_id: 70_000,
        record_id: "conversation",
        title: "*minga-queue*"
    }

    row = %{
      id: 0x1_0000_0000,
      revision: 3,
      kind: :follow_up,
      label: "1",
      preview: "Review café λ",
      attachment_count: 12
    }

    removed = %{row | id: 7, kind: :steering, preview: "Removed message"}
    next = %Action{id: "queue_return_to_composer", key: "↩", label: "Back to the composer"}

    empty = %EmptyList{
      glyph: "",
      title: "Nothing queued.",
      why: "Queued messages wait here.",
      actions: [next],
      selected: 0
    }

    close = {"q", "close", :close}
    hints = [%{key: "q", label: "close", action: 5}]

    for {name, queue, expected} <- [
          {"hidden", %Queue{}, hidden},
          {"empty", %{scope | summary: "Queue", hints: [close], empty: empty},
           %{
             shown
             | summary: "Queue",
               hints: hints,
               empty: %{
                 blank
                 | title: empty.title,
                   why: empty.why,
                   actions: [Map.from_struct(next)]
               }
           }},
          {"messages",
           %{
             scope
             | summary: "1 queued",
               removed_note: "Not sent.",
               selected_id: row.id,
               pending: [row],
               removed: [removed]
           },
           %{
             shown
             | summary: "1 queued",
               removed_note: "Not sent.",
               selected_id: row.id,
               pending: [%{row | kind: 1}],
               removed: [%{removed | kind: 0}]
           }}
        ] do
      <<0xAE, length::32, payload::binary-size(length)>> = AgentQueueEncoder.encode_command(queue)

      %{
        name: "agent_queue_#{name}",
        decoder: "GuiAgentQueueFields",
        payload: payload,
        expected: expected
      }
    end
  end

  # ── Fixtures: gui_completion (GuiCompletionFields) ───────────────────────

  @spec completion_fixtures() :: [fixture()]
  defp completion_fixtures do
    hidden = %Completion{visible?: false}

    typical = %Completion{
      visible?: true,
      generation: 7,
      cursor_row: 3,
      cursor_col: 7,
      selected_offset: 1,
      selected_item_id: "baz-id",
      items: [
        %Completion.Item{
          id: "foo-id",
          source: "alpha",
          kind: :function,
          label: "foo",
          detail: "bar",
          match_ranges: [%{start: 0, length: 2}]
        },
        %Completion.Item{id: "baz-id", source: "beta", kind: :module, label: "Baz", detail: ""}
      ],
      documentation: "Calls foo/1.\n\nReturns the result.",
      total_count: 12,
      matched_count: 4,
      incomplete?: true
    }

    unicode = %Completion{
      visible?: true,
      generation: 8,
      cursor_row: 0,
      cursor_col: 0,
      selected_offset: 0,
      items: [%Completion.Item{kind: :variable, label: "café→λ", detail: "ünïcödé"}],
      documentation: "Café λ docs → ✓"
    }

    empty_items = %Completion{
      visible?: true,
      generation: 9,
      cursor_row: 1,
      cursor_col: 2,
      items: []
    }

    [
      %{
        name: "completion_hidden",
        decoder: "GuiCompletionFields",
        payload: completion_payload(hidden),
        expected: %{
          visible: 0,
          cursor_row: 0,
          cursor_col: 0,
          selected_offset: 0,
          items: [],
          documentation: "",
          selected_item_id: "",
          total_count: 0,
          matched_count: 0,
          incomplete: 0,
          generation: 0
        }
      },
      %{
        name: "completion_typical",
        decoder: "GuiCompletionFields",
        payload: completion_payload(typical),
        expected: %{
          visible: 1,
          cursor_row: 3,
          cursor_col: 7,
          selected_offset: 1,
          items: [
            %{
              kind: 1,
              label: "foo",
              detail: "bar",
              id: "foo-id",
              source: "alpha",
              match_ranges: [%{start: 0, length: 2}]
            },
            %{kind: 5, label: "Baz", detail: "", id: "baz-id", source: "beta", match_ranges: []}
          ],
          documentation: "Calls foo/1.\n\nReturns the result.",
          selected_item_id: "baz-id",
          total_count: 12,
          matched_count: 4,
          incomplete: 1,
          generation: 7
        }
      },
      %{
        name: "completion_unicode",
        decoder: "GuiCompletionFields",
        payload: completion_payload(unicode),
        expected: %{
          visible: 1,
          cursor_row: 0,
          cursor_col: 0,
          selected_offset: 0,
          items: [
            %{kind: 3, label: "café→λ", detail: "ünïcödé", id: "", source: "", match_ranges: []}
          ],
          documentation: "Café λ docs → ✓",
          selected_item_id: "",
          total_count: 0,
          matched_count: 0,
          incomplete: 0,
          generation: 8
        }
      },
      %{
        name: "completion_empty_items",
        decoder: "GuiCompletionFields",
        payload: completion_payload(empty_items),
        expected: %{
          visible: 1,
          cursor_row: 1,
          cursor_col: 2,
          selected_offset: 0,
          items: [],
          documentation: "",
          selected_item_id: "",
          total_count: 0,
          matched_count: 0,
          incomplete: 0,
          generation: 9
        }
      }
    ]
  end

  # ── Fixtures: gui_picker header (GuiPickerHeader) ─────────────────────────

  @spec picker_model([Picker.item()]) :: Picker.t()
  defp picker_model(items) do
    %Picker{
      visible?: true,
      title: "Files",
      query: "rc",
      selected_index: 2,
      filtered_count: 10,
      total_count: 100,
      marked_count: 3,
      has_preview?: true,
      items: items,
      mode_prefix: "",
      load_status: :ready
    }
  end

  @spec picker_header_fixtures() :: [fixture()]
  defp picker_header_fixtures do
    model = picker_model([])

    [
      %{
        name: "picker_header_typical",
        decoder: "GuiPickerHeader",
        payload: section_body(picker_command(model), 0x01),
        expected: %{
          visible: 1,
          selected_index: 2,
          filtered_count: 10,
          total_count: 100,
          has_preview: 1,
          title: "Files",
          marked_count: 3,
          activation_generation: 0
        }
      },
      %{
        name: "picker_header_empty_title",
        decoder: "GuiPickerHeader",
        payload: section_body(picker_command(%{model | title: "", has_preview?: false}), 0x01),
        expected: %{
          visible: 1,
          selected_index: 2,
          filtered_count: 10,
          total_count: 100,
          has_preview: 0,
          title: "",
          marked_count: 3,
          activation_generation: 0
        }
      },
      # Short-section tolerance fixtures (ticket #2225). The Elixir encoder always
      # emits the full header tail, so these payloads are hand-crafted to model a
      # peer that emits a shorter header (an older or newer frontend). They prove
      # the generated decoder reads the `optional` title/marked_count tail only
      # when the section window has room, degrading absent fields to their zero
      # value, exactly as the hand-written frontend decoders do.
      %{
        name: "picker_header_short_no_marked_count",
        decoder: "GuiPickerHeader",
        # visible(1) selected(2) filtered(2) total(2) has_preview(1) title("Files")
        # but no marked_count tail.
        payload: <<1, 0, 2, 0, 10, 0, 100, 1, 0, 5, "Files">>,
        expected: %{
          visible: 1,
          selected_index: 2,
          filtered_count: 10,
          total_count: 100,
          has_preview: 1,
          title: "Files",
          marked_count: 0,
          activation_generation: 0
        }
      },
      %{
        name: "picker_header_short_no_title",
        decoder: "GuiPickerHeader",
        # Header truncated right after has_preview: both title and marked_count
        # are absent and decode to their zero value.
        payload: <<1, 0, 2, 0, 10, 0, 100, 1>>,
        expected: %{
          visible: 1,
          selected_index: 2,
          filtered_count: 10,
          total_count: 100,
          has_preview: 1,
          title: "",
          marked_count: 0,
          activation_generation: 0
        }
      }
    ]
  end

  @spec picker_query_fixtures() :: [fixture()]
  defp picker_query_fixtures do
    [
      %{
        name: "picker_query_unicode",
        decoder: "GuiPickerQuery",
        payload:
          section_body(
            picker_command(%{
              picker_model([])
              | query: "λ-query",
                query_generation: 7,
                acknowledged_query_edit_seq: 11
            }),
            0x02
          ),
        expected: %{text: "λ-query", generation: 7, acknowledged_edit_seq: 11}
      },
      %{
        name: "picker_query_empty",
        decoder: "GuiPickerQuery",
        payload: section_body(picker_command(%{picker_model([]) | query: ""}), 0x02),
        expected: %{text: "", generation: 0, acknowledged_edit_seq: 0}
      }
    ]
  end

  # ── Fixtures: gui_picker items (PickerItem) ───────────────────────────────

  @spec picker_item_fixtures() :: [fixture()]
  defp picker_item_fixtures do
    # Items are the wire-shaped maps the Layer 2 builder produces (flags packed,
    # nil-vs-empty defaulted, match_positions clamped). The shell passes these
    # straight to the generated encode_picker_item/1.
    items = [
      %{
        icon_color: 0x00AABBCC,
        flags: 0,
        label: "file.ex",
        description: "desc",
        annotation: "ann",
        match_positions: [1, 4],
        activation_id: 23,
        status: "",
        status_tone: :none,
        group: ""
      },
      %{
        # marked sets bit 1, active sets bit 3 => 0b1010 = 10; a warn status chip and a group
        icon_color: 0,
        flags: 10,
        label: "x",
        description: "",
        annotation: "★ favorite",
        match_positions: [],
        activation_id: 0,
        status: "Ready · 82%",
        status_tone: :warn,
        group: "ChatGPT"
      }
    ]

    # Boundary fixture at the wire maximum: a full 255-entry match_positions
    # list (the value the builder produces at and above its clamp). This proves
    # the generated encode_picker_item/1 lays out a max-count u8 list correctly.
    # The 256 -> 255 clamp itself is a builder-layer concern, covered by
    # MingaEditor.RenderModel.UI.PickerBuilderTest.
    boundary_max = %{
      icon_color: 0,
      flags: 0,
      label: "bmax",
      description: "",
      annotation: "",
      match_positions: Enum.to_list(0..254),
      activation_id: 0xFFFF_FFFF,
      status: "",
      status_tone: :none,
      group: ""
    }

    payload = section_body(picker_command(picker_model(items)), 0x03)

    [
      %{
        name: "picker_items_list",
        decoder: "GuiPickerItems",
        payload: payload,
        expected: Enum.map(items, &picker_item_expected/1)
      },
      %{
        name: "picker_items_empty",
        decoder: "GuiPickerItems",
        payload: section_body(picker_command(picker_model([])), 0x03),
        expected: []
      },
      %{
        name: "picker_items_match_positions_max",
        decoder: "GuiPickerItems",
        payload: section_body(picker_command(picker_model([boundary_max])), 0x03),
        expected: [picker_item_expected(boundary_max)]
      }
    ]
  end

  # Decoders surface the status tone as its wire byte (none 0, ready 1, warn 2, error 3, checking 4,
  # neutral 5), so the expectation carries the byte rather than the encoder's atom.
  @spec picker_item_expected(map()) :: map()
  defp picker_item_expected(item) do
    tone =
      Map.fetch!(
        %{none: 0, ready: 1, warn: 2, error: 3, checking: 4, neutral: 5},
        item.status_tone
      )

    %{item | status_tone: tone}
  end

  @spec act_menu_fixtures() :: [fixture()]
  defp act_menu_fixtures do
    keep = %ActMenuRow{
      id: 1,
      label: "Keep",
      key: "y",
      hint: "y",
      detail: "Review the whole change",
      section: "This change",
      destructive?: false
    }

    reject = %ActMenuRow{
      id: 2,
      label: "Reject",
      key: "n",
      hint: "n",
      detail: "Revert the change",
      section: "This change",
      destructive?: true
    }

    menu = %ActMenu{
      id: 4_294_967_301,
      title: "Minga's change",
      role: :minga,
      anchor: {4, 17},
      selected: keep.id,
      lead: [keep, reject],
      rows: [],
      query: ""
    }

    {<<0xB1, _shown_size::32, shown::binary>>, caches} = ActMenuEncoder.encode(menu, Caches.new())
    {<<0xB1, _hidden_size::32, hidden::binary>>, _caches} = ActMenuEncoder.encode(:hidden, caches)

    [
      %{
        name: "act_menu_review_decision",
        decoder: "GuiActMenuFields",
        payload: shown,
        expected: %{
          visible: 1,
          offer_id: menu.id,
          role: 1,
          anchor_row: 4,
          anchor_column: 17,
          selected: keep.id,
          title: menu.title,
          query: "",
          rows: [],
          lead: [
            %{
              id: 1,
              key: "y",
              label: "Keep",
              hint: "y",
              detail: keep.detail,
              section: keep.section,
              destructive: 0
            },
            %{
              id: 2,
              key: "n",
              label: "Reject",
              hint: "n",
              detail: reject.detail,
              section: reject.section,
              destructive: 1
            }
          ]
        }
      },
      %{
        name: "act_menu_hidden",
        decoder: "GuiActMenuFields",
        payload: hidden,
        expected: %{
          visible: 0,
          offer_id: 0,
          role: 0,
          anchor_row: 0,
          anchor_column: 0,
          selected: 0,
          title: "",
          query: "",
          lead: [],
          rows: []
        }
      }
    ]
  end

  # ── Fixtures: gui_picker load status (GuiPickerLoadStatus) ────────────────

  @spec picker_load_status_fixtures() :: [fixture()]
  defp picker_load_status_fixtures do
    [
      %{
        name: "load_status_ready",
        decoder: "GuiPickerLoadStatus",
        payload: section_body(picker_command(%{picker_model([]) | load_status: :ready}), 0x06),
        expected: %{status: 0, message: ""}
      },
      %{
        name: "load_status_loading",
        decoder: "GuiPickerLoadStatus",
        payload: section_body(picker_command(%{picker_model([]) | load_status: :loading}), 0x06),
        expected: %{status: 1, message: ""}
      },
      %{
        name: "load_status_error",
        decoder: "GuiPickerLoadStatus",
        payload:
          section_body(
            picker_command(%{picker_model([]) | load_status: {:error, "boom"}}),
            0x06
          ),
        expected: %{status: 2, message: "boom"}
      }
    ]
  end

  # ── Fixtures: gui_picker movement keys (GuiPickerMovementKeys) ────────────

  # Decoders surface the movement as its wire byte (next 1, previous 2), so the expectation carries the byte.
  @spec picker_movement_key_fixtures() :: [fixture()]
  defp picker_movement_key_fixtures do
    keys = [
      %{codepoint: ?j, modifiers: 0x02, movement: :next},
      %{codepoint: 57_353, modifiers: 0, movement: :next},
      %{codepoint: ?k, modifiers: 0x02, movement: :previous},
      %{codepoint: 0xF700, modifiers: 0, movement: :previous}
    ]

    expected =
      Enum.map(keys, fn key ->
        %{key | movement: Map.fetch!(%{next: 1, previous: 2}, key.movement)}
      end)

    [
      %{
        name: "picker_movement_keys_list",
        decoder: "GuiPickerMovementKeys",
        payload: section_body(picker_command(%{picker_model([]) | movement_keys: keys}), 0x08),
        expected: expected
      },
      %{
        name: "picker_movement_keys_empty",
        decoder: "GuiPickerMovementKeys",
        payload: section_body(picker_command(picker_model([])), 0x08),
        expected: []
      }
    ]
  end

  # ── Fixtures: gui_breadcrumb (GuiBreadcrumbFields) ────────────────────────

  # gui_breadcrumb is custom-framed: opcode(1) then the GuiBreadcrumbFields
  # payload (u8 segment count + that many string16 segments). Strip the opcode.
  @spec breadcrumb_payload(Breadcrumb.t()) :: binary()
  defp breadcrumb_payload(model) do
    {cmd, _caches} = BreadcrumbEncoder.encode(model, Caches.new())
    <<_op::8, payload::binary>> = cmd
    payload
  end

  @spec breadcrumb_model([String.t()]) :: Breadcrumb.t()
  defp breadcrumb_model(segments) do
    %Breadcrumb{segments: segments}
  end

  @spec breadcrumb_fixtures() :: [fixture()]
  defp breadcrumb_fixtures do
    empty = breadcrumb_model([])
    typical = breadcrumb_model(["lib", "foo.ex"])
    unicode = breadcrumb_model(["λ", "café→.ex"])
    # A 255-byte segment is the string16 element max worth covering here.
    max_segment = breadcrumb_model([String.duplicate("x", 255)])

    [
      %{
        name: "breadcrumb_empty",
        decoder: "GuiBreadcrumbFields",
        payload: breadcrumb_payload(empty),
        expected: %{segments: []}
      },
      %{
        name: "breadcrumb_typical",
        decoder: "GuiBreadcrumbFields",
        payload: breadcrumb_payload(typical),
        expected: %{segments: ["lib", "foo.ex"]}
      },
      %{
        name: "breadcrumb_unicode",
        decoder: "GuiBreadcrumbFields",
        payload: breadcrumb_payload(unicode),
        expected: %{segments: ["λ", "café→.ex"]}
      },
      %{
        name: "breadcrumb_max_segment",
        decoder: "GuiBreadcrumbFields",
        payload: breadcrumb_payload(max_segment),
        expected: %{segments: [String.duplicate("x", 255)]}
      }
    ]
  end

  # ── Fixtures: gui_git_status (GuiGitStatusFields) ─────────────────────────

  # gui_git_status is custom-framed: opcode(1) then the full GuiGitStatusFields
  # payload (header, entries, toast, and panel presentation tail). Strip
  # the opcode byte.
  @spec git_status_payload(GitStatus.t()) :: binary()
  defp git_status_payload(model) do
    {cmd, _caches} = GitStatusEncoder.encode(model, Caches.new())
    <<_op::8, payload::binary>> = cmd
    payload
  end

  @spec git_path_hash(String.t()) :: non_neg_integer()
  defp git_path_hash(path), do: :erlang.phash2(path, 0xFFFFFFFF)

  @spec absent_toast() :: map()
  defp absent_toast, do: %{present: 0, level: 0, action: 0, message: "", id: 0}

  # A tree that is not clean carries an empty_list with an empty title.
  @spec absent_empty() :: map()
  defp absent_empty, do: %{glyph: "", title: "", why: "", selected: 0, actions: []}

  @spec git_status_fixtures() :: [fixture()]
  defp git_status_fixtures do
    # not_a_repo with an absent toast: presence-byte == 0 path.
    not_repo = GitStatusBuilder.build(nil, false, nil)

    # loading repo at the u16 ahead/behind boundary.
    loading =
      GitStatusBuilder.build(
        %{id: 1, commit_target_id: 1, repo_state: :loading, ahead: 65_535, behind: 65_535},
        false,
        nil
      )

    # Normal repo exercising the section predicate (staged/untracked/conflict/
    # other), the per-entry path_hash, and a present error toast.
    entries = [
      %{path: "lib/a.ex", status: :modified, staged: true},
      %{path: "lib/b.ex", status: :untracked, staged: false},
      %{path: "lib/c.ex", status: :conflict, staged: false},
      %{path: "lib/d.ex", status: :added, staged: false}
    ]

    normal =
      GitStatusBuilder.build(
        %{
          id: 0x2_0000_002A,
          commit_target_id: 0x3_0000_002A,
          repo_state: :normal,
          branch: "main",
          ahead: 2,
          behind: 1,
          entries: entries,
          entry_base_path: "/repo",
          last_commit_message: "fix: λ café→",
          stash_count: 5
        },
        true,
        %{message: "Pull failed", level: :error, action: :pull_and_retry, id: 0x1_0000_002A}
      )
      |> then(&%{&1 | terminal_cursor: 3, terminal_collapsed: 8})

    # Boundary case: the largest valid u16 count and string remain byte-exact.
    max_message = String.duplicate("x", 65_535)

    boundary =
      GitStatusBuilder.build(
        %{
          id: 2,
          commit_target_id: 2,
          repo_state: :normal,
          branch: "b",
          stash_count: 65_535,
          last_commit_message: max_message
        },
        true,
        %{message: "Done", level: :success, action: nil}
      )

    [
      %{
        name: "git_status_not_repo_no_toast",
        decoder: "GuiGitStatusFields",
        payload: git_status_payload(not_repo),
        expected: %{
          repo_state: 1,
          syncing: 0,
          ahead: 0,
          behind: 0,
          branch: "",
          entries: [],
          toast: absent_toast(),
          entry_base_path: "",
          last_commit_message: "",
          stash_count: 0,
          terminal_cursor: 0,
          terminal_collapsed: 0,
          panel_id: 0,
          commit_target_id: 0,
          empty: absent_empty()
        }
      },
      %{
        name: "git_status_loading_max",
        decoder: "GuiGitStatusFields",
        payload: git_status_payload(loading),
        expected: %{
          repo_state: 2,
          syncing: 0,
          ahead: 65_535,
          behind: 65_535,
          branch: "",
          entries: [],
          toast: absent_toast(),
          entry_base_path: "",
          last_commit_message: "",
          stash_count: 0,
          terminal_cursor: 0,
          terminal_collapsed: 0,
          panel_id: 1,
          commit_target_id: 1,
          empty: absent_empty()
        }
      },
      %{
        name: "git_status_normal_entries_toast",
        decoder: "GuiGitStatusFields",
        payload: git_status_payload(normal),
        expected: %{
          repo_state: 0,
          syncing: 1,
          ahead: 2,
          behind: 1,
          branch: "main",
          entries: [
            %{path_hash: git_path_hash("lib/a.ex"), section: 0, status: 1, path: "lib/a.ex"},
            %{path_hash: git_path_hash("lib/b.ex"), section: 2, status: 6, path: "lib/b.ex"},
            %{path_hash: git_path_hash("lib/c.ex"), section: 3, status: 7, path: "lib/c.ex"},
            %{path_hash: git_path_hash("lib/d.ex"), section: 1, status: 2, path: "lib/d.ex"}
          ],
          toast: %{present: 1, level: 1, action: 1, message: "Pull failed", id: 0x1_0000_002A},
          entry_base_path: "/repo",
          last_commit_message: "fix: λ café→",
          stash_count: 5,
          terminal_cursor: 3,
          terminal_collapsed: 8,
          panel_id: 0x2_0000_002A,
          commit_target_id: 0x3_0000_002A,
          empty: absent_empty()
        }
      },
      %{
        name: "git_status_max_boundary",
        decoder: "GuiGitStatusFields",
        payload: git_status_payload(boundary),
        expected: %{
          repo_state: 0,
          syncing: 1,
          ahead: 0,
          behind: 0,
          branch: "b",
          entries: [],
          toast: %{present: 1, level: 0, action: 0, message: "Done", id: 0},
          entry_base_path: "",
          last_commit_message: max_message,
          stash_count: 65_535,
          terminal_cursor: 0,
          terminal_collapsed: 0,
          panel_id: 2,
          commit_target_id: 2,
          empty: absent_empty()
        }
      }
    ]
  end

  # ── Fixtures: gui_search_state (GuiSearchStateFields) ─────────────────────

  @spec search_state_payload(SearchState.t()) :: binary()
  defp search_state_payload(model) do
    # gui_search_state is len16-framed: opcode(1) + payload_len(u16) + payload.
    {cmd, _caches} = SearchStateEncoder.encode(model, Caches.new())
    <<_op::8, len::16, payload::binary-size(len)>> = cmd
    payload
  end

  @spec search_state_fixtures() :: [fixture()]
  defp search_state_fixtures do
    inactive = %SearchState{active: false}

    active = %SearchState{
      active: true,
      match_count: 12,
      current_index: 3,
      query: "café λ",
      session_id: 7,
      acknowledged_edit_seq: 4,
      case_sensitive: true,
      whole_word: false,
      regex: true
    }

    [
      %{
        name: "search_state_inactive",
        decoder: "GuiSearchStateFields",
        payload: search_state_payload(inactive),
        expected: search_state_expected(inactive)
      },
      %{
        name: "search_state_active",
        decoder: "GuiSearchStateFields",
        payload: search_state_payload(active),
        expected: search_state_expected(active)
      }
    ]
  end

  # Re-derive expected fields by decoding the encoder's own bytes so the fixture
  # stays correct even if the search_state flag bit layout changes; the golden
  # test still proves the Go decoder agrees with these bytes.
  @spec search_state_expected(SearchState.t()) :: map()
  defp search_state_expected(model) do
    <<active::8, match_count::32, current_index::32, flags::8, query_len::16,
      query::binary-size(query_len), session_id::32, acknowledged_edit_seq::32, status::8>> =
      search_state_payload(model)

    %{
      active: active,
      match_count: match_count,
      current_index: current_index,
      flags: flags,
      query: query,
      session_id: session_id,
      acknowledged_edit_seq: acknowledged_edit_seq,
      status: status
    }
  end

  # ── Fixtures: gui_surface_layout placements (GuiSurfaceLayoutPlacements) ───

  # gui_surface_layout (#2219 child A) has no hand-written production encoder yet
  # (the BEAM does not emit it until child E). Its placements section is a generated
  # counted_array, so the fixture builds the section body with the generated
  # `Minga.Protocol.Encode.encode_gui_surface_layout_placements/1` — the exact
  # inverse of the generated Go/Swift placement decoder. The golden test still
  # proves cross-language agreement: the generated Elixir encoder and the generated
  # Go decoder must produce identical field values for the same bytes.
  @spec surface_layout_payload([map()]) :: binary()
  defp surface_layout_payload(placements) do
    placements
    |> Encode.encode_gui_surface_layout_placements()
    |> IO.iodata_to_binary()
  end

  @spec placement(
          non_neg_integer(),
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()},
          non_neg_integer(),
          non_neg_integer()
        ) :: map()
  defp placement(surface_id, {row, col, width, height}, z, hit_kind) do
    %{
      surface_id: surface_id,
      rect: %{row: row, col: col, width: width, height: height},
      z: z,
      hit_kind: hit_kind
    }
  end

  @spec surface_layout_fixtures() :: [fixture()]
  defp surface_layout_fixtures do
    typical = [
      placement(1, {0, 0, 80, 24}, 0, 1),
      placement(7, {2, 4, 40, 10}, 5, 2)
    ]

    # Boundary fixture at the u16 ceilings for every numeric field, proving the
    # generated decoder reads full-width values without truncation.
    boundary = [
      placement(65_535, {65_535, 65_535, 65_535, 65_535}, 65_535, 255)
    ]

    [
      %{
        name: "surface_layout_empty",
        decoder: "GuiSurfaceLayoutPlacements",
        payload: surface_layout_payload([]),
        expected: []
      },
      %{
        name: "surface_layout_typical",
        decoder: "GuiSurfaceLayoutPlacements",
        payload: surface_layout_payload(typical),
        expected: typical
      },
      %{
        name: "surface_layout_boundary_max",
        decoder: "GuiSurfaceLayoutPlacements",
        payload: surface_layout_payload(boundary),
        expected: boundary
      }
    ]
  end

  # gui_theme is a header-only command_fields unit (only color_count is modeled
  # in the schema), so there is no top-level golden decoder for the color list;
  # canonical adapter tests cover BEAM theme bytes and frontend decoder tests
  # cover cross-language decoding. No cross-language fixture is emitted here.
  @spec theme_fixtures() :: [fixture()]
  defp theme_fixtures, do: []
end
