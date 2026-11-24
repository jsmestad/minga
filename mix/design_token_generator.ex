defmodule Minga.Mix.DesignTokenGenerator do
  @moduledoc """
  Generates the design token sources for Elixir, Swift and Go from `docs/design_tokens.toml`.

  The token file names colour roles, the six state words and their shapes, the twist variants and the voice lines. Themes supply colour values; the tokens only name roles and say which theme field or derivation feeds each one. Every output is checked in, and CI fails when `mix codegen` changes one.
  """

  @source_path "docs/design_tokens.toml"
  @elixir_path "generated/elixir/design_tokens.ex"
  @swift_path "macos/Sources/Protocol/DesignTokens.generated.swift"
  @go_path "go/tui/internal/generated/design_tokens.go"

  @role_slot_range 0x70..0x8F
  @shapes ~w(orbit halo_dot hollow_dot diamond solid_dot)
  @contrast_classes ~w(text glyph)
  @voice_lines ~w(welcome done farewell)
  @id_pattern ~r/^[a-z][a-z0-9_]*$/

  @type role_source ::
          {:fields, [{String.t(), String.t()}, ...]} | {:mix, String.t(), String.t(), 0..100}

  @type role :: %{
          id: String.t(),
          slot: non_neg_integer(),
          source: role_source(),
          contrast: {String.t(), String.t()} | nil,
          means: String.t()
        }

  @type state :: %{
          id: String.t(),
          wire: pos_integer(),
          word: String.t(),
          shape: String.t(),
          role: String.t(),
          tui_glyph: String.t(),
          tui_frames: [String.t()],
          accessibility_label: String.t()
        }

  @type agent_status :: %{id: String.t(), wire: byte(), state: String.t() | nil}

  @type twist :: %{
          id: String.t(),
          mark: String.t(),
          tui_glyph: String.t(),
          strand: String.t(),
          shade: String.t() | nil
        }

  @type tokens :: %{
          contrast: %{String.t() => float()},
          roles: [role()],
          states: [state()],
          agent_statuses: [agent_status()],
          twist: [twist()],
          voice: [{String.t(), String.t()}]
        }

  @type output :: {Path.t(), String.t()}

  @doc "Writes every generated source, or raises with the stale paths when `--check` is given."
  @spec run([String.t()]) :: :ok
  def run(args) do
    outputs = outputs(load!())

    if "--check" in args do
      check_outputs!(outputs)
    else
      Enum.each(outputs, fn {path, contents} -> write_if_changed!(path, contents) end)
    end
  end

  @spec source_path() :: Path.t()
  def source_path, do: @source_path

  @spec generated_paths() :: [Path.t()]
  def generated_paths, do: [@elixir_path, @swift_path, @go_path]

  @doc "Reads and validates the token file."
  @spec load!(Path.t()) :: tokens()
  def load!(path \\ @source_path) do
    case path |> File.read!() |> Toml.decode() do
      {:ok, raw} -> parse!(raw)
      {:error, reason} -> Mix.raise("Failed to parse #{path}: #{inspect(reason)}")
    end
  end

  @doc "Validates decoded TOML and normalizes it into the token map the renderers use."
  @spec parse!(map()) :: tokens()
  def parse!(raw) when is_map(raw) do
    contrast = parse_contrast!(Map.get(raw, "contrast"))
    roles = parse_list!(raw, "color_roles", &parse_role!/1)
    role_ids = unique_ids!(roles, "color_roles")
    validate_slots!(roles)
    Enum.each(roles, &validate_role_refs!(&1, role_ids))

    states = parse_list!(raw, "states", &parse_state!(&1, role_ids))
    state_ids = unique_ids!(states, "states")
    validate_wires!(states, "states")

    agent_statuses = parse_list!(raw, "agent_statuses", &parse_agent_status!(&1, state_ids))
    unique_ids!(agent_statuses, "agent_statuses")
    validate_wires!(agent_statuses, "agent_statuses")

    unless Enum.any?(agent_statuses, &(&1.id == "idle")) do
      invalid!("agent_statuses must define idle, the status unknown statuses encode as")
    end

    twist = parse_list!(raw, "twist", &parse_twist!(&1, role_ids))
    unique_ids!(twist, "twist")

    %{
      contrast: contrast,
      roles: roles,
      states: states,
      agent_statuses: agent_statuses,
      twist: twist,
      voice: parse_voice!(Map.get(raw, "voice"))
    }
  end

  @doc "Renders every generated source for a validated token map."
  @spec outputs(tokens()) :: [output()]
  def outputs(tokens) do
    [
      {@elixir_path, elixir_file(tokens)},
      {@swift_path, swift_file(tokens)},
      {@go_path, go_file(tokens)}
    ]
  end

  # ── Validation ─────────────────────────────────────────────────────────────

  @spec parse_contrast!(term()) :: %{String.t() => float()}
  defp parse_contrast!(%{} = contrast) do
    Map.new(@contrast_classes, fn class ->
      case Map.get(contrast, class) do
        ratio when is_number(ratio) and ratio >= 1 ->
          {class, ratio / 1}

        other ->
          invalid!("contrast.#{class} must be a ratio of at least 1, got #{inspect(other)}")
      end
    end)
  end

  defp parse_contrast!(other), do: invalid!("[contrast] must be a table, got #{inspect(other)}")

  @spec parse_list!(map(), String.t(), (map() -> entry)) :: [entry] when entry: map()
  defp parse_list!(raw, key, parse) do
    case Map.get(raw, key) do
      [_ | _] = entries -> Enum.map(entries, parse)
      other -> invalid!("#{key} must be a non-empty array of tables, got #{inspect(other)}")
    end
  end

  @spec parse_role!(map()) :: role()
  defp parse_role!(%{"id" => id, "slot" => slot, "means" => means} = raw) do
    validate_id!(id, "color_roles")

    unless is_integer(slot) and slot in @role_slot_range do
      invalid!("colour role #{id} slot must be in 0x70..0x8F, got #{inspect(slot)}")
    end

    unless is_binary(means) and means != "" do
      invalid!("colour role #{id} needs a `means` description")
    end

    %{
      id: id,
      slot: slot,
      source: parse_source!(id, raw),
      contrast: parse_role_contrast!(id, raw),
      means: means
    }
  end

  defp parse_role!(raw), do: invalid!("colour role needs id, slot and means: #{inspect(raw)}")

  @spec parse_source!(String.t(), map()) :: role_source()
  defp parse_source!(id, %{"source" => source} = raw) when is_binary(source) do
    if Map.has_key?(raw, "mix"), do: invalid!("colour role #{id} has both source and mix")

    fallbacks =
      case Map.get(raw, "fallback") do
        nil ->
          []

        fallback when is_binary(fallback) ->
          [fallback]

        other ->
          invalid!("colour role #{id} fallback must be section.field, got #{inspect(other)}")
      end

    {:fields, Enum.map([source | fallbacks], &parse_field!(id, &1))}
  end

  defp parse_source!(_id, %{"mix" => mix, "over" => over, "percent" => percent})
       when is_binary(mix) and is_binary(over) and is_integer(percent) and percent in 0..100 do
    {:mix, mix, over, percent}
  end

  defp parse_source!(id, _raw) do
    invalid!("colour role #{id} needs a source, or mix, over and percent (0..100)")
  end

  @spec parse_field!(String.t(), String.t()) :: {String.t(), String.t()}
  defp parse_field!(id, path) do
    case String.split(path, ".") do
      [section, field] when section != "" and field != "" ->
        validate_id!(section, "colour role #{id} source section")
        validate_id!(field, "colour role #{id} source field")
        {section, field}

      _ ->
        invalid!("colour role #{id} source must be section.field, got #{inspect(path)}")
    end
  end

  @spec parse_role_contrast!(String.t(), map()) :: {String.t(), String.t()} | nil
  defp parse_role_contrast!(id, %{"contrast" => class} = raw) do
    unless class in @contrast_classes do
      invalid!("colour role #{id} contrast must be one of #{inspect(@contrast_classes)}")
    end

    case Map.get(raw, "on") do
      on when is_binary(on) -> {class, on}
      _ -> invalid!("colour role #{id} has a contrast class but no `on` role")
    end
  end

  defp parse_role_contrast!(_id, _raw), do: nil

  @spec validate_role_refs!(role(), MapSet.t(String.t())) :: :ok
  defp validate_role_refs!(%{id: id} = role, role_ids) do
    refs =
      case role.source do
        {:mix, mix, over, _percent} -> [mix, over]
        {:fields, _fields} -> []
      end

    refs = if role.contrast, do: [elem(role.contrast, 1) | refs], else: refs
    Enum.each(refs, &validate_role_ref!(&1, role_ids, "colour role #{id}"))
  end

  @spec validate_slots!([role()]) :: :ok
  defp validate_slots!(roles) do
    roles
    |> Enum.group_by(& &1.slot, & &1.id)
    |> Enum.each(fn
      {_slot, [_id]} -> :ok
      {slot, ids} -> invalid!("slot 0x#{hex(slot)} is shared by #{Enum.join(ids, ", ")}")
    end)
  end

  @spec parse_state!(map(), MapSet.t(String.t())) :: state()
  defp parse_state!(
         %{
           "id" => id,
           "wire" => wire,
           "word" => word,
           "shape" => shape,
           "role" => role,
           "tui_glyph" => glyph,
           "accessibility_label" => label
         } = raw,
         role_ids
       ) do
    validate_id!(id, "states")
    Enum.each([word, glyph, label], &validate_text!(&1, "state #{id}"))

    unless is_integer(wire) and wire in 1..255 do
      invalid!("state #{id} wire must be a byte from 1 to 255, got #{inspect(wire)}")
    end

    unless shape in @shapes do
      invalid!("state #{id} shape must be one of #{inspect(@shapes)}, got #{inspect(shape)}")
    end

    validate_role_ref!(role, role_ids, "state #{id}")
    frames = Map.get(raw, "tui_frames", [glyph])
    Enum.each(frames, &validate_text!(&1, "state #{id} tui_frames"))

    %{
      id: id,
      wire: wire,
      word: word,
      shape: shape,
      role: role,
      tui_glyph: glyph,
      tui_frames: frames,
      accessibility_label: label
    }
  end

  defp parse_state!(raw, _role_ids) do
    invalid!(
      "state needs id, wire, word, shape, role, tui_glyph and accessibility_label: #{inspect(raw)}"
    )
  end

  @spec parse_agent_status!(map(), MapSet.t(String.t())) :: agent_status()
  defp parse_agent_status!(%{"id" => id, "wire" => wire} = raw, state_ids)
       when is_integer(wire) and wire in 0..255 do
    validate_id!(id, "agent_statuses")
    state = Map.get(raw, "state")

    if state != nil and not MapSet.member?(state_ids, state) do
      invalid!("agent status #{id} names unknown state #{inspect(state)}")
    end

    %{id: id, wire: wire, state: state}
  end

  defp parse_agent_status!(raw, _state_ids) do
    invalid!("agent status needs an id and a wire byte: #{inspect(raw)}")
  end

  @spec validate_wires!([%{id: String.t(), wire: byte()}], String.t()) :: :ok
  defp validate_wires!(entries, label) do
    entries
    |> Enum.group_by(& &1.wire, & &1.id)
    |> Enum.each(fn
      {_wire, [_id]} -> :ok
      {wire, ids} -> invalid!("#{label} wire byte #{wire} is shared by #{Enum.join(ids, ", ")}")
    end)
  end

  @spec parse_twist!(map(), MapSet.t(String.t())) :: twist()
  defp parse_twist!(
         %{"id" => id, "mark" => mark, "tui_glyph" => glyph, "strand" => strand} = raw,
         role_ids
       ) do
    validate_id!(id, "twist")
    Enum.each([mark, glyph], &validate_text!(&1, "twist #{id}"))
    validate_role_ref!(strand, role_ids, "twist #{id}")
    shade = Map.get(raw, "shade")
    if shade, do: validate_role_ref!(shade, role_ids, "twist #{id}")

    %{id: id, mark: mark, tui_glyph: glyph, strand: strand, shade: shade}
  end

  defp parse_twist!(raw, _role_ids) do
    invalid!("twist needs id, mark, tui_glyph and strand: #{inspect(raw)}")
  end

  @spec parse_voice!(term()) :: [{String.t(), String.t()}]
  defp parse_voice!(%{} = voice) do
    if Enum.sort(Map.keys(voice)) != Enum.sort(@voice_lines) do
      invalid!("[voice] must define exactly #{Enum.join(@voice_lines, ", ")}")
    end

    Enum.map(@voice_lines, fn line ->
      validate_text!(voice[line], "voice.#{line}")
      {line, voice[line]}
    end)
  end

  defp parse_voice!(other), do: invalid!("[voice] must be a table, got #{inspect(other)}")

  @spec unique_ids!([%{id: String.t()}], String.t()) :: MapSet.t(String.t())
  defp unique_ids!(entries, label) do
    Enum.reduce(entries, MapSet.new(), fn %{id: id}, seen ->
      if MapSet.member?(seen, id), do: invalid!("duplicate #{label} id #{inspect(id)}")
      MapSet.put(seen, id)
    end)
  end

  @spec validate_role_ref!(term(), MapSet.t(String.t()), String.t()) :: :ok
  defp validate_role_ref!(ref, role_ids, owner) do
    if MapSet.member?(role_ids, ref) do
      :ok
    else
      invalid!("#{owner} names unknown colour role #{inspect(ref)}")
    end
  end

  @spec validate_id!(term(), String.t()) :: :ok
  defp validate_id!(id, owner) do
    if is_binary(id) and Regex.match?(@id_pattern, id) do
      :ok
    else
      invalid!("#{owner} id must be snake_case, got #{inspect(id)}")
    end
  end

  @spec validate_text!(term(), String.t()) :: :ok
  defp validate_text!(text, owner) do
    if is_binary(text) and text != "" and not String.contains?(text, ["\"", "\\", "\n"]) do
      :ok
    else
      invalid!("#{owner} needs a plain non-empty string without quotes, got #{inspect(text)}")
    end
  end

  @spec invalid!(String.t()) :: no_return()
  defp invalid!(message), do: Mix.raise("Invalid #{@source_path}: #{message}")

  # ── Writing ────────────────────────────────────────────────────────────────

  @spec write_if_changed!(Path.t(), String.t()) :: :ok
  defp write_if_changed!(path, contents) do
    File.mkdir_p!(Path.dirname(path))

    case File.read(path) do
      {:ok, ^contents} -> :ok
      _other -> File.write!(path, contents)
    end
  end

  @spec check_outputs!([output()]) :: :ok
  defp check_outputs!(outputs) do
    case Enum.reject(outputs, fn {path, contents} -> File.read(path) == {:ok, contents} end) do
      [] ->
        :ok

      stale ->
        paths = Enum.map_join(stale, "\n", fn {path, _} -> "  - #{path}" end)
        Mix.raise("Design token sources are out of date. Run `mix codegen`.\n#{paths}")
    end
  end

  # ── Elixir ─────────────────────────────────────────────────────────────────

  @spec elixir_file(tokens()) :: String.t()
  defp elixir_file(tokens) do
    role_ids = Enum.map(tokens.roles, & &1.id)
    state_ids = Enum.map(tokens.states, & &1.id)
    twist_ids = Enum.map(tokens.twist, & &1.id)
    agent_status_ids = Enum.map(tokens.agent_statuses, & &1.id)

    source = """
    defmodule Minga.Design.Tokens do
      @moduledoc \"\"\"
      Design tokens: colour roles, state words and shapes, twist variants and voice lines.

      Generated from `#{@source_path}` by `mix codegen`. Do not edit by hand.

      Tokens name roles, never colour values. `MingaEditor.UI.Theme.role_color/2` resolves a role to the active theme's value. Tests assert by these names (`:needs_you`, `:working`) rather than by hex values.
      \"\"\"

      @typedoc "A colour role id."
      @type color_role :: #{atom_union(role_ids)}

      @typedoc "One of the six state ids."
      @type state_id :: #{atom_union(state_ids)}

      @typedoc "A state's shape. Waiting and Stopped share the hollow dot."
      @type state_shape :: #{atom_union(@shapes)}

      @typedoc "An Agent status the BEAM reports, as `MingaEditor.Agent.WorkspaceStatus` resolves it or a workspace stores it."
      @type agent_status :: #{atom_union(agent_status_ids)}

      @typedoc "A twist variant id."
      @type twist_variant :: #{atom_union(twist_ids)}

      @typedoc "A voice line id."
      @type voice_line :: #{atom_union(@voice_lines)}

      @typedoc "A contrast target class."
      @type contrast_class :: #{atom_union(@contrast_classes)}

      @typedoc "Where a role's colour comes from: the first non-nil theme field in a list, or a mix of one role over another at a percentage."
      @type role_source ::
              {:fields, [{section :: atom(), field :: atom()}, ...]}
              | {:mix, color_role(), over :: color_role(), percent :: 0..100}

      @typedoc "A colour role token."
      @type role_token :: %{
              id: color_role(),
              slot: byte(),
              source: role_source(),
              contrast: {contrast_class(), on :: color_role()} | nil
            }

      @typedoc "A state token."
      @type state_token :: %{
              id: state_id(),
              word: String.t(),
              shape: state_shape(),
              role: color_role(),
              tui_glyph: String.t(),
              tui_frames: [String.t()],
              accessibility_label: String.t()
            }

      @typedoc "A twist variant token. `shade` is nil when the variant has one strand."
      @type twist_token :: %{
              id: twist_variant(),
              mark: String.t(),
              tui_glyph: String.t(),
              strand: color_role(),
              shade: color_role() | nil
            }

      @doc "Every colour role id, in token-file order."
      @spec color_roles() :: [color_role()]
      def color_roles, do: #{inspect(atoms(role_ids))}

      @doc "The token for one colour role."
      @spec color_role(color_role()) :: role_token()
    #{Enum.map_join(tokens.roles, "\n", &elixir_role_clause/1)}

      @doc "The gui_theme slot ID that carries a colour role."
      @spec color_role_slot(color_role()) :: byte()
      def color_role_slot(role), do: color_role(role).slot

      @doc "The minimum contrast ratio for a target class."
      @spec contrast_target(contrast_class()) :: float()
    #{Enum.map_join(@contrast_classes, "\n", &"  def contrast_target(:#{&1}), do: #{tokens.contrast[&1]}")}

      @doc "Every state id, in token-file order."
      @spec state_ids() :: [state_id()]
      def state_ids, do: #{inspect(atoms(state_ids))}

      @doc "The token for one state."
      @spec state(state_id()) :: state_token()
    #{Enum.map_join(tokens.states, "\n", &elixir_state_clause/1)}

      @doc "The word a state is shown with."
      @spec state_word(state_id()) :: String.t()
      def state_word(state), do: state(state).word

      @doc "The colour role a state is drawn in."
      @spec state_role(state_id()) :: color_role()
      def state_role(state), do: state(state).role

      @doc "The byte a GUI section carries for a state; 0 means no state."
      @spec state_wire(state_id() | nil) :: byte()
    #{Enum.map_join(tokens.states, "\n", &"  def state_wire(:#{&1.id}), do: #{&1.wire}")}
      def state_wire(nil), do: 0

      @doc "Every Agent status, in token-file order."
      @spec agent_statuses() :: [agent_status()]
      def agent_statuses, do: #{inspect(atoms(agent_status_ids))}

      @doc "The Agent status byte gui_status_bar and gui_workspaces carry; unknown statuses and nil encode as idle."
      @spec agent_status_wire(agent_status() | atom() | nil) :: byte()
    #{Enum.map_join(tokens.agent_statuses, "\n", &"  def agent_status_wire(:#{&1.id}), do: #{&1.wire}")}
      def agent_status_wire(_status), do: #{Enum.find(tokens.agent_statuses, &(&1.id == "idle")).wire}

      @doc \"\"\"
      The state an Agent status speaks as, or nil when it shows none.

      Every surface that shows Minga's state reads it through this table, in Elixir, Swift and Go, so no two surfaces name the same status differently.
      \"\"\"
      @spec agent_status_state(agent_status() | atom() | nil) :: state_id() | nil
    #{Enum.map_join(tokens.agent_statuses, "\n", &"  def agent_status_state(:#{&1.id}), do: #{elixir_optional_atom(&1.state)}")}
      def agent_status_state(_status), do: nil

      @doc "Every twist variant id, in token-file order."
      @spec twist_variants() :: [twist_variant()]
      def twist_variants, do: #{inspect(atoms(twist_ids))}

      @doc "The token for one twist variant."
      @spec twist(twist_variant()) :: twist_token()
    #{Enum.map_join(tokens.twist, "\n", &elixir_twist_clause/1)}

      @doc "One of the three voice lines."
      @spec voice(voice_line()) :: String.t()
    #{Enum.map_join(tokens.voice, "\n", fn {line, text} -> "  def voice(:#{line}), do: #{inspect(text)}" end)}
    end
    """

    header = "# Code generated by mix codegen from #{@source_path}. DO NOT EDIT.\n\n"
    header <> IO.iodata_to_binary(Code.format_string!(source)) <> "\n"
  end

  @spec elixir_role_clause(role()) :: String.t()
  defp elixir_role_clause(role) do
    source =
      case role.source do
        {:fields, fields} ->
          "{:fields, [" <>
            Enum.map_join(fields, ", ", fn {section, field} -> "{:#{section}, :#{field}}" end) <>
            "]}"

        {:mix, mix, over, percent} ->
          "{:mix, :#{mix}, :#{over}, #{percent}}"
      end

    contrast =
      case role.contrast do
        nil -> "nil"
        {class, on} -> "{:#{class}, :#{on}}"
      end

    "  def color_role(:#{role.id}), do: %{id: :#{role.id}, slot: 0x#{hex(role.slot)}, source: #{source}, contrast: #{contrast}}"
  end

  @spec elixir_state_clause(state()) :: String.t()
  defp elixir_state_clause(state) do
    "  def state(:#{state.id}), do: %{id: :#{state.id}, word: #{inspect(state.word)}, shape: :#{state.shape}, role: :#{state.role}, tui_glyph: #{inspect(state.tui_glyph)}, tui_frames: #{inspect(state.tui_frames)}, accessibility_label: #{inspect(state.accessibility_label)}}"
  end

  @spec elixir_optional_atom(String.t() | nil) :: String.t()
  defp elixir_optional_atom(nil), do: "nil"
  defp elixir_optional_atom(id), do: ":#{id}"

  @spec elixir_twist_clause(twist()) :: String.t()
  defp elixir_twist_clause(twist) do
    shade = if twist.shade, do: ":#{twist.shade}", else: "nil"

    "  def twist(:#{twist.id}), do: %{id: :#{twist.id}, mark: #{inspect(twist.mark)}, tui_glyph: #{inspect(twist.tui_glyph)}, strand: :#{twist.strand}, shade: #{shade}}"
  end

  @spec atom_union([String.t()]) :: String.t()
  defp atom_union(ids), do: Enum.map_join(ids, " | ", &":#{&1}")

  @spec atoms([String.t()]) :: [atom()]
  defp atoms(ids), do: Enum.map(ids, &String.to_atom/1)

  # ── Swift ──────────────────────────────────────────────────────────────────

  @spec swift_file(tokens()) :: String.t()
  defp swift_file(tokens) do
    """
    // Code generated by mix codegen from #{@source_path}. DO NOT EDIT.
    //
    // Tokens name roles, never colour values. The BEAM sends each role's colour in the gui_theme slot named by its raw value; ThemeColors resolves a role to a Color.

    /// A colour role. The raw value is the gui_theme slot that carries the role's colour.
    public enum ColorRole: UInt8, CaseIterable, Sendable {
    #{Enum.map_join(tokens.roles, "\n", &"    case #{camel(&1.id)} = 0x#{hex(&1.slot)}")}

        /// The role's id in the token file.
        public var id: String {
            switch self {
    #{Enum.map_join(tokens.roles, "\n", &"        case .#{camel(&1.id)}: #{swift_string(&1.id)}")}
            }
        }
    }

    /// A state's shape. Waiting and Stopped share the hollow dot; the word tells them apart.
    public enum StateShape: String, CaseIterable, Sendable {
    #{Enum.map_join(@shapes, "\n", &swift_raw_case/1)}
    }

    /// One of the six states Minga can be in.
    public enum SpineState: String, CaseIterable, Sendable {
    #{Enum.map_join(tokens.states, "\n", &swift_raw_case(&1.id))}

        /// The word the state is shown with.
        public var word: String {
            switch self {
    #{swift_state_cases(tokens.states, &swift_string(&1.word))}
            }
        }

        /// The colour role the state is drawn in.
        public var role: ColorRole {
            switch self {
    #{swift_state_cases(tokens.states, &".#{camel(&1.role)}")}
            }
        }

        /// The state's shape.
        public var shape: StateShape {
            switch self {
    #{swift_state_cases(tokens.states, &".#{camel(&1.shape)}")}
            }
        }

        /// The TUI glyph for the state, shared so both frontends agree.
        public var tuiGlyph: String {
            switch self {
    #{swift_state_cases(tokens.states, &swift_string(&1.tui_glyph))}
            }
        }

        /// The VoiceOver label for the state's mark.
        public var accessibilityLabel: String {
            switch self {
    #{swift_state_cases(tokens.states, &swift_string(&1.accessibility_label))}
            }
        }

        /// The state a GUI section's state byte names, or nil for 0 (no state) and unknown bytes.
        public init?(wire: UInt8) {
            switch wire {
    #{Enum.map_join(tokens.states, "\n", &"        case #{&1.wire}: self = .#{camel(&1.id)}")}
            default: return nil
            }
        }

        /// The state an Agent status byte (gui_status_bar and gui_workspaces) speaks as, or nil when it shows none.
        public init?(agentStatus wire: UInt8) {
            switch wire {
    #{tokens.agent_statuses |> Enum.filter(& &1.state) |> Enum.map_join("\n", &"        case #{&1.wire}: self = .#{camel(&1.state)} // #{&1.id}")}
            default: return nil
            }
        }
    }

    /// A variant of the twist mark in the code gutter.
    public enum TwistVariant: String, CaseIterable, Sendable {
    #{Enum.map_join(tokens.twist, "\n", &swift_raw_case(&1.id))}

        /// The role of the light strand.
        public var strand: ColorRole {
            switch self {
    #{Enum.map_join(tokens.twist, "\n", &"        case .#{camel(&1.id)}: .#{camel(&1.strand)}")}
            }
        }

        /// The role of the shade strand, or nil when the variant has one strand.
        public var shade: ColorRole? {
            switch self {
    #{Enum.map_join(tokens.twist, "\n", &"        case .#{camel(&1.id)}: #{swift_optional_role(&1.shade)}")}
            }
        }

        /// The TUI glyph for the variant.
        public var tuiGlyph: String {
            switch self {
    #{Enum.map_join(tokens.twist, "\n", &"        case .#{camel(&1.id)}: #{swift_string(&1.tui_glyph)}")}
            }
        }
    }

    /// Minga's voice: three lines and no more.
    public enum Voice {
    #{Enum.map_join(tokens.voice, "\n", fn {line, text} -> "    public static let #{camel(line)} = #{swift_string(text)}" end)}
    }
    """
  end

  @spec swift_state_cases([state()], (state() -> String.t())) :: String.t()
  defp swift_state_cases(states, value) do
    Enum.map_join(states, "\n", &"        case .#{camel(&1.id)}: #{value.(&1)}")
  end

  @spec swift_raw_case(String.t()) :: String.t()
  defp swift_raw_case(id) do
    case camel(id) do
      ^id -> "    case #{id}"
      name -> "    case #{name} = #{swift_string(id)}"
    end
  end

  @spec swift_optional_role(String.t() | nil) :: String.t()
  defp swift_optional_role(nil), do: "nil"
  defp swift_optional_role(role), do: ".#{camel(role)}"

  @spec swift_string(String.t()) :: String.t()
  defp swift_string(text), do: ~s("#{text}")

  # ── Go ─────────────────────────────────────────────────────────────────────

  @spec go_file(tokens()) :: String.t()
  defp go_file(tokens) do
    """
    // Code generated by mix codegen from #{@source_path}. DO NOT EDIT.

    package generated

    // ColorRole is a colour role. Its value is the gui_theme slot that carries the role's colour.
    type ColorRole byte

    #{Enum.map_join(tokens.roles, "\n", &"const #{go_name("ColorRole", &1.id)} ColorRole = 0x#{hex(&1.slot)}")}

    // ColorRoles lists every colour role in token-file order.
    var ColorRoles = []ColorRole{#{Enum.map_join(tokens.roles, ", ", &go_name("ColorRole", &1.id))}}

    // ID returns the role's id in the token file.
    func (r ColorRole) ID() string {
    \tswitch r {
    #{Enum.map_join(tokens.roles, "\n", &"\tcase #{go_name("ColorRole", &1.id)}:\n\t\treturn #{inspect(&1.id)}")}
    \tdefault:
    \t\treturn ""
    \t}
    }

    // StateShape is a state's shape. Waiting and Stopped share the hollow dot.
    type StateShape string

    #{Enum.map_join(@shapes, "\n", &"const #{go_name("Shape", &1)} StateShape = #{inspect(&1)}")}

    // SpineState is one of the six states Minga can be in.
    type SpineState uint8

    const (
    #{go_iota(tokens.states, "State", "SpineState")}
    )

    // SpineStates lists every state in token-file order.
    var SpineStates = []SpineState{#{Enum.map_join(tokens.states, ", ", &go_name("State", &1.id))}}

    // StateToken is everything both frontends draw for a state.
    type StateToken struct {
    \tID                 string
    \tWord               string
    \tShape              StateShape
    \tRole               ColorRole
    \tGlyph              string
    \tFrames             []string
    \tAccessibilityLabel string
    }

    // Token returns the state's token.
    func (s SpineState) Token() StateToken {
    \tswitch s {
    #{Enum.map_join(tokens.states, "\n", &go_state_case/1)}
    \tdefault:
    \t\treturn StateToken{}
    \t}
    }

    // SpineStateFromWire returns the state a GUI section's state byte names; ok is false for 0 (no state) and unknown bytes.
    func SpineStateFromWire(wire byte) (state SpineState, ok bool) {
    \tswitch wire {
    #{Enum.map_join(tokens.states, "\n", &"\tcase #{&1.wire}:\n\t\treturn #{go_name("State", &1.id)}, true")}
    \tdefault:
    \t\treturn 0, false
    \t}
    }

    // SpineStateForAgentStatus returns the state an Agent status byte (gui_status_bar and gui_workspaces) speaks as; ok is false when it shows none.
    func SpineStateForAgentStatus(wire byte) (state SpineState, ok bool) {
    \tswitch wire {
    #{tokens.agent_statuses |> Enum.filter(& &1.state) |> Enum.map_join("\n", &"\tcase #{&1.wire}: // #{&1.id}\n\t\treturn #{go_name("State", &1.state)}, true")}
    \tdefault:
    \t\treturn 0, false
    \t}
    }

    // TwistVariant is a variant of the twist mark in the code gutter.
    type TwistVariant uint8

    const (
    #{go_iota(tokens.twist, "Twist", "TwistVariant")}
    )

    // TwistToken is the TUI drawing of a twist variant: the glyph in the strand role over the shade role. HasShade is false when the variant draws on the gutter background.
    type TwistToken struct {
    \tID       string
    \tGlyph    string
    \tStrand   ColorRole
    \tShade    ColorRole
    \tHasShade bool
    }

    // Token returns the twist variant's token.
    func (t TwistVariant) Token() TwistToken {
    \tswitch t {
    #{Enum.map_join(tokens.twist, "\n", &go_twist_case/1)}
    \tdefault:
    \t\treturn TwistToken{}
    \t}
    }

    // Voice lines: three and no more.
    #{Enum.map_join(tokens.voice, "\n", fn {line, text} -> "const #{go_name("Voice", line)} = #{inspect(text)}" end)}
    """
  end

  @spec go_state_case(state()) :: String.t()
  defp go_state_case(state) do
    frames = Enum.map_join(state.tui_frames, ", ", &inspect/1)

    "\tcase #{go_name("State", state.id)}:\n\t\treturn StateToken{ID: #{inspect(state.id)}, Word: #{inspect(state.word)}, Shape: #{go_name("Shape", state.shape)}, Role: #{go_name("ColorRole", state.role)}, Glyph: #{inspect(state.tui_glyph)}, Frames: []string{#{frames}}, AccessibilityLabel: #{inspect(state.accessibility_label)}}"
  end

  @spec go_twist_case(twist()) :: String.t()
  defp go_twist_case(twist) do
    shade =
      case twist.shade do
        nil -> ""
        shade -> ", Shade: #{go_name("ColorRole", shade)}, HasShade: true"
      end

    "\tcase #{go_name("Twist", twist.id)}:\n\t\treturn TwistToken{ID: #{inspect(twist.id)}, Glyph: #{inspect(twist.tui_glyph)}, Strand: #{go_name("ColorRole", twist.strand)}#{shade}}"
  end

  @spec go_iota([%{id: String.t()}], String.t(), String.t()) :: String.t()
  defp go_iota([first | rest], prefix, type) do
    Enum.map_join(
      [
        "\t#{go_name(prefix, first.id)} #{type} = iota"
        | Enum.map(rest, &"\t#{go_name(prefix, &1.id)}")
      ],
      "\n",
      & &1
    )
  end

  @spec go_name(String.t(), String.t()) :: String.t()
  defp go_name(prefix, id), do: prefix <> pascal(id)

  # ── Naming ─────────────────────────────────────────────────────────────────

  @spec camel(String.t()) :: String.t()
  defp camel(id) do
    [first | rest] = String.split(id, "_")
    first <> Enum.map_join(rest, &String.capitalize/1)
  end

  @spec pascal(String.t()) :: String.t()
  defp pascal(id), do: id |> String.split("_") |> Enum.map_join(&String.capitalize/1)

  @spec hex(non_neg_integer()) :: String.t()
  defp hex(value), do: value |> Integer.to_string(16) |> String.pad_leading(2, "0")
end
