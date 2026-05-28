defmodule Minga.RenderModel.GuardrailsTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @ui_model_root Path.join(@repo_root, "lib/minga/render_model/ui")
  @editor_render_model_root Path.join(@repo_root, "lib/minga_editor/render_model")

  @legacy_preencoded_ui_models MapSet.new([
                                 "agent_chat",
                                 "board",
                                 "bottom_panel",
                                 "change_summary",
                                 "completion",
                                 "edit_timeline",
                                 "extension_overlay",
                                 "extension_panel",
                                 "file_tree",
                                 "float_popup",
                                 "hover_popup",
                                 "minibuffer",
                                 "observatory",
                                 "picker",
                                 "sidebars",
                                 "signature_help",
                                 "status_bar",
                                 "tab_bar",
                                 "workspaces"
                               ])

  @legacy_protocol_gui_builder_files MapSet.new([
                                       "lib/minga_editor/render_model/ui/agent_chat_builder.ex",
                                       "lib/minga_editor/render_model/ui/agent_context_builder.ex",
                                       "lib/minga_editor/render_model/ui/board_builder.ex",
                                       "lib/minga_editor/render_model/ui/bottom_panel_builder.ex",
                                       "lib/minga_editor/render_model/ui/change_summary_builder.ex",
                                       "lib/minga_editor/render_model/ui/completion_builder.ex",
                                       "lib/minga_editor/render_model/ui/edit_timeline_builder.ex",
                                       "lib/minga_editor/render_model/ui/extension_overlay_builder.ex",
                                       "lib/minga_editor/render_model/ui/extension_panel_builder.ex",
                                       "lib/minga_editor/render_model/ui/file_tree_builder.ex",
                                       "lib/minga_editor/render_model/ui/float_popup_builder.ex",
                                       "lib/minga_editor/render_model/ui/hover_popup_builder.ex",
                                       "lib/minga_editor/render_model/ui/minibuffer_builder.ex",
                                       "lib/minga_editor/render_model/ui/observatory_builder.ex",
                                       "lib/minga_editor/render_model/ui/picker_builder.ex",
                                       "lib/minga_editor/render_model/ui/sidebars_builder.ex",
                                       "lib/minga_editor/render_model/ui/signature_help_builder.ex",
                                       "lib/minga_editor/render_model/ui/status_bar_builder.ex",
                                       "lib/minga_editor/render_model/ui/tab_bar_builder.ex",
                                       "lib/minga_editor/render_model/ui/workspaces_builder.ex"
                                     ])

  test "only tracked legacy UI render models carry protocol payload fields" do
    violations = payload_field_violations()

    untracked =
      Enum.reject(violations, fn violation ->
        MapSet.member?(@legacy_preencoded_ui_models, violation.component)
      end)

    assert untracked == [], """
    New Minga.RenderModel.UI structs must be semantic models, not wrappers around protocol command binaries.

    Move encoding into Minga.Frontend.Adapter.GUI, or migrate the component deliberately and update the remediation allowlist in this test.

    Untracked protocol payload fields:
    #{format_payload_violations(untracked)}
    """

    stale =
      stale_allowlist_entries(@legacy_preencoded_ui_models, Enum.map(violations, & &1.component))

    assert stale == [], """
    These legacy pre-encoded UI model allowlist entries no longer define protocol payload fields.

    Remove them from @legacy_preencoded_ui_models so the guardrail records the remaining debt accurately:
    #{format_entries(stale)}
    """
  end

  test "only tracked legacy render model builders reference the editor GUI protocol" do
    reference_files = protocol_gui_reference_files()

    untracked =
      Enum.reject(reference_files, fn path ->
        MapSet.member?(@legacy_protocol_gui_builder_files, path)
      end)

    assert untracked == [], """
    New files under lib/minga_editor/render_model must not depend on MingaEditor.Frontend.Protocol.GUI.

    Builders should produce semantic render models. Core GUI adapter encoders should own protocol bytes.

    Untracked Protocol.GUI references:
    #{format_entries(untracked)}
    """

    stale = stale_allowlist_entries(@legacy_protocol_gui_builder_files, reference_files)

    assert stale == [], """
    These legacy Protocol.GUI builder allowlist entries no longer reference MingaEditor.Frontend.Protocol.GUI.

    Remove them from @legacy_protocol_gui_builder_files so the guardrail records the remaining debt accurately:
    #{format_entries(stale)}
    """
  end

  test "resolves literal module attributes in defstruct payload fields" do
    path =
      write_guardrail_fixture("""
      defmodule Minga.RenderModel.UI.GuardrailFixture do
        @fields [:encoded, :selection_encoded]
        defstruct @fields
      end
      """)

    fields =
      path
      |> payload_field_violations_for_file()
      |> Enum.map(& &1.field)
      |> Enum.sort_by(&Atom.to_string/1)

    assert fields == [:encoded, :selection_encoded]
  end

  test "detects grouped GUI aliases in render model builders" do
    path =
      write_guardrail_fixture("""
      defmodule MingaEditor.RenderModel.UI.GuardrailFixture do
        alias MingaEditor.Frontend.Protocol.{GUI}

        def render(theme), do: GUI.encode_gui_theme(theme)
      end
      """)

    assert protocol_gui_reference_file?(path)
  end

  test "detects Protocol.GUI remote calls reached through a parent alias" do
    path =
      write_guardrail_fixture("""
      defmodule MingaEditor.RenderModel.UI.GuardrailFixture do
        alias MingaEditor.Frontend.Protocol

        def render(theme), do: Protocol.GUI.encode_gui_theme(theme)
      end
      """)

    assert protocol_gui_reference_file?(path)
  end

  test "detects grouped GUI imports in render model builders" do
    path =
      write_guardrail_fixture("""
      defmodule MingaEditor.RenderModel.UI.GuardrailFixture do
        import MingaEditor.Frontend.Protocol.{GUI}
      end
      """)

    assert protocol_gui_reference_file?(path)
  end

  test "detects standalone fully-qualified GUI references in render model builders" do
    path =
      write_guardrail_fixture("""
      defmodule MingaEditor.RenderModel.UI.GuardrailFixture do
        import MingaEditor.Frontend.Protocol.GUI

        @payload %MingaEditor.Frontend.Protocol.GUI.BoardPayload{}
        @spec render(MingaEditor.Frontend.Protocol.GUI.BoardPayload.t()) :: term()
        def render(theme), do: theme
      end
      """)

    assert protocol_gui_reference_file?(path)
  end

  defp payload_field_violations do
    [@ui_model_root, "**", "*.ex"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(&payload_field_violations_for_file/1)
  end

  defp payload_field_violations_for_file(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!(file: path)
    |> struct_fields()
    |> Enum.filter(&protocol_payload_field?/1)
    |> Enum.map(fn field ->
      %{component: component_name(path), path: relative_path(path), field: field}
    end)
  end

  defp struct_fields(ast) do
    {_ast, {%{}, fields}} = Macro.prewalk(ast, {%{}, []}, &collect_struct_fields/2)
    Enum.reverse(fields)
  end

  defp collect_struct_fields(
         {:@, _meta, [{name, _attr_meta, [value_ast]}]} = node,
         {attrs, fields}
       )
       when is_atom(name) do
    attrs =
      if Macro.quoted_literal?(value_ast) do
        Map.put(attrs, name, value_ast)
      else
        attrs
      end

    {node, {attrs, fields}}
  end

  defp collect_struct_fields({:defstruct, _meta, [fields_ast]} = node, {attrs, fields}) do
    resolved_fields = resolve_defstruct_fields(fields_ast, attrs)
    {node, {attrs, resolved_fields ++ fields}}
  end

  defp collect_struct_fields(node, acc), do: {node, acc}

  defp resolve_defstruct_fields({:@, _meta, [{attr_name, _, nil}]}, attrs)
       when is_atom(attr_name) do
    attrs
    |> Map.get(attr_name, [])
    |> extract_struct_fields()
  end

  defp resolve_defstruct_fields(fields_ast, _attrs), do: extract_struct_fields(fields_ast)

  defp extract_struct_fields(fields) when is_list(fields) do
    Enum.flat_map(fields, &extract_struct_field/1)
  end

  defp extract_struct_fields(_other), do: []

  defp extract_struct_field(field) when is_atom(field), do: [field]

  defp extract_struct_field({field, _default}) when is_atom(field), do: [field]

  defp extract_struct_field(_other), do: []

  defp protocol_payload_field?(field) do
    name = Atom.to_string(field)

    exact_protocol_payload_field?(name) or encoded_protocol_payload_field?(name) or
      command_protocol_payload_field?(name)
  end

  defp exact_protocol_payload_field?("encoded"), do: true
  defp exact_protocol_payload_field?("selection_encoded"), do: true
  defp exact_protocol_payload_field?("cmd"), do: true
  defp exact_protocol_payload_field?(_name), do: false

  defp encoded_protocol_payload_field?(name), do: String.ends_with?(name, "_encoded")

  defp command_protocol_payload_field?(name) do
    name in ["command", "commands", "cmds"] or String.ends_with?(name, "_cmd") or
      String.ends_with?(name, "_cmds") or String.ends_with?(name, "_command") or
      String.ends_with?(name, "_commands")
  end

  defp protocol_gui_reference_files do
    [@editor_render_model_root, "**", "*.ex"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.filter(&protocol_gui_reference_file?/1)
    |> Enum.map(&relative_path/1)
  end

  defp protocol_gui_reference_file?(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!(file: path)
    |> protocol_gui_reference_ast?()
  end

  defp protocol_gui_reference_ast?(ast) do
    {_ast, {_aliases, found}} =
      Macro.prewalk(ast, {%{}, false}, &collect_protocol_gui_references/2)

    found
  end

  defp collect_protocol_gui_references({:alias, _meta, [target_ast]} = node, {aliases, found}) do
    {aliases, alias_found?} = register_aliases(target_ast, nil, aliases)
    {node, {aliases, found or alias_found?}}
  end

  defp collect_protocol_gui_references(
         {:alias, _meta, [target_ast, opts]} = node,
         {aliases, found}
       ) do
    {aliases, alias_found?} = register_aliases(target_ast, opts, aliases)
    {node, {aliases, found or alias_found?}}
  end

  defp collect_protocol_gui_references(
         {{:., _meta1, [module_ast, :{}]}, _meta2, children} = node,
         {aliases, found}
       ) do
    {node, {aliases, found or grouped_remote_gui_reference?(module_ast, children, aliases)}}
  end

  defp collect_protocol_gui_references({:__aliases__, _meta, _segments} = node, {aliases, found}) do
    {node, {aliases, found or module_path_has_gui_prefix?(node, aliases)}}
  end

  defp collect_protocol_gui_references(node, acc), do: {node, acc}

  defp register_aliases({{:., _, [base_ast, :{}]}, _, children}, _opts, aliases) do
    base_paths = resolve_module_paths(base_ast, aliases)

    Enum.reduce(base_paths, {aliases, false}, fn base_path, {alias_map, found} ->
      Enum.reduce(children, {alias_map, found}, fn child_ast, {alias_map_acc, found_acc} ->
        child_segments = alias_segments(child_ast)
        path = base_path ++ child_segments
        alias_key = [List.last(path)]

        {Map.put(alias_map_acc, alias_key, path), found_acc or gui_module_path?(path)}
      end)
    end)
  end

  defp register_aliases(target_ast, opts, aliases) do
    alias_name = alias_name_from_opts(opts)

    resolve_module_paths(target_ast, aliases)
    |> Enum.reduce({aliases, false}, fn path, {alias_map, found} ->
      alias_key = alias_name || [List.last(path)]
      {Map.put(alias_map, alias_key, path), found or gui_module_path?(path)}
    end)
  end

  defp resolve_module_paths({:__aliases__, _, segments}, aliases) do
    [resolve_module_segments(segments, aliases)]
  end

  defp resolve_module_paths(other, _aliases), do: [alias_segments(other)]

  defp resolve_module_segments([:MingaEditor | _] = segments, _aliases), do: segments

  defp resolve_module_segments(segments, aliases) do
    resolve_module_segments(segments, aliases, length(segments))
  end

  defp resolve_module_segments(segments, _aliases, 0), do: segments

  defp resolve_module_segments(segments, aliases, prefix_length) do
    prefix = Enum.take(segments, prefix_length)

    case Map.get(aliases, prefix) do
      nil -> resolve_module_segments(segments, aliases, prefix_length - 1)
      resolved_prefix -> resolved_prefix ++ Enum.drop(segments, prefix_length)
    end
  end

  defp alias_segments({:__aliases__, _, segments}), do: segments
  defp alias_segments(_other), do: []

  defp alias_name_from_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :as) do
      nil -> nil
      as_ast -> alias_segments(as_ast)
    end
  end

  defp alias_name_from_opts(_opts), do: nil

  defp module_path_has_gui_prefix?(module_ast, aliases) do
    module_ast
    |> resolve_module_paths(aliases)
    |> Enum.any?(&gui_module_path?/1)
  end

  defp grouped_remote_gui_reference?(module_ast, children, aliases) do
    module_ast
    |> resolve_module_paths(aliases)
    |> Enum.any?(fn base_path ->
      Enum.any?(children, fn child_ast ->
        gui_module_path?(base_path ++ alias_segments(child_ast))
      end)
    end)
  end

  defp gui_module_path?(module_path) do
    Enum.take(module_path, 4) == [:MingaEditor, :Frontend, :Protocol, :GUI]
  end

  defp write_guardrail_fixture(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "minga_render_model_guardrail_#{System.unique_integer([:positive])}.ex"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp stale_allowlist_entries(allowlist, actual_entries) do
    actual = MapSet.new(actual_entries)

    allowlist
    |> MapSet.difference(actual)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp component_name(path), do: Path.basename(path, ".ex")

  defp relative_path(path), do: Path.relative_to(path, @repo_root)

  defp format_payload_violations([]), do: "none"

  defp format_payload_violations(violations) do
    Enum.map_join(violations, "\n", fn violation ->
      "- #{violation.path}: #{inspect(violation.field)}"
    end)
  end

  defp format_entries([]), do: "none"

  defp format_entries(entries) do
    Enum.map_join(entries, "\n", fn entry -> "- #{entry}" end)
  end
end
