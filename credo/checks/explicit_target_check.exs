defmodule Minga.Credo.ExplicitTargetCheck do
  @moduledoc """
  Keeps explicitly targeted workflows on their named subject and rejects index-only GUI activations.

  A clause that receives a Target must not rediscover its subject through active editor state. Binary lengths are framing, not positions; existing 16-bit identity contracts require a documented exemption.
  """

  use Credo.Check,
    id: "EX9015",
    base_priority: :high,
    category: :design,
    param_defaults: [identity_opcodes: []],
    explanations: [
      check: "Thread the explicit target through the operation. GUI activations must carry identity, not a bare list position.",
      params: [identity_opcodes: "At most ten {subopcode_attribute, reason} exemptions for existing 16-bit identity contracts."]
    ]

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source, params) do
    meta = IssueMeta.for(source, params)
    exemptions = Params.get(params, :identity_opcodes, __MODULE__)
    validate_exemptions!(exemptions)

    source
    |> Credo.Code.prewalk(&inspect_module(&1, &2, meta, exemptions))
    |> List.flatten()
  end

  defp inspect_module({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]} = ast, issues, meta, exemptions) do
    if scoped?(parts) do
      {_body, found} = Macro.prewalk(body, [], &inspect_clause(&1, &2, meta, exemptions))
      {ast, found ++ issues}
    else
      {ast, issues}
    end
  end

  defp inspect_module(ast, issues, _meta, _exemptions), do: {ast, issues}

  defp scoped?([:MingaEditor, :Commands | _]), do: true
  defp scoped?([:MingaEditor, :Handlers, handler]), do: handler in [:GuiActionHandler, :GUIActionHandler]
  defp scoped?([:MingaEditor, owner]), do: owner in [:Mouse, :WindowFocus, :TabWorkflow]
  defp scoped?([:MingaEditor, :Frontend, :Protocol, :GUI]), do: true
  defp scoped?(_parts), do: false

  defp inspect_clause({kind, _, [head, blocks]} = ast, issues, meta, exemptions)
       when kind in [:def, :defp] and is_list(blocks) do
    reads = if target_head?(head), do: active_reads([head, blocks], meta), else: []
    positions = position_issues(head, meta, exemptions)
    {ast, reads ++ positions ++ issues}
  end

  defp inspect_clause(ast, issues, _meta, _exemptions), do: {ast, issues}

  defp target_head?(head) do
    {_head, found?} = Macro.prewalk(head, false, fn
      {:%, _, [{:__aliases__, _, parts}, _]} = ast, found ->
        {ast, found or parts in [[:Target], [:MingaEditor, :Target]]}
      ast, found -> {ast, found}
    end)
    found?
  end

  defp active_reads(body, meta) do
    {_body, issues} = Macro.prewalk(body, [], fn ast, issues ->
      case active_read(ast) do
        nil -> {ast, issues}
        {line, trigger} ->
          issue = format_issue(meta, line_no: line, trigger: trigger, message: "Explicit target clause reads #{trigger}. Use the named target or return :target_mismatch; comparison-only reads belong in the state owner.")
          {ast, [issue | issues]}
      end
    end)
    issues
  end

  defp active_read({{:., _, [{{:., _, [_receiver, parent]}, _, []}, :active]}, meta, []}) when parent in [:buffers, :windows],
    do: {meta[:line], ".#{parent}.active"}
  defp active_read({{:., _, [_receiver, :active_id]}, meta, []}), do: {meta[:line], ".active_id"}
  defp active_read({{:., _, [{:__aliases__, _, parts}, function]}, meta, _args}) do
    case {List.last(parts), function} do
      {:TabBar, :active} -> {meta[:line], "TabBar.active"}
      {:Runtime, :active_tab} -> {meta[:line], "Runtime.active_tab"}
      {_, :active_window} -> {meta[:line], "active_window"}
      _ -> nil
    end
  end
  defp active_read({:active_window, meta, args}) when is_list(args), do: {meta[:line], "active_window"}
  defp active_read(_ast), do: nil

  defp position_issues({:when, _, [head | _guards]}, meta, exemptions), do: position_issues(head, meta, exemptions)
  defp position_issues({:decode_gui_action, _, [{:@, _, [{opcode, _, _}]}, payload]}, meta, exemptions) do
    fields = binary_fields(payload)
    if opcode == :gui_action_tab_reorder or Keyword.has_key?(exemptions, opcode) or identity?(fields) do
      []
    else
      for {name, line} <- bare_positions(fields) do
        format_issue(meta, line_no: line, trigger: Atom.to_string(name), message: "GUI action #{opcode} decodes a bare 16-bit position. Carry a stable item identity and generation with semantic_item_activate.")
      end
    end
  end
  defp position_issues(_head, _meta, _exemptions), do: []

  defp binary_fields({:<<>>, _, fields}), do: fields
  defp binary_fields({:=, _, [left, right]}), do: binary_fields(left) ++ binary_fields(right)
  defp binary_fields(_pattern), do: []

  defp identity?(fields) do
    Enum.any?(fields, fn
      {:"::", _, [{name, _, _}, type]} when is_atom(name) ->
        (unsigned_integer_width(type) == 32 and
           (name == :id or String.ends_with?(Atom.to_string(name), "_id"))) or
          (name == :item_id and framed_binary_identity?(fields, type))

      _ -> false
    end)
  end

  defp framed_binary_identity?(fields, type) do
    case segment(type, {:integer, false, 8, nil}) do
      {:binary, false, {:item_id_len, _, _}, unit} when unit in [nil, 8] ->
        Enum.any?(fields, fn
          {:"::", _, [{:item_id_len, _, _}, length_type]} ->
            unsigned_integer_width(length_type) == 16
          _ -> false
        end)

      _ -> false
    end
  end

  defp bare_positions(fields) do
    for {:"::", meta, [{name, _, _}, type]} <- fields,
        unsigned_integer_width(type) == 16,
        not length_field?(fields, name),
        do: {name, meta[:line]}
  end

  defp unsigned_integer_width(type) do
    case segment(type, {:integer, false, 8, nil}) do
      {:integer, false, size, unit} when is_integer(size) -> size * (unit || 1)
      _ -> nil
    end
  end

  defp segment({:-, _, [left, right]}, spec), do: segment(right, segment(left, spec))
  defp segment(size, {kind, signed?, _, unit}) when is_integer(size),
    do: {kind, signed?, size, unit}
  defp segment({:size, _, [size]}, {kind, signed?, _, unit}),
    do: {kind, signed?, size, unit}
  defp segment({:unit, _, [unit]}, {kind, signed?, size, _}),
    do: {kind, signed?, size, unit}
  defp segment({:signed, _, _}, {kind, _, size, unit}), do: {kind, true, size, unit}
  defp segment({:unsigned, _, _}, {kind, _, size, unit}), do: {kind, false, size, unit}
  defp segment({:bytes, _, _}, {_, signed?, size, unit}), do: {:binary, signed?, size, unit}
  defp segment({kind, _, _}, {_, signed?, size, unit})
       when kind in [:binary, :bitstring, :bits, :integer, :float, :utf8, :utf16, :utf32],
       do: {kind, signed?, size, unit}
  defp segment(_type, spec), do: spec

  defp length_field?(fields, name) do
    {_fields, used?} = Macro.prewalk(fields, false, fn
      {:size, _, [{^name, _, _}]} = ast, _found -> {ast, true}
      ast, found -> {ast, found}
    end)
    used?
  end

  defp validate_exemptions!(entries) do
    valid? = is_list(entries) and length(entries) <= 10 and Enum.all?(entries, fn
      {name, reason} when is_atom(name) and is_binary(reason) -> String.trim(reason) != ""
      _ -> false
    end)
    unless valid?, do: raise(ArgumentError, "ExplicitTargetCheck requires at most ten reasoned identity_opcodes")
  end
end
