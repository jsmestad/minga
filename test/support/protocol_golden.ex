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

  alias Minga.Frontend.Adapter.GUI.BreadcrumbEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ChangeSummaryEncoder
  alias Minga.Frontend.Adapter.GUI.CompletionEncoder
  alias Minga.Frontend.Adapter.GUI.GitStatusEncoder
  alias Minga.Frontend.Adapter.GUI.PickerEncoder
  alias Minga.Frontend.Adapter.GUI.SearchStateEncoder
  alias Minga.Protocol.Encode
  alias Minga.Protocol.GoldenFields
  alias Minga.RenderModel.UI.Breadcrumb
  alias Minga.RenderModel.UI.ChangeSummary
  alias Minga.RenderModel.UI.Completion
  alias Minga.RenderModel.UI.GitStatus
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
      picker_action_menu_fixtures() ++
      picker_load_status_fixtures() ++
      picker_query_fixtures() ++
      breadcrumb_fixtures() ++
      git_status_fixtures() ++
      change_summary_fixtures() ++
      search_state_fixtures() ++
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

  # ── Fixtures: gui_completion (GuiCompletionFields) ───────────────────────

  @spec completion_fixtures() :: [fixture()]
  defp completion_fixtures do
    hidden = %Completion{visible?: false}

    typical = %Completion{
      visible?: true,
      cursor_row: 3,
      cursor_col: 7,
      selected_offset: 1,
      items: [
        %Completion.Item{kind: :function, label: "foo", detail: "bar"},
        %Completion.Item{kind: :module, label: "Baz", detail: ""}
      ],
      documentation: "Calls foo/1.\n\nReturns the result."
    }

    unicode = %Completion{
      visible?: true,
      cursor_row: 0,
      cursor_col: 0,
      selected_offset: 0,
      items: [%Completion.Item{kind: :variable, label: "café→λ", detail: "ünïcödé"}],
      documentation: "Café λ docs → ✓"
    }

    empty_items = %Completion{visible?: true, cursor_row: 1, cursor_col: 2, items: []}

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
          documentation: ""
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
            %{kind: 1, label: "foo", detail: "bar"},
            %{kind: 5, label: "Baz", detail: ""}
          ],
          documentation: "Calls foo/1.\n\nReturns the result."
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
          items: [%{kind: 3, label: "café→λ", detail: "ünïcödé"}],
          documentation: "Café λ docs → ✓"
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
          documentation: ""
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
      action_menu: nil,
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
          marked_count: 3
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
          marked_count: 3
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
          marked_count: 0
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
          marked_count: 0
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
        match_positions: [1, 4]
      },
      %{
        # two_line sets bit 0, marked sets bit 1 => 0b11 = 3
        icon_color: 0,
        flags: 3,
        label: "x",
        description: "",
        annotation: "",
        match_positions: []
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
      match_positions: Enum.to_list(0..254)
    }

    payload = section_body(picker_command(picker_model(items)), 0x03)

    [
      %{
        name: "picker_items_list",
        decoder: "GuiPickerItems",
        payload: payload,
        expected: items
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
        expected: [boundary_max]
      }
    ]
  end

  # ── Fixtures: gui_picker action menu (GuiPickerActionMenu) ────────────────

  @spec picker_action_menu_fixtures() :: [fixture()]
  defp picker_action_menu_fixtures do
    visible_menu = %Picker.ActionMenu{actions: ["Open", "Delete"], selected_index: 1}
    empty_menu = %Picker.ActionMenu{actions: [], selected_index: 5}

    [
      %{
        name: "action_menu_hidden",
        decoder: "GuiPickerActionMenu",
        payload: section_body(picker_command(%{picker_model([]) | action_menu: nil}), 0x04),
        expected: %{visible: 0, selected_index: 0, actions: []}
      },
      %{
        name: "action_menu_visible",
        decoder: "GuiPickerActionMenu",
        payload:
          section_body(picker_command(%{picker_model([]) | action_menu: visible_menu}), 0x04),
        expected: %{visible: 1, selected_index: 1, actions: ["Open", "Delete"]}
      },
      %{
        name: "action_menu_empty_actions",
        decoder: "GuiPickerActionMenu",
        payload:
          section_body(picker_command(%{picker_model([]) | action_menu: empty_menu}), 0x04),
        expected: %{visible: 1, selected_index: 5, actions: []}
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
  # payload (header + entries + toast + base_path/last_commit/stash tail). Strip
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
  defp absent_toast, do: %{present: 0, level: 0, action: 0, message: ""}

  @spec git_status_fixtures() :: [fixture()]
  defp git_status_fixtures do
    # not_a_repo with an absent toast: presence-byte == 0 path.
    not_repo = GitStatusBuilder.build(nil, false, nil)

    # loading repo at the u16 ahead/behind boundary.
    loading =
      GitStatusBuilder.build(%{repo_state: :loading, ahead: 65_535, behind: 65_535}, false, nil)

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
        %{message: "Pull failed", level: :error, action: :pull_and_retry}
      )

    # Boundary case: the largest valid u16 count and string remain byte-exact.
    max_message = String.duplicate("x", 65_535)

    boundary =
      GitStatusBuilder.build(
        %{
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
          stash_count: 0
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
          stash_count: 0
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
          toast: %{present: 1, level: 1, action: 1, message: "Pull failed"},
          entry_base_path: "/repo",
          last_commit_message: "fix: λ café→",
          stash_count: 5
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
          toast: %{present: 1, level: 0, action: 0, message: "Done"},
          entry_base_path: "",
          last_commit_message: max_message,
          stash_count: 65_535
        }
      }
    ]
  end

  # ── Fixtures: gui_change_summary header (GuiChangeSummaryFields) ──────────

  @spec change_summary_payload(ChangeSummary.t()) :: binary()
  defp change_summary_payload(model) do
    # gui_change_summary is custom-framed: opcode(1) then the payload. The
    # generated decoder reads only the 5-byte header
    # (visible, selected_index, entry_count).
    {cmd, _caches} = ChangeSummaryEncoder.encode(model, Caches.new())
    <<_op::8, header::binary-size(5), _tail::binary>> = cmd
    header
  end

  @spec change_summary_fixtures() :: [fixture()]
  defp change_summary_fixtures do
    empty = %ChangeSummary{entries: [], selected_index: 0}

    populated = %ChangeSummary{
      selected_index: 1,
      entries: [
        %ChangeSummary.Entry{path: "a.ex", action: :modified, lines_added: 3, lines_removed: 1},
        %ChangeSummary.Entry{path: "b.ex", action: :added, lines_added: 10, lines_removed: 0}
      ]
    }

    [
      %{
        name: "change_summary_empty",
        decoder: "GuiChangeSummaryFields",
        payload: change_summary_payload(empty),
        expected: %{visible: 0, selected_index: 0, entry_count: 0}
      },
      %{
        name: "change_summary_populated",
        decoder: "GuiChangeSummaryFields",
        payload: change_summary_payload(populated),
        expected: %{visible: 1, selected_index: 1, entry_count: 2}
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
    <<active::8, match_count::16, current_index::16, flags::8>> = search_state_payload(model)
    %{active: active, match_count: match_count, current_index: current_index, flags: flags}
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
