defmodule Minga.Test.Storyboard.Render do
  @moduledoc """
  Records what every built storyboard scenario sends to each frontend, so the frontends can draw it (#4036).

  The storyboard factory drives a scenario through the real editor with rendering enabled and a headless frontend that keeps every packet. A packet is the exact payload a real frontend receives as one length-prefixed frame. Replaying a transcript's packets in order through a frontend's production decoder draws the scenario as that frontend would:

  - the Go TUI replays them in `go/tui/internal/ui/storyboard_render_test.go` and writes a text grid with its style runs;
  - the macOS frontend replays them in PreviewHost's storyboard mode and writes a PNG and an export of its measured anatomy parts.

  Every capture runs the real tree-sitter parser (see `Minga.Test.Storyboard.Session`), so frames show the syntax colours a user sees.

  Every scenario renders in each theme in `themes/0`, at each terminal size in `tui_sizes/0`, and at each macOS window width in `test/storyboard/macos_geometry.json`. The editor is told the frontend's capabilities, so each frontend gets the packets it would get in production. Journeys render as frame strips in the default theme at one size per frontend.

  `export!/1` writes the transcripts and a manifest that `design/tools/storyboard/renders.py` reads to diff renders against the baselines and to build the storyboard page. See `docs/design/storyboard.md`, "Renders and baselines".
  """

  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Inventory
  alias Minga.Test.Storyboard.Journeys
  alias Minga.Test.Storyboard.Model
  alias Minga.Test.Storyboard.Registry
  alias Minga.Test.Storyboard.Session
  alias MingaEditor.Frontend.Capabilities

  @themes [:catppuccin_frappe, :astrodark, :catppuccin_latte]
  @strip_theme :catppuccin_frappe
  @tui_sizes [{80, 24}, {120, 40}, {150, 38}]
  # The TUI draws its header above the grid it reports to the BEAM (`Model.reportGridResize` in go/tui/internal/ui/model.go): the workspace bar when there is more than one workspace, the tab bar, and the breadcrumb from 100 columns up when it has segments (`headerChrome` in render_chrome.go; `Session.tui_header_rows/3`).
  # Sessions start laid out for the usual header and report the grid the scenario's header leaves, as the terminal would.
  # The Go renderer checks its own grid against the transcript's `grid_rows` and fails when they differ.
  @tui_breadcrumb_min_cols 100
  @strip_tui_size "120x40"
  @strip_macos_size "1440"
  @macos_geometry_path "test/storyboard/macos_geometry.json"
  @external_resource @macos_geometry_path
  @macos_geometry @macos_geometry_path |> File.read!() |> JSON.decode!()

  @typedoc "The frontend a transcript is for."
  @type frontend :: :tui | :macos

  @typedoc """
  One render target: a frontend, a theme and a size.

  `size` names the target in file names: `80x24` for a terminal, the window width in points (`1440`) for macOS. On macOS, `cols` and `rows` are the editor grid the frontend reports for that size; they come from `test/storyboard/macos_geometry.json`, which the macOS renderer checks against its own row fit. `chrome_grid` maps the chrome open at the reached frame to the grid the frontend reports instead (see `fitted_target/2`). In the TUI, `cols` and `rows` are the terminal size, and `grid_rows` is the grid the TUI reports below its header; the session lays out for that grid.
  """
  @type target :: %{
          frontend: frontend(),
          theme: atom(),
          size: String.t(),
          cols: pos_integer(),
          rows: pos_integer(),
          grid_rows: pos_integer(),
          window: {pos_integer(), pos_integer()} | nil,
          chrome_grid: %{optional(String.t()) => chrome_geometry()},
          prompt_fit: {cols :: pos_integer(), rows :: pos_integer()} | nil
        }

  @typep chrome_geometry :: %{
           required(String.t()) => pos_integer() | %{required(String.t()) => pos_integer()}
         }

  @doc "The themes every scenario renders in: the default dark theme, astrodark, and a light theme."
  @spec themes() :: [atom()]
  def themes, do: @themes

  @doc "The terminal sizes every scenario renders at, as `{cols, rows}`."
  @spec tui_sizes() :: [{pos_integer(), pos_integer()}]
  def tui_sizes, do: @tui_sizes

  @doc "Every target a scenario renders at: each frontend, theme and size."
  @spec targets() :: [target()]
  def targets do
    for theme <- @themes, target <- size_targets(), do: Map.put(target, :theme, theme)
  end

  @doc "The targets a journey strip renders at: the default theme, one size per frontend."
  @spec strip_targets() :: [target()]
  def strip_targets do
    for target <- size_targets(),
        target.size in [@strip_tui_size, @strip_macos_size],
        do: Map.put(target, :theme, @strip_theme)
  end

  @doc "The capabilities each frontend reports in its ready handshake, matching `EncodeReady` in Go and `encodeReady` in Swift."
  @spec capabilities(frontend()) :: Capabilities.t()
  def capabilities(:tui) do
    %Capabilities{
      frontend_type: :tui,
      color_depth: :rgb,
      unicode_width: :unicode_15,
      image_support: :none,
      float_support: :emulated,
      text_rendering: :monospace,
      semantic_ui: true
    }
  end

  def capabilities(:macos) do
    %Capabilities{
      frontend_type: :native_gui,
      color_depth: :rgb,
      unicode_width: :unicode_15,
      image_support: :native,
      float_support: :native,
      text_rendering: :proportional,
      semantic_ui: true
    }
  end

  @doc """
  Drives a session to the scenario for one target, with every packet recorded.

  `keys` are key paths pressed after the scenario is reached; journey strips use them to walk their steps. The caller stops the session.
  """
  @spec drive(String.t() | Entry.t(), target(), [String.t()], String.t() | nil) :: Session.t()
  def drive(id_or_entry, target, keys \\ [], name \\ nil) do
    name = name || scenario_id(id_or_entry)

    session =
      Registry.drive(id_or_entry,
        root: project_root(name, target),
        rendering: :enabled,
        record_packets: true,
        theme: target.theme,
        capabilities: capabilities(target.frontend),
        width: target.cols,
        height: target.grid_rows
      )

    keys
    |> Enum.reduce(session, &Session.press(&2, &1))
    |> Session.await_frame()
    |> fit_tui_header(target)
  end

  # The conversation can add a workspace header row. Other scenes keep their measured grid fixtures.
  @spec fit_tui_header(Session.t(), target()) :: Session.t()
  defp fit_tui_header(session, %{frontend: :tui, cols: cols} = target) do
    case grid_rows(session, target) do
      rows when rows == target.grid_rows -> session
      rows -> Session.resize(session, cols, rows)
    end
  end

  defp fit_tui_header(session, _target), do: session

  @spec grid_rows(Session.t(), target()) :: pos_integer()
  defp grid_rows(session, %{frontend: :tui, rows: rows, cols: cols} = target) do
    case Session.conversation_header_rows(session, cols, @tui_breadcrumb_min_cols) do
      nil -> target.grid_rows
      header_rows -> rows - header_rows
    end
  end

  defp grid_rows(_session, target), do: target.grid_rows

  @doc """
  The project directory a capture runs in: the same on every machine, because the chrome shows its path.

  It is unique per capture name, frontend and size, so concurrent captures never share it; the themes of one size run one after another.
  """
  @spec project_root(String.t(), target()) :: Path.t()
  def project_root(name, target),
    do: Path.join(["/tmp/minga-storyboard", "#{target.frontend}-#{target.size}", name])

  @doc "The transcript for one capture, as JSON-ready data."
  @spec transcript(String.t(), target(), [binary()]) :: map()
  def transcript(name, target, packets) do
    %{
      "version" => 1,
      "scenario" => name,
      "frontend" => Atom.to_string(target.frontend),
      "theme" => Atom.to_string(target.theme),
      "size" => target.size,
      "cols" => target.cols,
      "rows" => target.rows,
      "grid_rows" => target.grid_rows,
      "prompt" => prompt_fit_json(target.prompt_fit),
      "window" => window(target.window),
      "digest" => digest(packets),
      "packets" => Enum.map(packets, &Base.encode64/1)
    }
  end

  @doc """
  A digest of what the packets draw, the same on every run and machine.

  Frame sequence numbers, the recovery generation and the echoed input sequence count up per run, so the digest zeroes them in the begin and commit commands that open and close each frame. CI compares the macOS digests with the ones recorded at promotion to decide whether macOS must draw again.
  """
  @spec digest([binary()]) :: String.t()
  def digest(packets) do
    packets
    |> Enum.map(&normalize_frame_header/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @begin_frame Minga.Protocol.Opcodes.begin_frame()
  @commit_frame Minga.Protocol.Opcodes.commit_frame()

  @spec normalize_frame_header(binary()) :: binary()
  defp normalize_frame_header(<<@begin_frame, _ids::binary-size(12), rest::binary>>) do
    body_size = byte_size(rest) - 9

    case rest do
      <<body::binary-size(^body_size), @commit_frame, _seqs::binary-size(8)>>
      when body_size >= 0 ->
        <<@begin_frame, 0::96, body::binary, @commit_frame, 0::64>>

      _unframed ->
        <<@begin_frame, 0::96, rest::binary>>
    end
  end

  defp normalize_frame_header(packet), do: packet

  @doc "The transcript file name for a target: `<frontend>-<theme>-<size>.json`."
  @spec file_name(target()) :: String.t()
  def file_name(target), do: "#{target.frontend}-#{target.theme}-#{target.size}.json"

  @doc """
  Writes every transcript and the manifest under `dir`.

  Layout: `dir/manifest.json`, and `dir/transcripts/<name>/<frontend>-<theme>-<size>.json`, where `name` is a scenario id or a journey frame (`journey.<slug>.<step>`). Pending scenarios appear in the manifest with the ticket they wait on and have no transcripts.
  """
  @spec export!(Path.t()) :: :ok
  def export!(dir) do
    Enum.each(exported_scenarios(), &export_scenario!(dir, &1))
    export_journeys!(dir)
  end

  @doc "The built, designed scenarios the export renders."
  @spec exported_scenarios() :: [Entry.t()]
  def exported_scenarios, do: Enum.filter(Registry.built(), &designed?(&1.id))

  @doc "Writes one scenario's transcripts for every target under `dir/transcripts/<id>/`."
  @spec export_scenario!(Path.t(), Entry.t()) :: :ok
  def export_scenario!(dir, %Entry{} = entry) do
    transcripts = Path.join(dir, "transcripts")
    Enum.each(targets(), &capture!(transcripts, entry.id, entry, [], &1))
  end

  @doc "Writes the journey strips' transcripts and the manifest under `dir`."
  @spec export_journeys!(Path.t()) :: :ok
  def export_journeys!(dir) do
    transcripts = Path.join(dir, "transcripts")
    File.mkdir_p!(transcripts)
    journeys = Enum.map(Journeys.all(), &export_journey!(transcripts, &1))
    write_json!(Path.join(dir, "manifest.json"), manifest(journeys))
  end

  @spec capture!(Path.t(), String.t(), String.t() | Entry.t(), [String.t()], target()) :: :ok
  defp capture!(transcripts, name, scenario, keys, target) do
    {session, target} = scenario |> drive(target, keys, name) |> fit_native_chrome(target)
    packets = session |> Session.packets() |> Enum.map(&pin_session_start/1)
    target = %{target | grid_rows: grid_rows(session, target)}
    Session.stop(session)
    path = Path.join([transcripts, name, file_name(target)])
    File.mkdir_p!(Path.dirname(path))
    write_json!(path, transcript(name, target, packets))
  end

  # The grid a frontend reports depends on the chrome around the editor (ADR-0001): on macOS the file tree and
  # Git status are a native sidebar beside the editor, so the editor's grid narrows while one is open; the tasks drawer
  # and the minibuffer prompt beneath it are native views below the editor, so the grid shrinks while they are open; the
  # project home (`empty_state`) draws no tab bar or breadcrumb on either frontend, so its grid grows.
  # A target's `chrome_grid` maps the grid-changing chrome open at the reached frame, joined with "+", to the grid the
  # frontend reports then. The capture does what that report does in production: it resizes the editor to that grid.
  @grid_chrome [
    :empty_state,
    :file_tree,
    :git_status,
    :tasks_drawer,
    :minibuffer,
    :agent_chat,
    :agent_activity
  ]

  # The Agent activity strip takes a row only above a conversation, so it changes the key
  # ("agent_chat+agent_activity") but needs no entry alone.
  @native_below %{
    macos: [:file_tree, :git_status, :tasks_drawer, :minibuffer, :agent_chat],
    tui: []
  }

  @spec fit_native_chrome(Session.t(), target()) :: {Session.t(), target()}
  defp fit_native_chrome(session, target) do
    fitted = fitted_target(target, Session.model(session))

    session =
      if {fitted.cols, fitted.grid_rows} == {target.cols, target.grid_rows},
        do: session,
        else: Session.resize(session, fitted.cols, fitted.grid_rows)

    {relay_prompt_fit(session, fitted.prompt_fit), fitted}
  end

  # The capture relays the native composer's measured fit after the window grid.
  @spec relay_prompt_fit(Session.t(), {pos_integer(), pos_integer()} | nil) :: Session.t()
  defp relay_prompt_fit(session, {cols, rows}), do: Session.fit_prompt(session, cols, rows)
  defp relay_prompt_fit(session, nil), do: session

  @doc """
  The target with the grid its frontend reports for the chrome open in `model`, from the target's `chrome_grid`.

  Chrome without an entry keeps the target's default grid, unless the frontend draws it natively around the editor: then the entry is missing and this raises, naming the key to add to `test/storyboard/macos_geometry.json`.
  """
  @spec fitted_target(target(), Model.t()) :: target()
  def fitted_target(%{frontend: frontend, chrome_grid: chrome_grid} = target, %Model{} = model) do
    open = Enum.filter(@grid_chrome, &Model.open?(model, &1))
    key = Enum.map_join(open, "+", &Atom.to_string/1)

    case Map.fetch(chrome_grid, key) do
      {:ok, grid} ->
        apply_grid(target, grid)

      :error ->
        if Enum.any?(open, &(&1 in Map.fetch!(@native_below, frontend))) do
          raise ArgumentError,
                "#{frontend} at #{target.size} shows #{key} beside or below the editor, but its chrome_grid has no " <>
                  "#{inspect(key)} entry; add the grid that frontend reports to test/storyboard/macos_geometry.json"
        end

        target
    end
  end

  # A conversation opens with "Session started · HH:MM:SS UTC", the wall clock of
  # this run. A frame must be the same on every run, so a capture shows one fixed
  # time. It has the same length, so every length in the packet stays true.
  @session_start ~r/(Session started · )\d\d:\d\d:\d\d( UTC)/

  @spec pin_session_start(binary()) :: binary()
  defp pin_session_start(packet),
    do: Regex.replace(@session_start, packet, "\\g{1}09:41:00\\g{2}")

  # In the TUI an entry sets only the grid below the header; the terminal size stays.
  @spec apply_grid(target(), chrome_geometry()) :: target()
  defp apply_grid(%{frontend: :tui} = target, %{"rows" => rows}), do: %{target | grid_rows: rows}

  defp apply_grid(target, %{"rows" => rows} = grid) do
    %{
      target
      | cols: Map.get(grid, "cols", target.cols),
        rows: rows,
        grid_rows: rows,
        prompt_fit: prompt_fit(grid)
    }
  end

  @spec prompt_fit(chrome_geometry()) :: {pos_integer(), pos_integer()} | nil
  defp prompt_fit(%{"prompt" => %{"cols" => cols, "rows" => rows}}), do: {cols, rows}
  defp prompt_fit(_grid), do: nil

  @spec prompt_fit_json({pos_integer(), pos_integer()} | nil) :: map() | nil
  defp prompt_fit_json({cols, rows}), do: %{"cols" => cols, "rows" => rows}
  defp prompt_fit_json(nil), do: nil

  # The TUI header holds the tab bar, and the breadcrumb from 100 columns up; the home shows neither, so the TUI
  # reports one more row there (its title row stays).
  @spec tui_chrome_grid(pos_integer(), pos_integer()) :: %{
          String.t() => %{String.t() => pos_integer()}
        }
  defp tui_chrome_grid(cols, rows) do
    if tui_header_rows(cols) > 1, do: %{"empty_state" => %{"rows" => rows - 1}}, else: %{}
  end

  # A strip frame is drawn by driving a fresh session to the journey's start and replaying the steps up to it.
  @spec export_journey!(Path.t(), Journeys.t()) :: map()
  defp export_journey!(transcripts, journey) do
    slug = slug(journey.name)
    {outcome, frames} = journey_outcome(Journeys.run(journey))

    strip =
      frames
      |> Enum.with_index()
      |> Enum.map(fn {frame, index} ->
        name = "journey.#{slug}.#{index}"
        keys = journey.steps |> Enum.take(index) |> Enum.map(&(&1.press || &1.key))

        for target <- strip_targets(),
            do: capture!(transcripts, name, journey.start, keys, target)

        %{"name" => name, "scenario" => frame.scenario, "keys" => frame.keys}
      end)

    Map.merge(%{"name" => journey.name, "slug" => slug, "frames" => strip}, outcome)
  end

  @spec journey_outcome(Journeys.outcome()) :: {map(), [Journeys.frame()]}
  defp journey_outcome({:ok, frames}), do: {%{"outcome" => "complete"}, frames}

  defp journey_outcome({:pending, scenario, issue, frames}),
    do: {%{"outcome" => "pending", "pending_scenario" => scenario, "issue" => issue}, frames}

  defp journey_outcome({:error, message, _frames}),
    do: raise(ArgumentError, "a journey failed while rendering its strip: #{message}")

  @spec manifest([map()]) :: map()
  defp manifest(journeys) do
    %{
      "version" => 1,
      "themes" => Enum.map(@themes, &Atom.to_string/1),
      "strip_theme" => Atom.to_string(@strip_theme),
      "targets" => Enum.map(size_targets(), &target_json/1),
      "scenarios" => Enum.map(Inventory.designed_ids(), &scenario_json/1),
      "journeys" => journeys
    }
  end

  @spec scenario_json(String.t()) :: map()
  defp scenario_json(id) do
    scenario = Inventory.fetch!(id)

    status =
      case Registry.fetch(id) do
        {:ok, %Entry{status: :built}} -> %{"status" => "built"}
        {:ok, %Entry{status: {:pending, issue, reason}}} -> pending(issue, reason)
        :error -> pending(nil, "no registry entry")
      end

    Map.merge(status, %{
      "id" => id,
      "journey" => scenario["journey"],
      "title" => scenario["title"],
      "frontends" => Map.get(scenario, "frontends", ["macos", "tui"]),
      "platform_only_reason" => scenario["platform_only_reason"],
      "boards" => Map.get(scenario, "boards", %{})
    })
  end

  @spec pending(pos_integer() | nil, String.t()) :: map()
  defp pending(issue, reason), do: %{"status" => "pending", "issue" => issue, "reason" => reason}

  @spec designed?(String.t()) :: boolean()
  defp designed?(id), do: id in Inventory.designed_ids()

  @spec size_targets() :: [target()]
  defp size_targets do
    tui =
      for {cols, rows} <- @tui_sizes do
        %{
          frontend: :tui,
          size: "#{cols}x#{rows}",
          cols: cols,
          rows: rows,
          grid_rows: rows - tui_header_rows(cols),
          window: nil,
          chrome_grid: tui_chrome_grid(cols, rows),
          prompt_fit: nil
        }
      end

    macos =
      for %{"width" => width, "height" => height, "cols" => cols, "rows" => rows} = window <-
            @macos_geometry["windows"] do
        %{
          frontend: :macos,
          size: "#{width}",
          cols: cols,
          rows: rows,
          grid_rows: rows,
          window: {width, height},
          chrome_grid: Map.get(window, "chrome_grid", %{}),
          prompt_fit: nil
        }
      end

    tui ++ macos
  end

  @spec tui_header_rows(pos_integer()) :: pos_integer()
  defp tui_header_rows(cols) when cols >= @tui_breadcrumb_min_cols, do: 2
  defp tui_header_rows(_cols), do: 1

  @spec target_json(target()) :: map()
  defp target_json(target) do
    %{
      "frontend" => Atom.to_string(target.frontend),
      "size" => target.size,
      "cols" => target.cols,
      "rows" => target.rows,
      "window" => window(target.window)
    }
  end

  @spec window({pos_integer(), pos_integer()} | nil) :: map() | nil
  defp window(nil), do: nil
  defp window({width, height}), do: %{"width" => width, "height" => height}

  @spec scenario_id(String.t() | Entry.t()) :: String.t()
  defp scenario_id(%Entry{id: id}), do: id
  defp scenario_id(id) when is_binary(id), do: id

  @spec slug(String.t()) :: String.t()
  defp slug(name) do
    name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")
  end

  @spec write_json!(Path.t(), map()) :: :ok
  defp write_json!(path, data), do: File.write!(path, JSON.encode!(data) <> "\n")
end
