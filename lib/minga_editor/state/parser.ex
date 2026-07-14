defmodule MingaEditor.State.Parser do
  @moduledoc """
  Parser connection and parser-derived presentation state.

  Highlight caches, injection ranges, and per-buffer face registries are kept
  together so buffer retirement and parser availability transitions cannot
  leave one parser-derived surface behind.
  """

  alias MingaEditor.State.Highlighting
  alias MingaEditor.UI.Face.Registry

  @type status :: MingaEditor.Shell.Traditional.Modeline.parser_status()
  @type injection_ranges :: %{pid() => [Minga.Language.Highlight.InjectionRange.t()]}
  @type face_override_registries :: %{pid() => Registry.t()}

  @type t :: %__MODULE__{
          parser_manager: GenServer.server(),
          parser_status: status(),
          highlighting: Highlighting.t(),
          injection_ranges: injection_ranges(),
          face_override_registries: face_override_registries()
        }

  defstruct parser_manager: Minga.Parser.Manager,
            parser_status: :available,
            highlighting: %Highlighting{},
            injection_ranges: %{},
            face_override_registries: %{}

  @doc "Creates parser state for the configured parser manager."
  @spec new(GenServer.server()) :: t()
  def new(parser_manager \\ Minga.Parser.Manager),
    do: %__MODULE__{parser_manager: parser_manager}

  @doc "Records the parser manager serving this editor."
  @spec connect_manager(t(), GenServer.server()) :: t()
  def connect_manager(%__MODULE__{} = parser, manager),
    do: %{parser | parser_manager: manager}

  @doc "Records parser availability for editor presentation."
  @spec report_status(t(), status()) :: t()
  def report_status(%__MODULE__{} = parser, status),
    do: %{parser | parser_status: status}

  @doc "Commits syntax-highlight presentation caches."
  @spec accept_highlighting(t(), Highlighting.t()) :: t()
  def accept_highlighting(%__MODULE__{} = parser, %Highlighting{} = highlighting),
    do: %{parser | highlighting: highlighting}

  @doc "Commits live parser injection ranges."
  @spec accept_injection_ranges(t(), injection_ranges()) :: t()
  def accept_injection_ranges(%__MODULE__{} = parser, ranges) when is_map(ranges),
    do: %{parser | injection_ranges: ranges}

  @doc "Reconciles the face override registry associated with a buffer."
  @spec reconcile_face_overrides(t(), pid(), Registry.t() | nil) :: t()
  def reconcile_face_overrides(%__MODULE__{} = parser, buffer_pid, nil)
      when is_pid(buffer_pid) do
    %{parser | face_override_registries: Map.delete(parser.face_override_registries, buffer_pid)}
  end

  def reconcile_face_overrides(%__MODULE__{} = parser, buffer_pid, %Registry{} = registry)
      when is_pid(buffer_pid) do
    registries = Map.put(parser.face_override_registries, buffer_pid, registry)
    %{parser | face_override_registries: registries}
  end

  @doc "Drops every parser-derived presentation value associated with a buffer."
  @spec retire_buffer(t(), pid()) :: t()
  def retire_buffer(%__MODULE__{} = parser, buffer_pid) when is_pid(buffer_pid) do
    %{
      parser
      | highlighting: Highlighting.remove_buffer(parser.highlighting, buffer_pid),
        injection_ranges: Map.delete(parser.injection_ranges, buffer_pid),
        face_override_registries: Map.delete(parser.face_override_registries, buffer_pid)
    }
  end
end
