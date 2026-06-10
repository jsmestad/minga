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

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ChangeSummaryEncoder
  alias Minga.Frontend.Adapter.GUI.CompletionEncoder
  alias Minga.Frontend.Adapter.GUI.GitStatusEncoder
  alias Minga.Frontend.Adapter.GUI.PickerEncoder
  alias Minga.Frontend.Adapter.GUI.SearchStateEncoder
  alias Minga.Protocol.GoldenFields
  alias Minga.RenderModel.UI.ChangeSummary
  alias Minga.RenderModel.UI.Completion
  alias Minga.RenderModel.UI.GitStatus
  alias Minga.RenderModel.UI.Picker
  alias Minga.RenderModel.UI.SearchState

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
      git_status_fixtures() ++
      change_summary_fixtures() ++
      search_state_fixtures() ++
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
      ]
    }

    unicode = %Completion{
      visible?: true,
      cursor_row: 0,
      cursor_col: 0,
      selected_offset: 0,
      items: [%Completion.Item{kind: :variable, label: "café→λ", detail: "ünïcödé"}]
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
          items: []
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
          ]
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
          items: [%{kind: 3, label: "café→λ", detail: "ünïcödé"}]
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
          items: []
        }
      }
    ]
  end

  # ── Fixtures: gui_picker header (GuiPickerHeader) ─────────────────────────

  @spec picker_model([Picker.Item.t()]) :: Picker.t()
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
      }
    ]
  end

  @spec picker_query_fixtures() :: [fixture()]
  defp picker_query_fixtures do
    [
      %{
        name: "picker_query_unicode",
        decoder: "GuiPickerQuery",
        payload: section_body(picker_command(%{picker_model([]) | query: "λ-query"}), 0x02),
        expected: %{text: "λ-query"}
      },
      %{
        name: "picker_query_empty",
        decoder: "GuiPickerQuery",
        payload: section_body(picker_command(%{picker_model([]) | query: ""}), 0x02),
        expected: %{text: ""}
      }
    ]
  end

  # ── Fixtures: gui_picker items (PickerItem) ───────────────────────────────

  @spec picker_item_fixtures() :: [fixture()]
  defp picker_item_fixtures do
    items = [
      %Picker.Item{
        id: 1,
        label: "file.ex",
        description: "desc",
        annotation: "ann",
        icon_color: 0x00AABBCC,
        two_line?: false,
        match_positions: [1, 4],
        marked?: false
      },
      %Picker.Item{
        id: 2,
        label: "x",
        description: "",
        annotation: "",
        icon_color: nil,
        two_line?: true,
        match_positions: [],
        marked?: true
      }
    ]

    payload = section_body(picker_command(picker_model(items)), 0x03)
    # The items section body is count(u16) ++ items; strip the count prefix so
    # the GuiPickerItems decoder (which reads the count) is exercised separately
    # by re-using the section body directly.
    [
      %{
        name: "picker_items_list",
        decoder: "GuiPickerItems",
        payload: payload,
        expected: [
          %{
            icon_color: 0x00AABBCC,
            flags: 0,
            label: "file.ex",
            description: "desc",
            annotation: "ann",
            match_positions: [1, 4]
          },
          %{
            icon_color: 0,
            # two_line? sets bit 0, marked? sets bit 1 => 0b11 = 3
            flags: 3,
            label: "x",
            description: "",
            annotation: "",
            match_positions: []
          }
        ]
      },
      %{
        name: "picker_items_empty",
        decoder: "GuiPickerItems",
        payload: section_body(picker_command(picker_model([])), 0x03),
        expected: []
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

  # ── Fixtures: gui_git_status header (GuiGitStatusFields) ──────────────────

  @spec git_status_payload(GitStatus.t()) :: binary()
  defp git_status_payload(model) do
    # gui_git_status is custom-framed: opcode(1) then the payload. The generated
    # decoder reads only the fixed 6-byte header (repo_state, syncing, ahead,
    # behind), so take just that prefix after the opcode byte.
    {cmd, _caches} = GitStatusEncoder.encode(model, Caches.new())
    <<_op::8, header::binary-size(6), _tail::binary>> = cmd
    header
  end

  @spec git_status_fixtures() :: [fixture()]
  defp git_status_fixtures do
    normal = %GitStatus{
      repo_state: :normal,
      syncing: true,
      branch: "main",
      ahead: 2,
      behind: 1,
      entries: []
    }

    not_repo = %GitStatus{repo_state: :not_a_repo, syncing: false, ahead: 0, behind: 0}
    loading = %GitStatus{repo_state: :loading, syncing: false, ahead: 65_535, behind: 65_535}

    [
      %{
        name: "git_status_normal",
        decoder: "GuiGitStatusFields",
        payload: git_status_payload(normal),
        expected: %{repo_state: 0, syncing: 1, ahead: 2, behind: 1}
      },
      %{
        name: "git_status_not_repo",
        decoder: "GuiGitStatusFields",
        payload: git_status_payload(not_repo),
        expected: %{repo_state: 1, syncing: 0, ahead: 0, behind: 0}
      },
      %{
        name: "git_status_loading_max",
        decoder: "GuiGitStatusFields",
        payload: git_status_payload(loading),
        expected: %{repo_state: 2, syncing: 0, ahead: 65_535, behind: 65_535}
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

  # gui_theme is a header-only command_fields unit (only color_count is modeled
  # in the schema), so there is no top-level golden decoder for the color list;
  # it is covered by the encoder parity oracle tests instead. No cross-language
  # fixture is emitted here.
  @spec theme_fixtures() :: [fixture()]
  defp theme_fixtures, do: []
end
