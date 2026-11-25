defmodule Minga.Protocol.Encode do
  @moduledoc """
  Generated pure protocol encoders.

  Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.

  Each `encode_*/1` validates schema-owned bounded fields immediately before
  emitting them and returns the on-wire iodata for one schema record.
  """

  alias Minga.Protocol.EncodingError

  @spec encode_terminal_feature(atom()) :: non_neg_integer()
  def encode_terminal_feature(:unknown), do: 0
  def encode_terminal_feature(:true_color), do: 1
  def encode_terminal_feature(:styled_underlines), do: 2
  def encode_terminal_feature(:underline_color), do: 3
  def encode_terminal_feature(:hyperlinks), do: 4
  def encode_terminal_feature(:kitty_keyboard), do: 5
  def encode_terminal_feature(:desktop_notifications), do: 6
  def encode_terminal_feature(:tab_title), do: 7
  def encode_terminal_feature(:tab_progress), do: 8
  def encode_terminal_feature(:kitty_graphics), do: 9
  def encode_terminal_feature(:synchronized_output), do: 10
  def encode_terminal_feature(:focus_reporting), do: 11
  def encode_terminal_feature(:clipboard_osc52), do: 12
  def encode_terminal_feature(_), do: 0

  @spec encode_terminal_feature_status(atom()) :: non_neg_integer()
  def encode_terminal_feature_status(:unknown), do: 0
  def encode_terminal_feature_status(:pending), do: 1
  def encode_terminal_feature_status(:detected), do: 2
  def encode_terminal_feature_status(:missing), do: 3
  def encode_terminal_feature_status(:fallback), do: 4
  def encode_terminal_feature_status(_), do: 0

  @spec encode_agent_approval_decision(atom()) :: non_neg_integer()
  def encode_agent_approval_decision(:unknown), do: 0
  def encode_agent_approval_decision(:approve), do: 1
  def encode_agent_approval_decision(:approve_session), do: 2
  def encode_agent_approval_decision(:approve_turn), do: 3
  def encode_agent_approval_decision(:reject), do: 4
  def encode_agent_approval_decision(_), do: 0

  @spec encode_frame_rejection_reason(atom()) :: non_neg_integer()
  def encode_frame_rejection_reason(:truncation), do: 1
  def encode_frame_rejection_reason(:commit_sequence_mismatch), do: 2
  def encode_frame_rejection_reason(:frame_sequence_not_increasing), do: 3
  def encode_frame_rejection_reason(:base_sequence_mismatch), do: 4
  def encode_frame_rejection_reason(:missing_theme), do: 5
  def encode_frame_rejection_reason(:incomplete_theme), do: 6
  def encode_frame_rejection_reason(:missing_window_reference), do: 7
  def encode_frame_rejection_reason(:window_epoch_mismatch), do: 8
  def encode_frame_rejection_reason(:invalid_retained_rows), do: 9
  def encode_frame_rejection_reason(:missing_font_resource), do: 10
  def encode_frame_rejection_reason(:transcript_desync), do: 11
  def encode_frame_rejection_reason(:decode_failure), do: 12
  def encode_frame_rejection_reason(:out_of_transaction_command), do: 13
  def encode_frame_rejection_reason(:invalid_row_splice), do: 14
  def encode_frame_rejection_reason(:resource_policy), do: 15
  def encode_frame_rejection_reason(:unknown), do: 255
  def encode_frame_rejection_reason(_), do: 255

  @spec encode_application_quit_decision(atom()) :: non_neg_integer()
  def encode_application_quit_decision(:save), do: 0
  def encode_application_quit_decision(:discard), do: 1
  def encode_application_quit_decision(:cancel), do: 2
  def encode_application_quit_decision(_), do: 2

  @spec encode_application_quit_outcome(atom()) :: non_neg_integer()
  def encode_application_quit_outcome(:needs_decision), do: 0
  def encode_application_quit_outcome(:proceeding), do: 1
  def encode_application_quit_outcome(:cancelled), do: 2
  def encode_application_quit_outcome(:save_failed), do: 3
  def encode_application_quit_outcome(_), do: 2

  @spec encode_frame_rejection_disposition(atom()) :: non_neg_integer()
  def encode_frame_rejection_disposition(:retryable_recovery), do: 1
  def encode_frame_rejection_disposition(:targeted_replacement), do: 2
  def encode_frame_rejection_disposition(:adapted_retry), do: 3
  def encode_frame_rejection_disposition(:terminal_frontend_failure), do: 4
  def encode_frame_rejection_disposition(_), do: 4

  @spec encode_resource_policy_dimension(atom()) :: non_neg_integer()
  def encode_resource_policy_dimension(:unknown), do: 0
  def encode_resource_policy_dimension(:frame_bytes), do: 1
  def encode_resource_policy_dimension(:frame_commands), do: 2
  def encode_resource_policy_dimension(:window_rows), do: 3
  def encode_resource_policy_dimension(_), do: 0

  @spec encode_completion_kind(atom()) :: non_neg_integer()
  def encode_completion_kind(:unknown), do: 0
  def encode_completion_kind(:function), do: 1
  def encode_completion_kind(:method), do: 2
  def encode_completion_kind(:variable), do: 3
  def encode_completion_kind(:field), do: 4
  def encode_completion_kind(:module), do: 5
  def encode_completion_kind(:keyword), do: 7
  def encode_completion_kind(:snippet), do: 8
  def encode_completion_kind(:constant), do: 9
  def encode_completion_kind(:struct), do: 11
  def encode_completion_kind(:enum), do: 12
  def encode_completion_kind(_), do: 0

  @spec encode_picker_movement(atom()) :: non_neg_integer()
  def encode_picker_movement(:none), do: 0
  def encode_picker_movement(:next), do: 1
  def encode_picker_movement(:previous), do: 2
  def encode_picker_movement(_), do: 0

  @spec encode_picker_status_tone(atom()) :: non_neg_integer()
  def encode_picker_status_tone(:none), do: 0
  def encode_picker_status_tone(:ready), do: 1
  def encode_picker_status_tone(:warn), do: 2
  def encode_picker_status_tone(:error), do: 3
  def encode_picker_status_tone(:checking), do: 4
  def encode_picker_status_tone(:neutral), do: 5
  def encode_picker_status_tone(_), do: 0

  @spec encode_git_file_status(atom()) :: non_neg_integer()
  def encode_git_file_status(:unknown), do: 0
  def encode_git_file_status(:modified), do: 1
  def encode_git_file_status(:added), do: 2
  def encode_git_file_status(:deleted), do: 3
  def encode_git_file_status(:renamed), do: 4
  def encode_git_file_status(:copied), do: 5
  def encode_git_file_status(:untracked), do: 6
  def encode_git_file_status(:conflict), do: 7
  def encode_git_file_status(_), do: 0

  @spec encode_git_repo_state(atom()) :: non_neg_integer()
  def encode_git_repo_state(:normal), do: 0
  def encode_git_repo_state(:not_a_repo), do: 1
  def encode_git_repo_state(:loading), do: 2
  def encode_git_repo_state(_), do: 1

  @spec encode_git_toast_level(atom()) :: non_neg_integer()
  def encode_git_toast_level(:success), do: 0
  def encode_git_toast_level(:error), do: 1
  def encode_git_toast_level(_), do: 0

  @spec encode_git_toast_action(atom()) :: non_neg_integer()
  def encode_git_toast_action(:none), do: 0
  def encode_git_toast_action(:pull_and_retry), do: 1
  def encode_git_toast_action(_), do: 0

  @spec encode_operation_kind(atom()) :: non_neg_integer()
  def encode_operation_kind(:unknown), do: 0
  def encode_operation_kind(:external_format), do: 1
  def encode_operation_kind(:git_stage), do: 2
  def encode_operation_kind(:git_unstage), do: 3
  def encode_operation_kind(:git_discard), do: 4
  def encode_operation_kind(:git_stage_all), do: 5
  def encode_operation_kind(:git_unstage_all), do: 6
  def encode_operation_kind(:git_commit), do: 7
  def encode_operation_kind(:lsp_references), do: 8
  def encode_operation_kind(:lsp_rename), do: 9
  def encode_operation_kind(_), do: 0

  @spec encode_operation_status(atom()) :: non_neg_integer()
  def encode_operation_status(:pending), do: 1
  def encode_operation_status(:queued), do: 2
  def encode_operation_status(:running), do: 3
  def encode_operation_status(:success), do: 4
  def encode_operation_status(:error), do: 5
  def encode_operation_status(:timeout), do: 6
  def encode_operation_status(:canceled), do: 7
  def encode_operation_status(:stale), do: 8
  def encode_operation_status(_), do: 1

  @spec encode_rect(map()) :: iodata()
  def encode_rect(model), do: encode_rect(model, :rect, [])

  @spec encode_rect(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_rect(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :row)),
      (fn value -> validate_uint!(command, [:col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :col)),
      (fn value -> validate_uint!(command, [:width | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :width)),
      (fn value -> validate_uint!(command, [:height | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :height)),
    ]
  end

  @spec encode_span(map()) :: iodata()
  def encode_span(model), do: encode_span(model, :span, [])

  @spec encode_span(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_span(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:start_col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :start_col)),
      (fn value -> validate_uint!(command, [:end_col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :end_col)),
      (fn value -> validate_uint!(command, [:fg | path], value, 16777215); <<value::24>> end).(Map.fetch!(model, :fg)),
      (fn value -> validate_uint!(command, [:bg | path], value, 16777215); <<value::24>> end).(Map.fetch!(model, :bg)),
      (fn value -> validate_uint!(command, [:attrs | path], value, 255); <<value::8>> end).(Map.fetch!(model, :attrs)),
      (fn value -> validate_uint!(command, [:font_weight | path], value, 255); <<value::8>> end).(Map.fetch!(model, :font_weight)),
      (fn value -> validate_uint!(command, [:font_id | path], value, 255); <<value::8>> end).(Map.fetch!(model, :font_id)),
    ]
  end

  @spec encode_row(map()) :: iodata()
  def encode_row(model), do: encode_row(model, :row, [])

  @spec encode_row(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_row(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:row_type | path], value, 255); <<value::8>> end).(Map.fetch!(model, :row_type)),
      (fn value -> validate_uint!(command, [:row_id | path], value, 18446744073709551615); <<value::64>> end).(Map.fetch!(model, :row_id)),
      (fn value -> validate_uint!(command, [:buf_line | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :buf_line)),
      (fn value -> validate_uint!(command, [:content_hash | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :content_hash)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:text | path], byte_size(bin), 4294967295); <<byte_size(bin)::32, bin::binary>> end).(Map.fetch!(model, :text)),
      (fn items -> count = Enum.count(items); validate_uint!(command, [:spans | path], count, 65535); [<<count::16>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_span(value, command, [index | [:spans | path]]) end)] end).(Map.fetch!(model, :spans)),
    ]
  end

  @spec encode_search_match(map()) :: iodata()
  def encode_search_match(model), do: encode_search_match(model, :search_match, [])

  @spec encode_search_match(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_search_match(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :row)),
      (fn value -> validate_uint!(command, [:start_col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :start_col)),
      (fn value -> validate_uint!(command, [:end_col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :end_col)),
      (fn value -> validate_uint!(command, [:is_current | path], value, 255); <<value::8>> end).(Map.fetch!(model, :is_current)),
    ]
  end

  @spec encode_diagnostic_range(map()) :: iodata()
  def encode_diagnostic_range(model), do: encode_diagnostic_range(model, :diagnostic_range, [])

  @spec encode_diagnostic_range(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_diagnostic_range(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:start_row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :start_row)),
      (fn value -> validate_uint!(command, [:start_col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :start_col)),
      (fn value -> validate_uint!(command, [:end_row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :end_row)),
      (fn value -> validate_uint!(command, [:end_col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :end_col)),
      (fn value -> validate_uint!(command, [:severity | path], value, 255); <<value::8>> end).(Map.fetch!(model, :severity)),
    ]
  end

  @spec encode_accessibility_range(map()) :: iodata()
  def encode_accessibility_range(model), do: encode_accessibility_range(model, :accessibility_range, [])

  @spec encode_accessibility_range(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_accessibility_range(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :row)),
      (fn value -> validate_uint!(command, [:start_utf16 | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :start_utf16)),
      (fn value -> validate_uint!(command, [:end_utf16 | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :end_utf16)),
    ]
  end

  @spec encode_document_highlight(map()) :: iodata()
  def encode_document_highlight(model), do: encode_document_highlight(model, :document_highlight, [])

  @spec encode_document_highlight(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_document_highlight(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:start_row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :start_row)),
      (fn value -> validate_uint!(command, [:start_col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :start_col)),
      (fn value -> validate_uint!(command, [:end_row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :end_row)),
      (fn value -> validate_uint!(command, [:end_col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :end_col)),
      (fn value -> validate_uint!(command, [:kind | path], value, 255); <<value::8>> end).(Map.fetch!(model, :kind)),
    ]
  end

  @spec encode_annotation(map()) :: iodata()
  def encode_annotation(model), do: encode_annotation(model, :annotation, [])

  @spec encode_annotation(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_annotation(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :row)),
      (fn value -> validate_uint!(command, [:kind | path], value, 255); <<value::8>> end).(Map.fetch!(model, :kind)),
      (fn value -> validate_uint!(command, [:fg | path], value, 16777215); <<value::24>> end).(Map.fetch!(model, :fg)),
      (fn value -> validate_uint!(command, [:bg | path], value, 16777215); <<value::24>> end).(Map.fetch!(model, :bg)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:text | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :text)),
    ]
  end

  @spec encode_hit_region(map()) :: iodata()
  def encode_hit_region(model), do: encode_hit_region(model, :hit_region, [])

  @spec encode_hit_region(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_hit_region(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:kind | path], value, 255); <<value::8>> end).(Map.fetch!(model, :kind)),
      encode_rect(Map.fetch!(model, :rect), command, [:rect | path]),
      (fn value -> validate_uint!(command, [:id | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :id)),
    ]
  end

  @spec encode_surface_placement(map()) :: iodata()
  def encode_surface_placement(model), do: encode_surface_placement(model, :surface_placement, [])

  @spec encode_surface_placement(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_surface_placement(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:surface_id | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :surface_id)),
      encode_rect(Map.fetch!(model, :rect), command, [:rect | path]),
      (fn value -> validate_uint!(command, [:z | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :z)),
      (fn value -> validate_uint!(command, [:hit_kind | path], value, 255); <<value::8>> end).(Map.fetch!(model, :hit_kind)),
    ]
  end

  @spec encode_gutter_entry(map()) :: iodata()
  def encode_gutter_entry(model), do: encode_gutter_entry(model, :gutter_entry, [])

  @spec encode_gutter_entry(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gutter_entry(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:buf_line | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :buf_line)),
      (fn value -> validate_uint!(command, [:display_type | path], value, 255); <<value::8>> end).(Map.fetch!(model, :display_type)),
      (fn value -> validate_uint!(command, [:sign_type | path], value, 255); <<value::8>> end).(Map.fetch!(model, :sign_type)),
      (fn value -> validate_uint!(command, [:fold_end_line | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :fold_end_line)),
      if Map.fetch!(model, :sign_type) == 8 do
        [
          (fn value -> validate_uint!(command, [:sign_fg | path], value, 16777215); <<value::24>> end).(Map.fetch!(model, :sign_fg)),
          (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:sign_text | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :sign_text)),
        ]
      else
        []
      end
    ]
  end

  @spec encode_modeline_segment(map()) :: iodata()
  def encode_modeline_segment(model), do: encode_modeline_segment(model, :modeline_segment, [])

  @spec encode_modeline_segment(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_modeline_segment(model, command, path) do
    [
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:name | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :name)),
      (fn value -> validate_uint!(command, [:fg | path], value, 16777215); <<value::24>> end).(Map.fetch!(model, :fg)),
      (fn value -> validate_uint!(command, [:bg | path], value, 16777215); <<value::24>> end).(Map.fetch!(model, :bg)),
      (fn value -> validate_uint!(command, [:attrs | path], value, 255); <<value::8>> end).(Map.fetch!(model, :attrs)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:text | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :text)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:target | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :target)),
      (fn value -> validate_uint!(command, [:drop | path], value, 255); <<value::8>> end).(Map.fetch!(model, :drop)),
      (fn value -> validate_uint!(command, [:flags | path], value, 255); <<value::8>> end).(Map.fetch!(model, :flags)),
      (fn value -> validate_uint!(command, [:state | path], value, 255); <<value::8>> end).(Map.fetch!(model, :state)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:compact | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :compact)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:key | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :key)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:label | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :label)),
    ]
  end

  @spec encode_tab_entry(map()) :: iodata()
  def encode_tab_entry(model), do: encode_tab_entry(model, :tab_entry, [])

  @spec encode_tab_entry(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_tab_entry(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:flags | path], value, 255); <<value::8>> end).(Map.fetch!(model, :flags)),
      (fn value -> validate_uint!(command, [:id | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :id)),
      (fn value -> validate_uint!(command, [:workspace_id | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :workspace_id)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:icon | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :icon)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:label | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :label)),
      (fn value -> validate_uint!(command, [:tint_color | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :tint_color)),
    ]
  end

  @spec encode_theme_color(map()) :: iodata()
  def encode_theme_color(model), do: encode_theme_color(model, :theme_color, [])

  @spec encode_theme_color(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_theme_color(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:slot | path], value, 255); <<value::8>> end).(Map.fetch!(model, :slot)),
      (fn value -> validate_uint!(command, [:color | path], value, 16777215); <<value::24>> end).(Map.fetch!(model, :color)),
    ]
  end

  @spec encode_completion_match_range(map()) :: iodata()
  def encode_completion_match_range(model), do: encode_completion_match_range(model, :completion_match_range, [])

  @spec encode_completion_match_range(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_completion_match_range(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:start | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :start)),
      (fn value -> validate_uint!(command, [:length | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :length)),
    ]
  end

  @spec encode_completion_item(map()) :: iodata()
  def encode_completion_item(model), do: encode_completion_item(model, :completion_item, [])

  @spec encode_completion_item(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_completion_item(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:kind | path], value, 255); <<value::8>> end).(encode_completion_kind(Map.fetch!(model, :kind))),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:label | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :label)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:detail | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :detail)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:id | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :id)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:source | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :source)),
      (fn items -> count = Enum.count(items); validate_uint!(command, [:match_ranges | path], count, 255); [<<count::8>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_completion_match_range(value, command, [index | [:match_ranges | path]]) end)] end).(Map.fetch!(model, :match_ranges)),
    ]
  end

  @spec encode_picker_item(map()) :: iodata()
  def encode_picker_item(model), do: encode_picker_item(model, :picker_item, [])

  @spec encode_picker_item(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_picker_item(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:icon_color | path], value, 16777215); <<value::24>> end).(Map.fetch!(model, :icon_color)),
      (fn value -> validate_uint!(command, [:flags | path], value, 255); <<value::8>> end).(Map.fetch!(model, :flags)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:label | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :label)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:description | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :description)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:annotation | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :annotation)),
      (fn items -> count = Enum.count(items); validate_uint!(command, [:match_positions | path], count, 255); [<<count::8>> | Enum.map(Stream.with_index(items), fn {value, index} -> (fn value -> validate_uint!(command, [index | [:match_positions | path]], value, 65535); <<value::16>> end).(value) end)] end).(Map.fetch!(model, :match_positions)),
      (fn value -> validate_uint!(command, [:activation_id | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :activation_id)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:status | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :status)),
      (fn value -> validate_uint!(command, [:status_tone | path], value, 255); <<value::8>> end).(encode_picker_status_tone(Map.fetch!(model, :status_tone))),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:group | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :group)),
    ]
  end

  @spec encode_empty_list_action(map()) :: iodata()
  def encode_empty_list_action(model), do: encode_empty_list_action(model, :empty_list_action, [])

  @spec encode_empty_list_action(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_empty_list_action(model, command, path) do
    [
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:id | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :id)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:key | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :key)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:label | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :label)),
    ]
  end

  @spec encode_empty_list(map()) :: iodata()
  def encode_empty_list(model), do: encode_empty_list(model, :empty_list, [])

  @spec encode_empty_list(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_empty_list(model, command, path) do
    [
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:glyph | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :glyph)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:title | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :title)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:why | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :why)),
      (fn value -> validate_uint!(command, [:selected | path], value, 255); <<value::8>> end).(Map.fetch!(model, :selected)),
      (fn items -> count = Enum.count(items); validate_uint!(command, [:actions | path], count, 255); [<<count::8>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_empty_list_action(value, command, [index | [:actions | path]]) end)] end).(Map.fetch!(model, :actions)),
    ]
  end

  @spec encode_picker_movement_key(map()) :: iodata()
  def encode_picker_movement_key(model), do: encode_picker_movement_key(model, :picker_movement_key, [])

  @spec encode_picker_movement_key(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_picker_movement_key(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:codepoint | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :codepoint)),
      (fn value -> validate_uint!(command, [:modifiers | path], value, 255); <<value::8>> end).(Map.fetch!(model, :modifiers)),
      (fn value -> validate_uint!(command, [:movement | path], value, 255); <<value::8>> end).(encode_picker_movement(Map.fetch!(model, :movement))),
    ]
  end

  @spec encode_which_key_crumb(map()) :: iodata()
  def encode_which_key_crumb(model), do: encode_which_key_crumb(model, :which_key_crumb, [])

  @spec encode_which_key_crumb(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_which_key_crumb(model, command, path) do
    [
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:key | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :key)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:label | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :label)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:path | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :path)),
    ]
  end

  @spec encode_which_key_hint(map()) :: iodata()
  def encode_which_key_hint(model), do: encode_which_key_hint(model, :which_key_hint, [])

  @spec encode_which_key_hint(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_which_key_hint(model, command, path) do
    [
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:key | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :key)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:label | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :label)),
    ]
  end

  @spec encode_menu_bar_item(map()) :: iodata()
  def encode_menu_bar_item(model), do: encode_menu_bar_item(model, :menu_bar_item, [])

  @spec encode_menu_bar_item(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_menu_bar_item(model, command, path) do
    [
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:path | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :path)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:label | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :label)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:section | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :section)),
      (fn value -> validate_uint!(command, [:kind | path], value, 255); <<value::8>> end).(Map.fetch!(model, :kind)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:command | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :command)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:platform_key | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :platform_key)),
    ]
  end

  @spec encode_which_key_entry(map()) :: iodata()
  def encode_which_key_entry(model), do: encode_which_key_entry(model, :which_key_entry, [])

  @spec encode_which_key_entry(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_which_key_entry(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:kind | path], value, 255); <<value::8>> end).(Map.fetch!(model, :kind)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:key | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :key)),
      (fn value -> validate_uint!(command, [:codepoint | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :codepoint)),
      (fn value -> validate_uint!(command, [:modifiers | path], value, 255); <<value::8>> end).(Map.fetch!(model, :modifiers)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:label | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :label)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:section | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :section)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:count | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :count)),
      (fn value -> validate_uint!(command, [:count_tone | path], value, 255); <<value::8>> end).(Map.fetch!(model, :count_tone)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:platform_key | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :platform_key)),
    ]
  end

  @spec encode_agent_todo(map()) :: iodata()
  def encode_agent_todo(model), do: encode_agent_todo(model, :agent_todo, [])

  @spec encode_agent_todo(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_agent_todo(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:status | path], value, 255); <<value::8>> end).(Map.fetch!(model, :status)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:description | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :description)),
    ]
  end

  @spec encode_edit_timeline_entry(map()) :: iodata()
  def encode_edit_timeline_entry(model), do: encode_edit_timeline_entry(model, :edit_timeline_entry, [])

  @spec encode_edit_timeline_entry(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_edit_timeline_entry(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:index | path], value, 255); <<value::8>> end).(Map.fetch!(model, :index)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:tool_name | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :tool_name)),
      (fn value -> validate_uint!(command, [:timestamp_delta | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :timestamp_delta)),
    ]
  end

  @spec encode_edit_timeline_file(map()) :: iodata()
  def encode_edit_timeline_file(model), do: encode_edit_timeline_file(model, :edit_timeline_file, [])

  @spec encode_edit_timeline_file(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_edit_timeline_file(model, command, path) do
    [
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:path | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :path)),
      (fn value -> validate_uint!(command, [:entry_count | path], value, 255); <<value::8>> end).(Map.fetch!(model, :entry_count)),
      (fn value -> validate_uint!(command, [:lines_added | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :lines_added)),
      (fn value -> validate_uint!(command, [:lines_removed | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :lines_removed)),
      (fn value -> validate_uint!(command, [:review_status | path], value, 255); <<value::8>> end).(Map.fetch!(model, :review_status)),
    ]
  end

  @spec encode_git_status_entry(map()) :: iodata()
  def encode_git_status_entry(model), do: encode_git_status_entry(model, :git_status_entry, [])

  @spec encode_git_status_entry(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_git_status_entry(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:path_hash | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :path_hash)),
      (fn value -> validate_uint!(command, [:section | path], value, 255); <<value::8>> end).(Map.fetch!(model, :section)),
      (fn value -> validate_uint!(command, [:status | path], value, 255); <<value::8>> end).(encode_git_file_status(Map.fetch!(model, :status))),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:path | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :path)),
    ]
  end

  @spec encode_git_toast(map()) :: iodata()
  def encode_git_toast(model), do: encode_git_toast(model, :git_toast, [])

  @spec encode_git_toast(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_git_toast(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:present | path], value, 255); <<value::8>> end).(Map.fetch!(model, :present)),
      if Map.fetch!(model, :present) == 1 do
        [
          (fn value -> validate_uint!(command, [:level | path], value, 255); <<value::8>> end).(encode_git_toast_level(Map.fetch!(model, :level))),
          (fn value -> validate_uint!(command, [:action | path], value, 255); <<value::8>> end).(encode_git_toast_action(Map.fetch!(model, :action))),
          (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:message | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :message)),
          (fn value -> validate_uint!(command, [:id | path], value, 18446744073709551615); <<value::64>> end).(Map.fetch!(model, :id)),
        ]
      else
        []
      end
    ]
  end

  @spec encode_gui_window_content_header(map()) :: iodata()
  def encode_gui_window_content_header(model), do: encode_gui_window_content_header(model, :gui_window_content, [:header])

  @spec encode_gui_window_content_header(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_content_header(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:window_id | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :window_id)),
      (fn value -> validate_uint!(command, [:flags | path], value, 255); <<value::8>> end).(Map.fetch!(model, :flags)),
      (fn value -> validate_uint!(command, [:cursor_row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :cursor_row)),
      (fn value -> validate_uint!(command, [:cursor_col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :cursor_col)),
      (fn value -> validate_uint!(command, [:cursor_shape | path], value, 255); <<value::8>> end).(Map.fetch!(model, :cursor_shape)),
      (fn value -> validate_uint!(command, [:scroll_left | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :scroll_left)),
      (fn value -> validate_uint!(command, [:content_epoch | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :content_epoch)),
    ]
  end

  @spec encode_gui_window_content_rows([term()]) :: iodata()
  def encode_gui_window_content_rows(items) when is_list(items), do: encode_gui_window_content_rows(items, :gui_window_content, [:rows])

  @spec encode_gui_window_content_rows([term()], atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_content_rows(items, command, path) when is_list(items) do
    count = Enum.count(items)
    validate_uint!(command, path, count, 4294967295)
    [<<count::32>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_row(value, command, [index | path]) end)]
  end

  @spec encode_gui_window_content_selection(map()) :: iodata()
  def encode_gui_window_content_selection(model), do: encode_gui_window_content_selection(model, :gui_window_content, [:selection])

  @spec encode_gui_window_content_selection(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_content_selection(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:type | path], value, 255); <<value::8>> end).(Map.fetch!(model, :type)),
      if Map.fetch!(model, :type) != 0 do
        [
          (fn value -> validate_uint!(command, [:start_row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :start_row)),
          (fn value -> validate_uint!(command, [:start_col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :start_col)),
          (fn value -> validate_uint!(command, [:end_row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :end_row)),
          (fn value -> validate_uint!(command, [:end_col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :end_col)),
        ]
      else
        []
      end
    ]
  end

  @spec encode_gui_window_content_search_matches([term()]) :: iodata()
  def encode_gui_window_content_search_matches(items) when is_list(items), do: encode_gui_window_content_search_matches(items, :gui_window_content, [:search_matches])

  @spec encode_gui_window_content_search_matches([term()], atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_content_search_matches(items, command, path) when is_list(items) do
    count = Enum.count(items)
    validate_uint!(command, path, count, 65535)
    [<<count::16>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_search_match(value, command, [index | path]) end)]
  end

  @spec encode_gui_window_content_diagnostic_ranges([term()]) :: iodata()
  def encode_gui_window_content_diagnostic_ranges(items) when is_list(items), do: encode_gui_window_content_diagnostic_ranges(items, :gui_window_content, [:diagnostic_ranges])

  @spec encode_gui_window_content_diagnostic_ranges([term()], atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_content_diagnostic_ranges(items, command, path) when is_list(items) do
    count = Enum.count(items)
    validate_uint!(command, path, count, 65535)
    [<<count::16>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_diagnostic_range(value, command, [index | path]) end)]
  end

  @spec encode_gui_window_content_document_highlights([term()]) :: iodata()
  def encode_gui_window_content_document_highlights(items) when is_list(items), do: encode_gui_window_content_document_highlights(items, :gui_window_content, [:document_highlights])

  @spec encode_gui_window_content_document_highlights([term()], atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_content_document_highlights(items, command, path) when is_list(items) do
    count = Enum.count(items)
    validate_uint!(command, path, count, 65535)
    [<<count::16>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_document_highlight(value, command, [index | path]) end)]
  end

  @spec encode_gui_window_content_annotations([term()]) :: iodata()
  def encode_gui_window_content_annotations(items) when is_list(items), do: encode_gui_window_content_annotations(items, :gui_window_content, [:annotations])

  @spec encode_gui_window_content_annotations([term()], atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_content_annotations(items, command, path) when is_list(items) do
    count = Enum.count(items)
    validate_uint!(command, path, count, 65535)
    [<<count::16>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_annotation(value, command, [index | path]) end)]
  end

  @spec encode_gui_window_content_geometry(map()) :: iodata()
  def encode_gui_window_content_geometry(model), do: encode_gui_window_content_geometry(model, :gui_window_content, [:geometry])

  @spec encode_gui_window_content_geometry(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_content_geometry(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:window_id | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :window_id)),
      encode_rect(Map.fetch!(model, :total_rect), command, [:total_rect | path]),
      encode_rect(Map.fetch!(model, :content_rect), command, [:content_rect | path]),
      encode_rect(Map.fetch!(model, :text_rect), command, [:text_rect | path]),
      encode_rect(Map.fetch!(model, :gutter_rect), command, [:gutter_rect | path]),
      encode_rect(Map.fetch!(model, :clip_rect), command, [:clip_rect | path]),
      (fn value -> validate_uint!(command, [:viewport_top | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :viewport_top)),
      (fn value -> validate_uint!(command, [:viewport_left | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :viewport_left)),
      (fn value -> validate_uint!(command, [:viewport_rows | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :viewport_rows)),
      (fn value -> validate_uint!(command, [:viewport_cols | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :viewport_cols)),
      (fn value -> validate_uint!(command, [:viewport_total_lines | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :viewport_total_lines)),
      (fn value -> validate_uint!(command, [:viewport_visual_row_offset | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :viewport_visual_row_offset)),
      (fn value -> validate_uint!(command, [:viewport_total_visual_rows | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :viewport_total_visual_rows)),
      (fn value -> validate_uint!(command, [:line_number_width | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :line_number_width)),
      (fn value -> validate_uint!(command, [:sign_col_width | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :sign_col_width)),
      (fn items -> count = Enum.count(items); validate_uint!(command, [:hit_regions | path], count, 255); [<<count::8>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_hit_region(value, command, [index | [:hit_regions | path]]) end)] end).(Map.fetch!(model, :hit_regions)),
    ]
  end

  @spec encode_gui_window_content_cursorline(map()) :: iodata()
  def encode_gui_window_content_cursorline(model), do: encode_gui_window_content_cursorline(model, :gui_window_content, [:cursorline])

  @spec encode_gui_window_content_cursorline(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_content_cursorline(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :row)),
      (fn value -> validate_uint!(command, [:bg | path], value, 16777215); <<value::24>> end).(Map.fetch!(model, :bg)),
    ]
  end

  @spec encode_gui_window_content_scroll_presentation(map()) :: iodata()
  def encode_gui_window_content_scroll_presentation(model), do: encode_gui_window_content_scroll_presentation(model, :gui_window_content, [:scroll_presentation])

  @spec encode_gui_window_content_scroll_presentation(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_content_scroll_presentation(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:window_id | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :window_id)),
      (fn value -> validate_uint!(command, [:flags | path], value, 255); <<value::8>> end).(Map.fetch!(model, :flags)),
      (fn value -> validate_uint!(command, [:anchor_top | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :anchor_top)),
      (fn value -> validate_uint!(command, [:anchor_left | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :anchor_left)),
      (fn value -> validate_uint!(command, [:anchor_visual_row_offset | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :anchor_visual_row_offset)),
      (fn value -> validate_uint!(command, [:visible_start_line | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :visible_start_line)),
      (fn value -> validate_uint!(command, [:visible_end_line | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :visible_end_line)),
      (fn value -> validate_uint!(command, [:overscan_start_line | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :overscan_start_line)),
      (fn value -> validate_uint!(command, [:overscan_end_line | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :overscan_end_line)),
      (fn value -> validate_uint!(command, [:content_epoch | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :content_epoch)),
      (fn value -> validate_uint!(command, [:layout_generation | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :layout_generation)),
      (fn value -> validate_uint!(command, [:scroll_seq | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :scroll_seq)),
      (fn value -> validate_uint!(command, [:horizontal_pan_ack | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :horizontal_pan_ack)),
      (fn value -> validate_uint!(command, [:horizontal_pan_limit | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :horizontal_pan_limit)),
    ]
  end

  @spec encode_gui_window_content_accessibility(map()) :: iodata()
  def encode_gui_window_content_accessibility(model), do: encode_gui_window_content_accessibility(model, :gui_window_content, [:accessibility])

  @spec encode_gui_window_content_accessibility(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_content_accessibility(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:generation | path], value, 18446744073709551615); <<value::64>> end).(Map.fetch!(model, :generation)),
      (fn value -> validate_uint!(command, [:cursor_row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :cursor_row)),
      (fn value -> validate_uint!(command, [:cursor_utf16 | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :cursor_utf16)),
      (fn items -> count = Enum.count(items); validate_uint!(command, [:selection_ranges | path], count, 65535); [<<count::16>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_accessibility_range(value, command, [index | [:selection_ranges | path]]) end)] end).(Map.fetch!(model, :selection_ranges)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:label | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :label)),
    ]
  end

  @spec encode_gui_status_bar_identity(map()) :: iodata()
  def encode_gui_status_bar_identity(model), do: encode_gui_status_bar_identity(model, :gui_status_bar, [:identity])

  @spec encode_gui_status_bar_identity(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_status_bar_identity(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:content_kind | path], value, 255); <<value::8>> end).(Map.fetch!(model, :content_kind)),
      (fn value -> validate_uint!(command, [:mode | path], value, 255); <<value::8>> end).(Map.fetch!(model, :mode)),
      (fn value -> validate_uint!(command, [:flags | path], value, 255); <<value::8>> end).(Map.fetch!(model, :flags)),
    ]
  end

  @spec encode_gui_status_bar_cursor(map()) :: iodata()
  def encode_gui_status_bar_cursor(model), do: encode_gui_status_bar_cursor(model, :gui_status_bar, [:cursor])

  @spec encode_gui_status_bar_cursor(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_status_bar_cursor(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:line | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :line)),
      (fn value -> validate_uint!(command, [:col | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :col)),
      (fn value -> validate_uint!(command, [:line_count | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :line_count)),
    ]
  end

  @spec encode_gui_status_bar_diagnostics(map()) :: iodata()
  def encode_gui_status_bar_diagnostics(model), do: encode_gui_status_bar_diagnostics(model, :gui_status_bar, [:diagnostics])

  @spec encode_gui_status_bar_diagnostics(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_status_bar_diagnostics(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:errors | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :errors)),
      (fn value -> validate_uint!(command, [:warnings | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :warnings)),
      (fn value -> validate_uint!(command, [:info | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :info)),
      (fn value -> validate_uint!(command, [:hints | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :hints)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:hint_text | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :hint_text)),
    ]
  end

  @spec encode_gui_status_bar_language(map()) :: iodata()
  def encode_gui_status_bar_language(model), do: encode_gui_status_bar_language(model, :gui_status_bar, [:language])

  @spec encode_gui_status_bar_language(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_status_bar_language(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:lsp_status | path], value, 255); <<value::8>> end).(Map.fetch!(model, :lsp_status)),
      (fn value -> validate_uint!(command, [:parser_status | path], value, 255); <<value::8>> end).(Map.fetch!(model, :parser_status)),
    ]
  end

  @spec encode_gui_status_bar_git(map()) :: iodata()
  def encode_gui_status_bar_git(model), do: encode_gui_status_bar_git(model, :gui_status_bar, [:git])

  @spec encode_gui_status_bar_git(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_status_bar_git(model, command, path) do
    [
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:branch | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :branch)),
      (fn value -> validate_uint!(command, [:added | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :added)),
      (fn value -> validate_uint!(command, [:modified | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :modified)),
      (fn value -> validate_uint!(command, [:deleted | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :deleted)),
    ]
  end

  @spec encode_gui_status_bar_file(map()) :: iodata()
  def encode_gui_status_bar_file(model), do: encode_gui_status_bar_file(model, :gui_status_bar, [:file])

  @spec encode_gui_status_bar_file(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_status_bar_file(model, command, path) do
    [
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:icon | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :icon)),
      (fn value -> validate_uint!(command, [:icon_color | path], value, 16777215); <<value::24>> end).(Map.fetch!(model, :icon_color)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:filename | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :filename)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:filetype | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :filetype)),
    ]
  end

  @spec encode_gui_status_bar_message(map()) :: iodata()
  def encode_gui_status_bar_message(model), do: encode_gui_status_bar_message(model, :gui_status_bar, [:message])

  @spec encode_gui_status_bar_message(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_status_bar_message(model, command, path) do
    [
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:text | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :text)),
    ]
  end

  @spec encode_gui_status_bar_recording(map()) :: iodata()
  def encode_gui_status_bar_recording(model), do: encode_gui_status_bar_recording(model, :gui_status_bar, [:recording])

  @spec encode_gui_status_bar_recording(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_status_bar_recording(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:macro_register | path], value, 255); <<value::8>> end).(Map.fetch!(model, :macro_register)),
    ]
  end

  @spec encode_gui_status_bar_indent(map()) :: iodata()
  def encode_gui_status_bar_indent(model), do: encode_gui_status_bar_indent(model, :gui_status_bar, [:indent])

  @spec encode_gui_status_bar_indent(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_status_bar_indent(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:indent_type | path], value, 255); <<value::8>> end).(Map.fetch!(model, :indent_type)),
      (fn value -> validate_uint!(command, [:indent_size | path], value, 255); <<value::8>> end).(Map.fetch!(model, :indent_size)),
    ]
  end

  @spec encode_gui_status_bar_modeline(map()) :: iodata()
  def encode_gui_status_bar_modeline(model), do: encode_gui_status_bar_modeline(model, :gui_status_bar, [:modeline])

  @spec encode_gui_status_bar_modeline(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_status_bar_modeline(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:format | path], value, 255); <<value::8>> end).(Map.fetch!(model, :format)),
      (fn items -> count = Enum.count(items); validate_uint!(command, [:left_segments | path], count, 65535); [<<count::16>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_modeline_segment(value, command, [index | [:left_segments | path]]) end)] end).(Map.fetch!(model, :left_segments)),
      (fn items -> count = Enum.count(items); validate_uint!(command, [:right_segments | path], count, 65535); [<<count::16>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_modeline_segment(value, command, [index | [:right_segments | path]]) end)] end).(Map.fetch!(model, :right_segments)),
    ]
  end

  @spec encode_gui_status_bar_selection(map()) :: iodata()
  def encode_gui_status_bar_selection(model), do: encode_gui_status_bar_selection(model, :gui_status_bar, [:selection])

  @spec encode_gui_status_bar_selection(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_status_bar_selection(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:selection_mode | path], value, 255); <<value::8>> end).(Map.fetch!(model, :selection_mode)),
      (fn value -> validate_uint!(command, [:selection_size | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :selection_size)),
    ]
  end

  @spec encode_gui_status_bar_workspace(map()) :: iodata()
  def encode_gui_status_bar_workspace(model), do: encode_gui_status_bar_workspace(model, :gui_status_bar, [:workspace])

  @spec encode_gui_status_bar_workspace(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_status_bar_workspace(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:workspace_id | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :workspace_id)),
      (fn value -> validate_uint!(command, [:kind | path], value, 255); <<value::8>> end).(Map.fetch!(model, :kind)),
      (fn value -> validate_uint!(command, [:status | path], value, 255); <<value::8>> end).(Map.fetch!(model, :status)),
      (fn value -> validate_uint!(command, [:flags | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :flags)),
      (fn value -> validate_uint!(command, [:draft_count | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :draft_count)),
      (fn value -> validate_uint!(command, [:conflict_count | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :conflict_count)),
      (fn value -> validate_uint!(command, [:running_background_count | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :running_background_count)),
      (fn value -> validate_uint!(command, [:attention_count | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :attention_count)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:label | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :label)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:icon | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :icon)),
    ]
  end

  @spec encode_gui_status_bar_pending_keys(map()) :: iodata()
  def encode_gui_status_bar_pending_keys(model), do: encode_gui_status_bar_pending_keys(model, :gui_status_bar, [:pending_keys])

  @spec encode_gui_status_bar_pending_keys(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_status_bar_pending_keys(model, command, path) do
    [
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:keys | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :keys)),
    ]
  end

  @spec encode_gui_status_bar_operation(map()) :: iodata()
  def encode_gui_status_bar_operation(model), do: encode_gui_status_bar_operation(model, :gui_status_bar, [:operation])

  @spec encode_gui_status_bar_operation(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_status_bar_operation(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:operation_id | path], value, 18446744073709551615); <<value::64>> end).(Map.fetch!(model, :operation_id)),
      (fn value -> validate_uint!(command, [:kind | path], value, 255); <<value::8>> end).(encode_operation_kind(Map.fetch!(model, :kind))),
      (fn value -> validate_uint!(command, [:status | path], value, 255); <<value::8>> end).(encode_operation_status(Map.fetch!(model, :status))),
      (fn value -> validate_uint!(command, [:flags | path], value, 255); <<value::8>> end).(Map.fetch!(model, :flags)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:message | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :message)),
      (fn value -> validate_uint!(command, [:queue_position | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :queue_position)),
      (fn value -> validate_uint!(command, [:queue_total | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :queue_total)),
      (fn value -> validate_uint!(command, [:progress_current | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :progress_current)),
      (fn value -> validate_uint!(command, [:progress_total | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :progress_total)),
    ]
  end

  @spec encode_gui_status_bar_review(map()) :: iodata()
  def encode_gui_status_bar_review(model), do: encode_gui_status_bar_review(model, :gui_status_bar, [:review])

  @spec encode_gui_status_bar_review(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_status_bar_review(model, command, path) do
    [
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:path | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :path)),
      (fn value -> validate_uint!(command, [:freshness | path], value, 255); <<value::8>> end).(Map.fetch!(model, :freshness)),
      (fn value -> validate_uint!(command, [:generation | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :generation)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:item_id | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :item_id)),
    ]
  end

  @spec encode_gui_status_bar_message_actions([term()]) :: iodata()
  def encode_gui_status_bar_message_actions(items) when is_list(items), do: encode_gui_status_bar_message_actions(items, :gui_status_bar, [:message_actions])

  @spec encode_gui_status_bar_message_actions([term()], atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_status_bar_message_actions(items, command, path) when is_list(items) do
    count = Enum.count(items)
    validate_uint!(command, path, count, 255)
    [<<count::8>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_empty_list_action(value, command, [index | path]) end)]
  end

  @spec encode_gui_gutter_window(map()) :: iodata()
  def encode_gui_gutter_window(model), do: encode_gui_gutter_window(model, :gui_gutter, [:window])

  @spec encode_gui_gutter_window(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_gutter_window(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:window_id | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :window_id)),
      (fn value -> validate_uint!(command, [:content_row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :content_row)),
      (fn value -> validate_uint!(command, [:content_col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :content_col)),
      (fn value -> validate_uint!(command, [:content_height | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :content_height)),
      (fn value -> validate_uint!(command, [:is_active | path], value, 255); <<value::8>> end).(Map.fetch!(model, :is_active)),
      (fn value -> validate_uint!(command, [:content_width | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :content_width)),
    ]
  end

  @spec encode_gui_gutter_config(map()) :: iodata()
  def encode_gui_gutter_config(model), do: encode_gui_gutter_config(model, :gui_gutter, [:config])

  @spec encode_gui_gutter_config(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_gutter_config(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:cursor_line | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :cursor_line)),
      (fn value -> validate_uint!(command, [:line_number_style | path], value, 255); <<value::8>> end).(Map.fetch!(model, :line_number_style)),
      (fn value -> validate_uint!(command, [:line_number_width | path], value, 255); <<value::8>> end).(Map.fetch!(model, :line_number_width)),
      (fn value -> validate_uint!(command, [:sign_col_width | path], value, 255); <<value::8>> end).(Map.fetch!(model, :sign_col_width)),
    ]
  end

  @spec encode_gui_gutter_entries([term()]) :: iodata()
  def encode_gui_gutter_entries(items) when is_list(items), do: encode_gui_gutter_entries(items, :gui_gutter, [:entries])

  @spec encode_gui_gutter_entries([term()], atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_gutter_entries(items, command, path) when is_list(items) do
    count = Enum.count(items)
    validate_uint!(command, path, count, 65535)
    [<<count::16>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_gutter_entry(value, command, [index | path]) end)]
  end

  @spec encode_gui_gutter_resident(map()) :: iodata()
  def encode_gui_gutter_resident(model), do: encode_gui_gutter_resident(model, :gui_gutter, [:resident])

  @spec encode_gui_gutter_resident(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_gutter_resident(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:content_epoch | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :content_epoch)),
      (fn value -> validate_uint!(command, [:line_count | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :line_count)),
      (fn value -> validate_uint!(command, [:retain_overrides | path], value, 255); <<value::8>> end).(Map.fetch!(model, :retain_overrides)),
    ]
  end

  @spec encode_gui_gutter_resident_overrides([term()]) :: iodata()
  def encode_gui_gutter_resident_overrides(items) when is_list(items), do: encode_gui_gutter_resident_overrides(items, :gui_gutter, [:resident_overrides])

  @spec encode_gui_gutter_resident_overrides([term()], atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_gutter_resident_overrides(items, command, path) when is_list(items) do
    count = Enum.count(items)
    validate_uint!(command, path, count, 65535)
    [<<count::16>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_gutter_entry(value, command, [index | path]) end)]
  end

  @spec encode_gui_window_viewport_delta_header(map()) :: iodata()
  def encode_gui_window_viewport_delta_header(model), do: encode_gui_window_viewport_delta_header(model, :gui_window_viewport_delta, [:header])

  @spec encode_gui_window_viewport_delta_header(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_viewport_delta_header(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:window_id | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :window_id)),
      (fn value -> validate_uint!(command, [:content_epoch | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :content_epoch)),
      (fn value -> validate_uint!(command, [:flags | path], value, 255); <<value::8>> end).(Map.fetch!(model, :flags)),
      (fn value -> validate_uint!(command, [:cursor_row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :cursor_row)),
      (fn value -> validate_uint!(command, [:cursor_col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :cursor_col)),
      (fn value -> validate_uint!(command, [:cursor_shape | path], value, 255); <<value::8>> end).(Map.fetch!(model, :cursor_shape)),
      (fn value -> validate_uint!(command, [:scroll_left | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :scroll_left)),
    ]
  end

  @spec encode_gui_window_viewport_delta_rows([term()]) :: iodata()
  def encode_gui_window_viewport_delta_rows(items) when is_list(items), do: encode_gui_window_viewport_delta_rows(items, :gui_window_viewport_delta, [:rows])

  @spec encode_gui_window_viewport_delta_rows([term()], atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_viewport_delta_rows(items, command, path) when is_list(items) do
    count = Enum.count(items)
    validate_uint!(command, path, count, 4294967295)
    [<<count::32>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_row(value, command, [index | path]) end)]
  end

  @spec encode_gui_window_viewport_delta_accessibility(map()) :: iodata()
  def encode_gui_window_viewport_delta_accessibility(model), do: encode_gui_window_viewport_delta_accessibility(model, :gui_window_viewport_delta, [:accessibility])

  @spec encode_gui_window_viewport_delta_accessibility(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_viewport_delta_accessibility(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:generation | path], value, 18446744073709551615); <<value::64>> end).(Map.fetch!(model, :generation)),
      (fn value -> validate_uint!(command, [:cursor_row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :cursor_row)),
      (fn value -> validate_uint!(command, [:cursor_utf16 | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :cursor_utf16)),
      (fn items -> count = Enum.count(items); validate_uint!(command, [:selection_ranges | path], count, 65535); [<<count::16>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_accessibility_range(value, command, [index | [:selection_ranges | path]]) end)] end).(Map.fetch!(model, :selection_ranges)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:label | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :label)),
    ]
  end

  @spec encode_gui_window_rows_delta_header(map()) :: iodata()
  def encode_gui_window_rows_delta_header(model), do: encode_gui_window_rows_delta_header(model, :gui_window_rows_delta, [:header])

  @spec encode_gui_window_rows_delta_header(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_rows_delta_header(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:window_id | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :window_id)),
      (fn value -> validate_uint!(command, [:content_epoch | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :content_epoch)),
      (fn value -> validate_uint!(command, [:flags | path], value, 255); <<value::8>> end).(Map.fetch!(model, :flags)),
      (fn value -> validate_uint!(command, [:cursor_row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :cursor_row)),
      (fn value -> validate_uint!(command, [:cursor_col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :cursor_col)),
      (fn value -> validate_uint!(command, [:cursor_shape | path], value, 255); <<value::8>> end).(Map.fetch!(model, :cursor_shape)),
      (fn value -> validate_uint!(command, [:scroll_left | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :scroll_left)),
    ]
  end

  @spec encode_gui_window_rows_delta_rows([term()]) :: iodata()
  def encode_gui_window_rows_delta_rows(items) when is_list(items), do: encode_gui_window_rows_delta_rows(items, :gui_window_rows_delta, [:rows])

  @spec encode_gui_window_rows_delta_rows([term()], atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_rows_delta_rows(items, command, path) when is_list(items) do
    count = Enum.count(items)
    validate_uint!(command, path, count, 4294967295)
    [<<count::32>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_row(value, command, [index | path]) end)]
  end

  @spec encode_gui_window_rows_delta_accessibility(map()) :: iodata()
  def encode_gui_window_rows_delta_accessibility(model), do: encode_gui_window_rows_delta_accessibility(model, :gui_window_rows_delta, [:accessibility])

  @spec encode_gui_window_rows_delta_accessibility(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_window_rows_delta_accessibility(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:generation | path], value, 18446744073709551615); <<value::64>> end).(Map.fetch!(model, :generation)),
      (fn value -> validate_uint!(command, [:cursor_row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :cursor_row)),
      (fn value -> validate_uint!(command, [:cursor_utf16 | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :cursor_utf16)),
      (fn items -> count = Enum.count(items); validate_uint!(command, [:selection_ranges | path], count, 65535); [<<count::16>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_accessibility_range(value, command, [index | [:selection_ranges | path]]) end)] end).(Map.fetch!(model, :selection_ranges)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:label | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :label)),
    ]
  end

  @spec encode_gui_surface_layout_placements([term()]) :: iodata()
  def encode_gui_surface_layout_placements(items) when is_list(items), do: encode_gui_surface_layout_placements(items, :gui_surface_layout, [:placements])

  @spec encode_gui_surface_layout_placements([term()], atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_surface_layout_placements(items, command, path) when is_list(items) do
    count = Enum.count(items)
    validate_uint!(command, path, count, 65535)
    [<<count::16>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_surface_placement(value, command, [index | path]) end)]
  end

  @spec encode_gui_picker_header(map()) :: iodata()
  def encode_gui_picker_header(model), do: encode_gui_picker_header(model, :gui_picker, [:header])

  @spec encode_gui_picker_header(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_picker_header(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
      (fn value -> validate_uint!(command, [:selected_index | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :selected_index)),
      (fn value -> validate_uint!(command, [:filtered_count | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :filtered_count)),
      (fn value -> validate_uint!(command, [:total_count | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :total_count)),
      (fn value -> validate_uint!(command, [:has_preview | path], value, 255); <<value::8>> end).(Map.fetch!(model, :has_preview)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:title | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :title)),
      (fn value -> validate_uint!(command, [:marked_count | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :marked_count)),
      (fn value -> validate_uint!(command, [:activation_generation | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :activation_generation)),
    ]
  end

  @spec encode_gui_picker_query(map()) :: iodata()
  def encode_gui_picker_query(model), do: encode_gui_picker_query(model, :gui_picker, [:query])

  @spec encode_gui_picker_query(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_picker_query(model, command, path) do
    [
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:text | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :text)),
      (fn value -> validate_uint!(command, [:generation | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :generation)),
      (fn value -> validate_uint!(command, [:acknowledged_edit_seq | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :acknowledged_edit_seq)),
    ]
  end

  @spec encode_gui_picker_items([term()]) :: iodata()
  def encode_gui_picker_items(items) when is_list(items), do: encode_gui_picker_items(items, :gui_picker, [:items])

  @spec encode_gui_picker_items([term()], atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_picker_items(items, command, path) when is_list(items) do
    count = Enum.count(items)
    validate_uint!(command, path, count, 65535)
    [<<count::16>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_picker_item(value, command, [index | path]) end)]
  end

  @spec encode_gui_picker_action_menu(map()) :: iodata()
  def encode_gui_picker_action_menu(model), do: encode_gui_picker_action_menu(model, :gui_picker, [:action_menu])

  @spec encode_gui_picker_action_menu(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_picker_action_menu(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
      if Map.fetch!(model, :visible) == 1 do
        [
          (fn value -> validate_uint!(command, [:selected_index | path], value, 255); <<value::8>> end).(Map.fetch!(model, :selected_index)),
          (fn items -> count = Enum.count(items); validate_uint!(command, [:actions | path], count, 255); [<<count::8>> | Enum.map(Stream.with_index(items), fn {value, index} -> (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [index | [:actions | path]], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(value) end)] end).(Map.fetch!(model, :actions)),
          (fn items -> count = Enum.count(items); validate_uint!(command, [:activation_ids | path], count, 255); [<<count::8>> | Enum.map(Stream.with_index(items), fn {value, index} -> (fn value -> validate_uint!(command, [index | [:activation_ids | path]], value, 4294967295); <<value::32>> end).(value) end)] end).(Map.fetch!(model, :activation_ids)),
        ]
      else
        []
      end
    ]
  end

  @spec encode_gui_picker_mode_prefix(map()) :: iodata()
  def encode_gui_picker_mode_prefix(model), do: encode_gui_picker_mode_prefix(model, :gui_picker, [:mode_prefix])

  @spec encode_gui_picker_mode_prefix(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_picker_mode_prefix(model, command, path) do
    [
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:text | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :text)),
    ]
  end

  @spec encode_gui_picker_load_status(map()) :: iodata()
  def encode_gui_picker_load_status(model), do: encode_gui_picker_load_status(model, :gui_picker, [:load_status])

  @spec encode_gui_picker_load_status(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_picker_load_status(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:status | path], value, 255); <<value::8>> end).(Map.fetch!(model, :status)),
      if Map.fetch!(model, :status) == 2 do
        [
          (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:message | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :message)),
        ]
      else
        []
      end
    ]
  end

  @spec encode_gui_picker_empty(map()) :: iodata()
  def encode_gui_picker_empty(model), do: encode_gui_picker_empty(model, :gui_picker, [:empty])

  @spec encode_gui_picker_empty(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_picker_empty(model, command, path) do
    [
      encode_empty_list(Map.fetch!(model, :empty), command, [:empty | path]),
      (fn value -> validate_uint!(command, [:list_keys | path], value, 255); <<value::8>> end).(Map.fetch!(model, :list_keys)),
    ]
  end

  @spec encode_gui_picker_movement_keys([term()]) :: iodata()
  def encode_gui_picker_movement_keys(items) when is_list(items), do: encode_gui_picker_movement_keys(items, :gui_picker, [:movement_keys])

  @spec encode_gui_picker_movement_keys([term()], atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_picker_movement_keys(items, command, path) when is_list(items) do
    count = Enum.count(items)
    validate_uint!(command, path, count, 255)
    [<<count::8>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_picker_movement_key(value, command, [index | path]) end)]
  end

  @spec encode_gui_agent_chat_header(map()) :: iodata()
  def encode_gui_agent_chat_header(model), do: encode_gui_agent_chat_header(model, :gui_agent_chat, [:header])

  @spec encode_gui_agent_chat_header(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_agent_chat_header(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
      (fn value -> validate_uint!(command, [:status | path], value, 255); <<value::8>> end).(Map.fetch!(model, :status)),
    ]
  end

  @spec encode_gui_agent_chat_draft_attachments(map()) :: iodata()
  def encode_gui_agent_chat_draft_attachments(model), do: encode_gui_agent_chat_draft_attachments(model, :gui_agent_chat, [:draft_attachments])

  @spec encode_gui_agent_chat_draft_attachments(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_agent_chat_draft_attachments(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:count | path], value, 255); <<value::8>> end).(Map.fetch!(model, :count)),
      (fn value -> validate_uint!(command, [:offer | path], value, 18446744073709551615); <<value::64>> end).(Map.fetch!(model, :offer)),
    ]
  end

  @spec encode_gui_agent_chat_prompt_presentation(map()) :: iodata()
  def encode_gui_agent_chat_prompt_presentation(model), do: encode_gui_agent_chat_prompt_presentation(model, :gui_agent_chat, [:prompt_presentation])

  @spec encode_gui_agent_chat_prompt_presentation(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_agent_chat_prompt_presentation(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:generation | path], value, 18446744073709551615); <<value::64>> end).(Map.fetch!(model, :generation)),
    ]
  end

  @spec encode_gui_agent_chat_queue_target(map()) :: iodata()
  def encode_gui_agent_chat_queue_target(model), do: encode_gui_agent_chat_queue_target(model, :gui_agent_chat, [:queue_target])

  @spec encode_gui_agent_chat_queue_target(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_agent_chat_queue_target(model, command, path) do
    [
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:session_id | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :session_id)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:request_id | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :request_id)),
      (fn value -> validate_uint!(command, [:sequence | path], value, 18446744073709551615); <<value::64>> end).(Map.fetch!(model, :sequence)),
    ]
  end

  @spec encode_gui_agent_chat_lifecycle(map()) :: iodata()
  def encode_gui_agent_chat_lifecycle(model), do: encode_gui_agent_chat_lifecycle(model, :gui_agent_chat, [:lifecycle])

  @spec encode_gui_agent_chat_lifecycle(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_agent_chat_lifecycle(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:kind | path], value, 255); <<value::8>> end).(Map.fetch!(model, :kind)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:reason | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :reason)),
      (fn value -> validate_uint!(command, [:remedy | path], value, 255); <<value::8>> end).(Map.fetch!(model, :remedy)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:action_label | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :action_label)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:key_hint | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :key_hint)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:headline | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :headline)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:note | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :note)),
    ]
  end

  @spec encode_gui_picker_preview_header(map()) :: iodata()
  def encode_gui_picker_preview_header(model), do: encode_gui_picker_preview_header(model, :gui_picker_preview, [:header])

  @spec encode_gui_picker_preview_header(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_picker_preview_header(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
      (fn value -> validate_uint!(command, [:kind | path], value, 255); <<value::8>> end).(Map.fetch!(model, :kind)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:title | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :title)),
    ]
  end

  @spec encode_gui_tab_bar(map()) :: iodata()
  def encode_gui_tab_bar(model), do: encode_gui_tab_bar(model, :gui_tab_bar, [])

  @spec encode_gui_tab_bar(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_tab_bar(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:active_index | path], value, 255); <<value::8>> end).(Map.fetch!(model, :active_index)),
      (fn value -> validate_uint!(command, [:tab_count | path], value, 255); <<value::8>> end).(Map.fetch!(model, :tab_count)),
    ]
  end

  @spec encode_gui_theme(map()) :: iodata()
  def encode_gui_theme(model), do: encode_gui_theme(model, :gui_theme, [])

  @spec encode_gui_theme(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_theme(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:color_count | path], value, 255); <<value::8>> end).(Map.fetch!(model, :color_count)),
    ]
  end

  @spec encode_gui_breadcrumb(map()) :: iodata()
  def encode_gui_breadcrumb(model), do: encode_gui_breadcrumb(model, :gui_breadcrumb, [])

  @spec encode_gui_breadcrumb(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_breadcrumb(model, command, path) do
    [
      (fn items -> count = Enum.count(items); validate_uint!(command, [:segments | path], count, 255); [<<count::8>> | Enum.map(Stream.with_index(items), fn {value, index} -> (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [index | [:segments | path]], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(value) end)] end).(Map.fetch!(model, :segments)),
    ]
  end

  @spec encode_gui_completion(map()) :: iodata()
  def encode_gui_completion(model), do: encode_gui_completion(model, :gui_completion, [])

  @spec encode_gui_completion(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_completion(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
      if Map.fetch!(model, :visible) == 1 do
        [
          (fn value -> validate_uint!(command, [:cursor_row | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :cursor_row)),
          (fn value -> validate_uint!(command, [:cursor_col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :cursor_col)),
          (fn value -> validate_uint!(command, [:selected_offset | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :selected_offset)),
          (fn items -> count = Enum.count(items); validate_uint!(command, [:items | path], count, 65535); [<<count::16>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_completion_item(value, command, [index | [:items | path]]) end)] end).(Map.fetch!(model, :items)),
          (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:documentation | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :documentation)),
          (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:selected_item_id | path], byte_size(bin), 255); <<byte_size(bin)::8, bin::binary>> end).(Map.fetch!(model, :selected_item_id)),
          (fn value -> validate_uint!(command, [:total_count | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :total_count)),
          (fn value -> validate_uint!(command, [:matched_count | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :matched_count)),
          (fn value -> validate_uint!(command, [:incomplete | path], value, 255); <<value::8>> end).(Map.fetch!(model, :incomplete)),
          (fn value -> validate_uint!(command, [:generation | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :generation)),
        ]
      else
        []
      end
    ]
  end

  @spec encode_gui_which_key(map()) :: iodata()
  def encode_gui_which_key(model), do: encode_gui_which_key(model, :gui_which_key, [])

  @spec encode_gui_which_key(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_which_key(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
    ]
  end

  @spec encode_gui_focus_owner(map()) :: iodata()
  def encode_gui_focus_owner(model), do: encode_gui_focus_owner(model, :gui_focus_owner, [])

  @spec encode_gui_focus_owner(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_focus_owner(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:responder | path], value, 255); <<value::8>> end).(Map.fetch!(model, :responder)),
      (fn value -> validate_uint!(command, [:surface | path], value, 255); <<value::8>> end).(Map.fetch!(model, :surface)),
      (fn value -> validate_uint!(command, [:window_id | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :window_id)),
      (fn value -> validate_uint!(command, [:generation | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :generation)),
    ]
  end

  @spec encode_gui_minibuffer(map()) :: iodata()
  def encode_gui_minibuffer(model), do: encode_gui_minibuffer(model, :gui_minibuffer, [])

  @spec encode_gui_minibuffer(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_minibuffer(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
    ]
  end

  @spec encode_gui_hover_popup(map()) :: iodata()
  def encode_gui_hover_popup(model), do: encode_gui_hover_popup(model, :gui_hover_popup, [])

  @spec encode_gui_hover_popup(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_hover_popup(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
    ]
  end

  @spec encode_gui_signature_help(map()) :: iodata()
  def encode_gui_signature_help(model), do: encode_gui_signature_help(model, :gui_signature_help, [])

  @spec encode_gui_signature_help(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_signature_help(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
    ]
  end

  @spec encode_gui_float_popup(map()) :: iodata()
  def encode_gui_float_popup(model), do: encode_gui_float_popup(model, :gui_float_popup, [])

  @spec encode_gui_float_popup(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_float_popup(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
    ]
  end

  @spec encode_gui_split_separators(map()) :: iodata()
  def encode_gui_split_separators(model), do: encode_gui_split_separators(model, :gui_split_separators, [])

  @spec encode_gui_split_separators(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_split_separators(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:bg | path], value, 16777215); <<value::24>> end).(Map.fetch!(model, :bg)),
      (fn value -> validate_uint!(command, [:vertical_count | path], value, 255); <<value::8>> end).(Map.fetch!(model, :vertical_count)),
    ]
  end

  @spec encode_gui_git_status(map()) :: iodata()
  def encode_gui_git_status(model), do: encode_gui_git_status(model, :gui_git_status, [])

  @spec encode_gui_git_status(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_git_status(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:repo_state | path], value, 255); <<value::8>> end).(encode_git_repo_state(Map.fetch!(model, :repo_state))),
      (fn value -> validate_uint!(command, [:syncing | path], value, 255); <<value::8>> end).(Map.fetch!(model, :syncing)),
      (fn value -> validate_uint!(command, [:ahead | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :ahead)),
      (fn value -> validate_uint!(command, [:behind | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :behind)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:branch | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :branch)),
      (fn items -> count = Enum.count(items); validate_uint!(command, [:entries | path], count, 65535); [<<count::16>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_git_status_entry(value, command, [index | [:entries | path]]) end)] end).(Map.fetch!(model, :entries)),
      encode_git_toast(Map.fetch!(model, :toast), command, [:toast | path]),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:entry_base_path | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :entry_base_path)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:last_commit_message | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :last_commit_message)),
      (fn value -> validate_uint!(command, [:stash_count | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :stash_count)),
      (fn value -> validate_uint!(command, [:terminal_cursor | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :terminal_cursor)),
      (fn value -> validate_uint!(command, [:terminal_collapsed | path], value, 255); <<value::8>> end).(Map.fetch!(model, :terminal_collapsed)),
      (fn value -> validate_uint!(command, [:panel_id | path], value, 18446744073709551615); <<value::64>> end).(Map.fetch!(model, :panel_id)),
      (fn value -> validate_uint!(command, [:commit_target_id | path], value, 18446744073709551615); <<value::64>> end).(Map.fetch!(model, :commit_target_id)),
      encode_empty_list(Map.fetch!(model, :empty), command, [:empty | path]),
    ]
  end

  @spec encode_gui_bottom_panel(map()) :: iodata()
  def encode_gui_bottom_panel(model), do: encode_gui_bottom_panel(model, :gui_bottom_panel, [])

  @spec encode_gui_bottom_panel(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_bottom_panel(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
    ]
  end

  @spec encode_gui_agent_context(map()) :: iodata()
  def encode_gui_agent_context(model), do: encode_gui_agent_context(model, :gui_agent_context, [])

  @spec encode_gui_agent_context(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_agent_context(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:payload_len | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :payload_len)),
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:task | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :task)),
      (fn value -> validate_uint!(command, [:dispatch_timestamp | path], value, 18446744073709551615); <<value::64>> end).(Map.fetch!(model, :dispatch_timestamp)),
      (fn value -> validate_uint!(command, [:status | path], value, 255); <<value::8>> end).(Map.fetch!(model, :status)),
      (fn value -> validate_uint!(command, [:can_approve | path], value, 255); <<value::8>> end).(Map.fetch!(model, :can_approve)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:active_action | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :active_action)),
      (fn value -> validate_uint!(command, [:tool_count | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :tool_count)),
      (fn value -> validate_uint!(command, [:file_count | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :file_count)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:review_hint | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :review_hint)),
      (fn items -> count = Enum.count(items); validate_uint!(command, [:todos | path], count, 255); [<<count::8>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_agent_todo(value, command, [index | [:todos | path]]) end)] end).(Map.fetch!(model, :todos)),
    ]
  end

  @spec encode_gui_gutter_sep(map()) :: iodata()
  def encode_gui_gutter_sep(model), do: encode_gui_gutter_sep(model, :gui_gutter_sep, [])

  @spec encode_gui_gutter_sep(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_gutter_sep(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :col)),
      (fn value -> validate_uint!(command, [:bg | path], value, 16777215); <<value::24>> end).(Map.fetch!(model, :bg)),
    ]
  end

  @spec encode_gui_cursorline(map()) :: iodata()
  def encode_gui_cursorline(model), do: encode_gui_cursorline(model, :gui_cursorline, [])

  @spec encode_gui_cursorline(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_cursorline(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:col | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :col)),
      (fn value -> validate_uint!(command, [:bg | path], value, 16777215); <<value::24>> end).(Map.fetch!(model, :bg)),
    ]
  end

  @spec encode_gui_search_state(map()) :: iodata()
  def encode_gui_search_state(model), do: encode_gui_search_state(model, :gui_search_state, [])

  @spec encode_gui_search_state(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_search_state(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:active | path], value, 255); <<value::8>> end).(Map.fetch!(model, :active)),
      (fn value -> validate_uint!(command, [:match_count | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :match_count)),
      (fn value -> validate_uint!(command, [:current_index | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :current_index)),
      (fn value -> validate_uint!(command, [:flags | path], value, 255); <<value::8>> end).(Map.fetch!(model, :flags)),
      (fn value -> bin = :erlang.iolist_to_binary([value]); validate_uint!(command, [:query | path], byte_size(bin), 65535); <<byte_size(bin)::16, bin::binary>> end).(Map.fetch!(model, :query)),
      (fn value -> validate_uint!(command, [:session_id | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :session_id)),
      (fn value -> validate_uint!(command, [:acknowledged_edit_seq | path], value, 4294967295); <<value::32>> end).(Map.fetch!(model, :acknowledged_edit_seq)),
      (fn value -> validate_uint!(command, [:status | path], value, 255); <<value::8>> end).(Map.fetch!(model, :status)),
    ]
  end

  @spec encode_gui_edit_timeline(map()) :: iodata()
  def encode_gui_edit_timeline(model), do: encode_gui_edit_timeline(model, :gui_edit_timeline, [])

  @spec encode_gui_edit_timeline(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_edit_timeline(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
      (fn value -> validate_uint!(command, [:viewing_index | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :viewing_index)),
      (fn items -> count = Enum.count(items); validate_uint!(command, [:entries | path], count, 255); [<<count::8>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_edit_timeline_entry(value, command, [index | [:entries | path]]) end)] end).(Map.fetch!(model, :entries)),
      (fn items -> count = Enum.count(items); validate_uint!(command, [:files | path], count, 255); [<<count::8>> | Enum.map(Stream.with_index(items), fn {value, index} -> encode_edit_timeline_file(value, command, [index | [:files | path]]) end)] end).(Map.fetch!(model, :files)),
    ]
  end

  @spec encode_gui_workspaces(map()) :: iodata()
  def encode_gui_workspaces(model), do: encode_gui_workspaces(model, :gui_workspaces, [])

  @spec encode_gui_workspaces(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_workspaces(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
      (fn value -> validate_uint!(command, [:active_workspace_id | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :active_workspace_id)),
      (fn value -> validate_uint!(command, [:mode | path], value, 255); <<value::8>> end).(Map.fetch!(model, :mode)),
      (fn value -> validate_uint!(command, [:flags | path], value, 255); <<value::8>> end).(Map.fetch!(model, :flags)),
      (fn value -> validate_uint!(command, [:workspace_count | path], value, 255); <<value::8>> end).(Map.fetch!(model, :workspace_count)),
    ]
  end

  @spec encode_gui_notifications(map()) :: iodata()
  def encode_gui_notifications(model), do: encode_gui_notifications(model, :gui_notifications, [])

  @spec encode_gui_notifications(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_notifications(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
      (fn value -> validate_uint!(command, [:notification_count | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :notification_count)),
    ]
  end

  @spec encode_gui_sidebars(map()) :: iodata()
  def encode_gui_sidebars(model), do: encode_gui_sidebars(model, :gui_sidebars, [])

  @spec encode_gui_sidebars(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_sidebars(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
      (fn value -> validate_uint!(command, [:sidebar_count | path], value, 65535); <<value::16>> end).(Map.fetch!(model, :sidebar_count)),
    ]
  end

  @spec encode_gui_extension_overlay(map()) :: iodata()
  def encode_gui_extension_overlay(model), do: encode_gui_extension_overlay(model, :gui_extension_overlay, [])

  @spec encode_gui_extension_overlay(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_extension_overlay(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:entry_count | path], value, 255); <<value::8>> end).(Map.fetch!(model, :entry_count)),
    ]
  end

  @spec encode_gui_extension_panel(map()) :: iodata()
  def encode_gui_extension_panel(model), do: encode_gui_extension_panel(model, :gui_extension_panel, [])

  @spec encode_gui_extension_panel(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_extension_panel(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:panel_count | path], value, 255); <<value::8>> end).(Map.fetch!(model, :panel_count)),
    ]
  end

  @spec encode_gui_file_tree(map()) :: iodata()
  def encode_gui_file_tree(model), do: encode_gui_file_tree(model, :gui_file_tree, [])

  @spec encode_gui_file_tree(map(), atom(), [atom() | non_neg_integer()]) :: iodata()
  defp encode_gui_file_tree(model, command, path) do
    [
      (fn value -> validate_uint!(command, [:visible | path], value, 255); <<value::8>> end).(Map.fetch!(model, :visible)),
      (fn value -> validate_uint!(command, [:flags | path], value, 255); <<value::8>> end).(Map.fetch!(model, :flags)),
      (fn value -> validate_uint!(command, [:status | path], value, 255); <<value::8>> end).(Map.fetch!(model, :status)),
    ]
  end

  @spec validate_uint!(atom(), [atom() | non_neg_integer()], term(), non_neg_integer()) :: :ok
  defp validate_uint!(_command, _path, value, max)
       when is_integer(value) and value >= 0 and value <= max,
       do: :ok

  defp validate_uint!(command, reverse_path, value, max) do
    field_path = Enum.reverse(reverse_path)
    raise EncodingError,
      command: command,
      field: Enum.find(reverse_path, &is_atom/1),
      field_path: field_path,
      actual: value,
      min: 0,
      max: max
  end

end
