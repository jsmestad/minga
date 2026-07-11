defmodule Minga.Credo.NoLossyGuiEncoderCheck do
  @moduledoc false

  use Credo.Check,
    id: "EX9014",
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      GUI adapter encoders must not silently clamp, truncate, or drop data to fit a wire field. Use Minga.Frontend.Adapter.GUI.Wire.Writer so an out-of-range value raises EncodingError with command and field metadata. See #2737.
      """
    ]

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source_file, params) do
    if gui_encoder_file?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&find_lossy_encoder_call(&1, &2, issue_meta))
      |> List.flatten()
    else
      []
    end
  end

  defp find_lossy_encoder_call({:min, meta, _args} = ast, issues, issue_meta),
    do: issue(ast, issues, issue_meta, meta, "min")

  defp find_lossy_encoder_call({:&&&, meta, _args} = ast, issues, issue_meta),
    do: issue(ast, issues, issue_meta, meta, "&&&")

  defp find_lossy_encoder_call({:utf8_prefix_bytes, meta, _args} = ast, issues, issue_meta),
    do: issue(ast, issues, issue_meta, meta, "utf8_prefix_bytes")

  defp find_lossy_encoder_call({:<<>>, _, segments} = ast, issues, issue_meta) do
    issues = Enum.reduce(segments, issues, &dynamic_bounded_segment_issue(&1, &2, issue_meta))
    {ast, issues}
  end

  defp find_lossy_encoder_call(
         {{:., _, [module, function]}, meta, _args} = ast,
         issues,
         issue_meta
       )
       when function in [
              :bounded_entries,
              :clamp_u8,
              :clamp_u16,
              :clamp_u32,
              :encode_section,
              :encode_string8,
              :encode_string16,
              :reduce_while,
              :rgb,
              :take,
              :utf8_prefix_bytes,
              :validate_uint!
            ] do
    if lossy_remote_call?(alias_name(module), function) do
      issue(ast, issues, issue_meta, meta, Atom.to_string(function))
    else
      {ast, issues}
    end
  end

  defp find_lossy_encoder_call(ast, issues, _issue_meta), do: {ast, issues}

  defp dynamic_bounded_segment_issue(
         {:"::", meta, [value, {:-, _, [{:signed, _, _}, 32]}]},
         issues,
         issue_meta
       ) do
    dynamic_bounded_segment_issue(value, issues, issue_meta, meta, "::32-signed")
  end

  defp dynamic_bounded_segment_issue({:"::", meta, [value, width]}, issues, issue_meta)
       when width in [8, 16, 24, 32, 64] do
    dynamic_bounded_segment_issue(value, issues, issue_meta, meta, "::#{width}")
  end

  defp dynamic_bounded_segment_issue(_segment, issues, _issue_meta), do: issues

  defp dynamic_bounded_segment_issue(value, issues, issue_meta, meta, trigger) do
    if dynamic_wire_value?(value) do
      {_ast, issues} = issue(value, issues, issue_meta, meta, trigger)
      issues
    else
      issues
    end
  end

  defp dynamic_wire_value?(value) when is_integer(value), do: false
  defp dynamic_wire_value?({:@, _, _}), do: false
  defp dynamic_wire_value?(_value), do: true

  defp issue(ast, issues, issue_meta, meta, trigger) do
    issue =
      format_issue(issue_meta,
        message:
          "GUI encoders must use Wire.Writer for data-derived bounded fields, not #{trigger}. See #2737.",
        trigger: trigger,
        line_no: meta[:line]
      )

    {ast, [issue | issues]}
  end

  defp alias_name({:__aliases__, _, names}), do: List.last(names)
  defp alias_name(_), do: nil

  defp lossy_remote_call?(:Enum, function) when function in [:reduce_while, :take], do: true

  defp lossy_remote_call?(module, function)
       when module in [:Wire, :Encoding, :AgentChatMessageCodec] and
              function in [
                :bounded_entries,
                :clamp_u8,
                :clamp_u16,
                :clamp_u32,
                :utf8_prefix_bytes,
                :validate_uint!
              ],
       do: true

  defp lossy_remote_call?(:Wire, function)
       when function in [:encode_section, :encode_string8, :encode_string16, :rgb],
       do: true

  defp lossy_remote_call?(_module, _function), do: false

  defp gui_encoder_file?(%SourceFile{} = source_file) do
    filename = Path.expand(source_file.filename)

    String.contains?(filename, "/lib/minga/frontend/adapter/gui/") and
      not String.ends_with?(filename, "/lib/minga/frontend/adapter/gui/wire.ex") and
      not String.contains?(filename, "/lib/minga/frontend/adapter/gui/wire/")
  end
end
