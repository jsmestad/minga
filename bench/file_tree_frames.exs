defmodule Minga.Bench.FileTreeFrames do
  @moduledoc """
  File-tree frame cost (ticket #3493).

  The renderer rebuilds the whole file-tree semantic model on every frame, including frames where nothing in the tree changed and frames where the sidebar is hidden but the tree is loaded. This script measures that work at three tree sizes and separates its stages.

  Two parts:

    * **Stages.** For each size, the script times tree scanning (`Minga.Project.FileTree.refresh/1`), semantic model construction (`FileTreeBuilder.build/1`), and GUI encoding (`FileTreeEncoder.encode/2` against warm caches, which is the unchanged-frame path, and against empty caches, which is the full re-send path). Each stage sample runs in a fresh process, so no sample inherits another sample's heap. It also records deterministic work counters for one model build and the word sizes of the Editor-to-Renderer file-tree state and the built model.
    * **Consumer path.** For each size, the script starts a real Editor generation (Editor, `Renderer.Server`, semantic GUI encoder and `HeadlessPort`), opens the file tree on the fixture with every directory expanded, and times six frame kinds from the input to the committed frame:
      * `unchanged`: `j`/`k` in the editor buffer while the tree is visible and unfocused. The tree model does not change.
      * `hidden`: the same keys while the sidebar is hidden but the tree stays loaded.
      * `select`: `j`/`k` in the focused tree.
      * `toggle`: `TAB` on a leaf directory, collapsing and expanding its 100 files.
      * `git`: a git status event marking 50 files modified, alternating with one marking a different 50.
      * `fs`: a completed filesystem refresh that adds one file, alternating with one that removes it. The rescan runs before the sample starts; the sample covers acceptance through the frame.

  The headless backend renders synchronously: the Editor calls its `Renderer.Server` and waits, so a sample covers Editor dispatch, the Editor-to-Renderer copy of the file-tree state, model construction, encoding and the headless frontend's decode.

  Each consumer sample records wall microseconds, VM-wide exact reductions and VM-wide garbage-collected words for the interval. After the samples the script runs two traced frames per kind to count model builds and filetype registry reads, then records the Editor and Renderer process memory.

  Fixture: N files in directories of 100, 20 directories per package, all expanded, with ten source extensions and unique file names, plus a 2,000-line `README.md` that is the active buffer. Fixtures are cached under the system temp directory and reused across runs.

  Run with:

      MIX_ENV=test mix run bench/file_tree_frames.exs

  Set `MINGA_BENCH_TREE_OUT` to choose the JSON output path and `MINGA_BENCH_TREE_LABEL` to tag the run (for example `baseline` or `candidate`). Set `MINGA_BENCH_TREE_QUICK=1` to run 1,000 and 10,000 entries only.
  """

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Frontend.Adapter.GUI.Caches, as: GUICaches
  alias Minga.Frontend.Adapter.GUI.FileTreeEncoder
  alias Minga.Project.FileTree
  alias Minga.Test.HeadlessPort
  alias MingaEditor.Commands
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FileTree.Freshness
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.FileTreeBuilder
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.FileTree, as: FileTreeState

  @per_dir 100
  @dirs_per_package 20
  @exts ~w(ex exs rs ts tsx md json go swift zig)
  @readme_lines 2_000
  @stage_samples 10
  @warmup 3
  @samples 20
  @traced_frames 2
  @tab 9

  @caps %Capabilities{
    frontend_type: :native_gui,
    float_support: :native,
    image_support: :native,
    semantic_ui: true
  }

  @spec run() :: :ok
  def run do
    quick? = System.get_env("MINGA_BENCH_TREE_QUICK") == "1"
    label = System.get_env("MINGA_BENCH_TREE_LABEL", "run")

    out =
      System.get_env(
        "MINGA_BENCH_TREE_OUT",
        Path.join(System.tmp_dir!(), "minga_file_tree_frames_#{label}.json")
      )

    # The test environment routes git through an in-memory stub; the fixture is
    # not a repository, so the stub only needs its table to answer "not git".
    Minga.Git.Stub.ensure_table()

    sizes = sizes(quick?)
    parts = System.get_env("MINGA_BENCH_TREE_PARTS", "stages,consumer") |> String.split(",")

    results = Enum.map(sizes, &size_result(&1, parts))

    write(out, label, results)
    print(results)
    IO.puts("raw samples: #{out}")
    :ok
  end

  @spec sizes(boolean()) :: [pos_integer()]
  defp sizes(quick?) do
    case System.get_env("MINGA_BENCH_TREE_SIZES") do
      nil when quick? -> [1_000, 10_000]
      nil -> [1_000, 10_000, 50_000]
      list -> list |> String.split(",") |> Enum.map(&String.to_integer/1)
    end
  end

  @spec size_result(pos_integer(), [String.t()]) :: {String.t(), map()}
  defp size_result(n, parts) do
    root = fixture(n)
    stages = part(n, parts, "stages", fn -> stages(root) end)
    consumer = part(n, parts, "consumer", fn -> consumer(root) end)
    {"n#{n}", %{files: n, stages: stages, consumer: consumer}}
  end

  @spec part(pos_integer(), [String.t()], String.t(), (-> map())) :: map() | nil
  defp part(n, parts, name, fun) do
    if name in parts do
      IO.puts("size #{n}: #{name}")
      fun.()
    end
  end

  # ── Fixture ────────────────────────────────────────────────────────────────

  @spec fixture(pos_integer()) :: String.t()
  defp fixture(n) do
    root = Path.join(System.tmp_dir!(), "minga_file_tree_bench_#{n}")
    stamp = Path.join(root, ".complete")

    unless File.exists?(stamp) do
      File.rm_rf!(root)

      Enum.each(0..(div(n, @per_dir) - 1), &write_module_dir(root, &1))

      readme = Enum.map_join(1..@readme_lines, "\n", &"line #{&1} of the bench readme")
      File.write!(Path.join(root, "README.md"), readme)
      File.write!(stamp, "")
    end

    root
  end

  # One leaf directory of @per_dir files with unique names and mixed extensions.
  @spec write_module_dir(String.t(), non_neg_integer()) :: :ok
  defp write_module_dir(root, d) do
    dir = Path.join([root, "pkg_#{div(d, @dirs_per_package)}", "mod_#{d}"])
    File.mkdir_p!(dir)
    Enum.each(0..(@per_dir - 1), &File.write!(Path.join(dir, "m#{d}_f#{&1}.#{ext(&1)}"), ""))
  end

  @spec expanded_tree(String.t()) :: FileTree.t()
  defp expanded_tree(root) do
    root
    |> all_dirs()
    |> Enum.reduce(FileTree.new(root), &FileTree.expand_path(&2, &1))
    |> FileTree.ensure_entries()
  end

  @spec all_dirs(String.t()) :: [String.t()]
  defp all_dirs(root) do
    root
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
  end

  # ── Stages ─────────────────────────────────────────────────────────────────

  @spec stages(String.t()) :: map()
  defp stages(root) do
    tree = expanded_tree(root)
    ctx = stage_context(tree)
    model = FileTreeBuilder.build(ctx)
    {_binary, warm_caches} = FileTreeEncoder.encode(model, GUICaches.new())

    %{
      entries: length(tree.entries),
      file_tree_state_words: :erts_debug.flat_size(ctx.workspace.file_tree),
      model_words: :erts_debug.flat_size(model),
      encoded_bytes: byte_size(FileTreeEncoder.encode_command(model)),
      build_counters: counted(fn -> FileTreeBuilder.build(ctx) end),
      scan: isolated_samples(fn -> FileTree.refresh(tree) end),
      build: isolated_samples(fn -> FileTreeBuilder.build(ctx) end),
      encode_unchanged: isolated_samples(fn -> FileTreeEncoder.encode(model, warm_caches) end),
      encode_full: isolated_samples(fn -> FileTreeEncoder.encode(model, GUICaches.new()) end)
    }
  end

  @spec stage_context(FileTree.t()) :: Context.t()
  defp stage_context(tree) do
    file_tree = FileTreeState.open(%FileTreeState{}, tree, nil)

    MingaEditor.RenderPipeline.TestHelpers.base_state(port_manager: nil)
    |> put_file_tree(file_tree)
    |> Context.from_editor_state()
  end

  # Runs each sample in a fresh process so heap growth from earlier samples
  # does not charge later ones with garbage collection.
  @spec isolated_samples((-> term())) :: [map()]
  defp isolated_samples(fun) do
    Enum.map(1..@stage_samples, fn _ ->
      task =
        Task.async(fn ->
          {_, _} = :erlang.statistics(:exact_reductions)
          started = System.monotonic_time(:microsecond)
          _ = fun.()
          wall = System.monotonic_time(:microsecond) - started
          {_, reductions} = :erlang.statistics(:exact_reductions)
          %{wall_us: wall, reductions: reductions}
        end)

      Task.await(task, :infinity)
    end)
  end

  # ── Consumer path ──────────────────────────────────────────────────────────

  @spec consumer(String.t()) :: map()
  defp consumer(root) do
    with_editor(root, fn ctx ->
      open_expanded_tree(ctx, root)
      command(ctx, &Commands.execute(&1, :window_right))
      unchanged = keys(ctx, ?j, ?k)
      unchanged_counters = traced(fn -> key(ctx, ?j, 0) end)

      command(ctx, &Commands.execute(&1, :toggle_file_tree))
      hidden = keys(ctx, ?j, ?k)
      hidden_counters = traced(fn -> key(ctx, ?j, 0) end)

      command(ctx, &Commands.execute(&1, :toggle_file_tree))
      select = keys(ctx, ?j, ?k)
      select_counters = traced(fn -> key(ctx, ?j, 0) end)

      # Index 1 is pkg_0/mod_0, a leaf directory with 100 files.
      command(ctx, &update_tree(&1, fn tree -> FileTree.select(tree, 1) end))
      toggle = keys(ctx, @tab, @tab)
      toggle_counters = traced(fn -> key(ctx, @tab, 0) end)

      git = measure(fn i -> git_event(ctx, root, i) end)
      git_counters = traced(fn -> git_event(ctx, root, 0) end)

      fs = measure(fn i -> fs_update(ctx, root, i) end)
      fs_counters = traced(fn -> fs_update(ctx, root, 0) end)
      File.rm(Path.join([root, "pkg_0", "mod_0", "bench_added.ex"]))

      %{
        unchanged: %{samples: unchanged, counters: unchanged_counters},
        hidden: %{samples: hidden, counters: hidden_counters},
        select: %{samples: select, counters: select_counters},
        toggle: %{samples: toggle, counters: toggle_counters},
        git: %{samples: git, counters: git_counters},
        fs: %{samples: fs, counters: fs_counters},
        memory: process_memory(ctx)
      }
    end)
  end

  @spec with_editor(String.t(), (map() -> map())) :: map()
  defp with_editor(root, fun) do
    id = System.unique_integer([:positive])
    width = 160
    height = 50
    sidebar_registry = :"minga_tree_bench_sidebar_#{id}"
    {:ok, sidebar} = Sidebar.start_link(name: sidebar_registry, notify: false)
    {:ok, port} = HeadlessPort.start_link(width: width, height: height, capabilities: @caps)
    path = Path.join(root, "README.md")
    {:ok, buffer} = BufferProcess.start_link(content: File.read!(path), file_path: path)

    {:ok, generation} =
      MingaEditor.GenerationSupervisor.start_editor_generation_link(
        name: :"tree_bench_editor_#{id}",
        backend: :headless,
        port_manager: port,
        buffer: buffer,
        width: width,
        height: height,
        editing_model: :vim,
        sidebar_registry: sidebar_registry,
        suppress_tool_prompts: true
      )

    {:ok, editor} = MingaEditor.GenerationSupervisor.editor_owner(generation)
    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:ready, width, height}})
    {:ok, _} = HeadlessPort.collect_frame(ref, 60_000)
    ctx = %{editor: editor, port: port}

    try do
      fun.(ctx)
    after
      Enum.each([generation, buffer, port, sidebar], &stop/1)
    end
  end

  # Opens the tree through the real command, then expands every directory
  # through the tree's owner API so the resident model holds all N files.
  @spec open_expanded_tree(map(), String.t()) :: :ok
  defp open_expanded_tree(ctx, root) do
    command(ctx, fn state ->
      state
      |> put_file_tree(FileTreeState.set_project_root(state.workspace.file_tree, root))
      |> Commands.execute(:toggle_file_tree)
    end)

    dirs = all_dirs(root)

    expand_all = fn tree ->
      dirs |> Enum.reduce(tree, &FileTree.expand_path(&2, &1)) |> FileTree.refresh()
    end

    command(ctx, &update_tree(&1, expand_all))
  end

  @spec update_tree(map(), (FileTree.t() -> FileTree.t())) :: map()
  defp update_tree(state, fun) do
    file_tree = state.workspace.file_tree
    tree = file_tree |> FileTreeState.tree() |> fun.()
    put_file_tree(state, FileTreeState.replace_tree_metadata(file_tree, tree))
  end

  @spec put_file_tree(map(), FileTreeState.t()) :: map()
  defp put_file_tree(state, file_tree) do
    %{state | workspace: SessionState.set_file_tree(state.workspace, file_tree)}
  end

  @spec command(map(), (map() -> map())) :: :ok
  defp command(%{editor: editor, port: port}, fun) do
    ref = HeadlessPort.prepare_await(port)

    :sys.replace_state(
      editor,
      fn state -> state |> fun.() |> MingaEditor.Renderer.render() end,
      120_000
    )

    {:ok, _} = HeadlessPort.collect_frame(ref, 120_000)
    :ok
  end

  # A git status event through the Editor's real handler. Even and odd samples
  # mark different 50-file sets so every sample changes the badges.
  @spec git_event(map(), String.t(), non_neg_integer()) :: map()
  defp git_event(%{editor: editor, port: port}, root, i) do
    offset = rem(i, 2) * 50

    entries =
      for f <- offset..(offset + 49) do
        %Minga.Git.StatusEntry{
          path: "pkg_0/mod_0/m0_f#{rem(f, @per_dir)}.#{ext(f)}",
          status: :modified,
          staged: false
        }
      end

    event = %Minga.Events.GitStatusEvent{
      git_root: root,
      entry_base_path: root,
      entries: entries,
      branch: "main",
      ahead: 0,
      behind: 0
    }

    sync(editor)
    ref = HeadlessPort.prepare_await(port)

    sample(
      fn ->
        :sys.replace_state(
          editor,
          fn state ->
            state |> Freshness.refresh_git_status(event) |> MingaEditor.Renderer.render()
          end,
          120_000
        )
      end,
      ref
    )
  end

  # A completed filesystem refresh. The file is added or removed and the tree
  # rescanned before the sample starts, so the sample covers acceptance through
  # the Editor's file-tree owner and the resulting frame, not the scan.
  @spec fs_update(map(), String.t(), non_neg_integer()) :: map()
  defp fs_update(%{editor: editor, port: port}, root, i) do
    added = Path.join([root, "pkg_0", "mod_0", "bench_added.ex"])
    if rem(i, 2) == 0, do: File.write!(added, ""), else: File.rm(added)

    live = :sys.get_state(editor, 120_000).workspace.file_tree |> FileTreeState.tree()
    refreshed = FileTree.refresh(live)
    token = make_ref()
    ref = HeadlessPort.prepare_await(port)

    sample(
      fn ->
        :sys.replace_state(
          editor,
          fn state ->
            file_tree =
              FileTreeState.track_refresh_request(state.workspace.file_tree, root, token)

            {:accepted, file_tree} =
              FileTreeState.accept_refresh_result(file_tree, root, token, refreshed)

            state |> put_file_tree(file_tree) |> MingaEditor.Renderer.render()
          end,
          120_000
        )
      end,
      ref
    )
  end

  @spec ext(non_neg_integer()) :: String.t()
  defp ext(f), do: Enum.at(@exts, rem(f, length(@exts)))

  # ── Measurement ────────────────────────────────────────────────────────────

  @spec keys(map(), char(), char()) :: [map()]
  defp keys(ctx, even, odd) do
    Enum.each(1..@warmup, fn i -> key(ctx, alternate(i, even, odd), 0) end)
    measure(fn i -> key(ctx, alternate(i, even, odd), 0) end)
  end

  @spec alternate(integer(), char(), char()) :: char()
  defp alternate(i, even, odd), do: if(rem(i, 2) == 0, do: even, else: odd)

  @spec measure((non_neg_integer() -> map())) :: [map()]
  defp measure(fun), do: Enum.map(1..@samples, fun)

  @spec key(map(), non_neg_integer(), non_neg_integer()) :: map()
  defp key(%{editor: editor, port: port}, codepoint, mods) do
    sync(editor)
    ref = HeadlessPort.prepare_await(port)
    sample(fn -> send(editor, {:minga_input, {:key_press, codepoint, mods, 0}}) end, ref)
  end

  @spec sync(pid()) :: :ok
  defp sync(editor) do
    _ = :sys.get_state(editor, 120_000)
    :ok
  end

  @spec sample((-> term()), reference()) :: map()
  defp sample(action, ref) do
    {_, _} = :erlang.statistics(:exact_reductions)
    {_, gc_words_before, _} = :erlang.statistics(:garbage_collection)
    started = System.monotonic_time(:microsecond)
    action.()

    case HeadlessPort.collect_frame(ref, 120_000) do
      {:ok, _} -> :ok
      {:error, :timeout} -> raise "timed out waiting for a frame"
    end

    wall = System.monotonic_time(:microsecond) - started
    {_, reductions} = :erlang.statistics(:exact_reductions)
    {_, gc_words_after, _} = :erlang.statistics(:garbage_collection)
    %{wall_us: wall, reductions: reductions, gc_words: gc_words_after - gc_words_before}
  end

  # Deterministic work counters: how many times the frame built file-tree rows
  # and how many times it read the filetype registry. Counted on separate frames
  # so call tracing never inflates the timed samples.
  @counted [
    {MingaEditor.FileTree.Rows, :from_tree, 2},
    {Minga.Language.Filetype.Registry, :_, :_}
  ]

  @spec traced((-> term())) :: map()
  defp traced(frame) do
    Enum.reduce(1..@traced_frames, %{}, fn _, acc ->
      Map.merge(acc, counted(frame), fn _key, a, b -> a + b end)
    end)
    |> Map.new(fn {name, calls} -> {name, calls / @traced_frames} end)
  end

  @spec counted((-> term())) :: %{String.t() => non_neg_integer()}
  defp counted(fun) do
    Enum.each(@counted, &:erlang.trace_pattern(&1, true, [:call_count]))
    _ = fun.()
    counts = call_counts()
    Enum.each(@counted, &:erlang.trace_pattern(&1, false, [:call_count]))
    counts
  end

  @spec call_counts() :: %{String.t() => non_neg_integer()}
  defp call_counts do
    rows =
      case :erlang.trace_info({MingaEditor.FileTree.Rows, :from_tree, 2}, :call_count) do
        {:call_count, n} when is_integer(n) -> n
        _ -> 0
      end

    registry =
      Minga.Language.Filetype.Registry.__info__(:functions)
      |> Enum.map(fn {name, arity} ->
        case :erlang.trace_info({Minga.Language.Filetype.Registry, name, arity}, :call_count) do
          {:call_count, n} when is_integer(n) -> n
          _ -> 0
        end
      end)
      |> Enum.sum()

    %{"row_builds" => rows, "registry_reads" => registry}
  end

  @spec process_memory(map()) :: map()
  defp process_memory(%{editor: editor}) do
    renderer = :sys.get_state(editor, 120_000).render.renderer

    %{
      editor_bytes: process_bytes(editor),
      renderer_bytes: if(is_pid(renderer), do: process_bytes(renderer))
    }
  end

  @spec process_bytes(pid()) :: non_neg_integer()
  defp process_bytes(pid) do
    :erlang.garbage_collect(pid)
    {:memory, bytes} = Process.info(pid, :memory)
    bytes
  end

  @spec stop(pid()) :: :ok
  defp stop(pid) do
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      5_000 -> Process.exit(pid, :kill)
    end

    :ok
  end

  # ── Output ─────────────────────────────────────────────────────────────────

  @spec summary([map()]) :: map()
  defp summary(samples) do
    wall = Enum.map(samples, & &1.wall_us)
    reds = Enum.map(samples, & &1.reductions)
    gc = samples |> Enum.map(&Map.get(&1, :gc_words, 0))

    %{
      p10: pct(wall, 0.10),
      p50: pct(wall, 0.50),
      p90: pct(wall, 0.90),
      red_p50: pct(reds, 0.50),
      gc_p50: pct(gc, 0.50)
    }
  end

  @spec pct([number()], float()) :: number()
  defp pct([], _), do: 0

  defp pct(values, ratio) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(length(sorted) - 1, trunc(ratio * length(sorted))))
  end

  @spec print([{String.t(), map()}]) :: :ok
  defp print(results) do
    IO.puts("\n| Files | Stage | p10 µs | p50 µs | p90 µs | Reductions p50 |")
    IO.puts("|---:|---|---:|---:|---:|---:|")

    results
    |> Enum.filter(fn {_name, r} -> r.stages end)
    |> Enum.each(fn {_name, r} ->
      Enum.each([:scan, :build, :encode_unchanged, :encode_full], fn stage ->
        s = summary(Map.fetch!(r.stages, stage))
        IO.puts("| #{r.files} | #{stage} | #{s.p10} | #{s.p50} | #{s.p90} | #{s.red_p50} |")
      end)

      IO.puts(
        "| #{r.files} | sizes | entries #{r.stages.entries}, state words #{r.stages.file_tree_state_words}, model words #{r.stages.model_words}, encoded bytes #{r.stages.encoded_bytes}, build counters #{inspect(r.stages.build_counters)} | | | |"
      )
    end)

    IO.puts(
      "\n| Files | Frame | p10 µs | p50 µs | p90 µs | Reductions p50 | GC words p50 | Row builds/frame | Registry reads/frame |"
    )

    IO.puts("|---:|---|---:|---:|---:|---:|---:|---:|---:|")

    results
    |> Enum.filter(fn {_name, r} -> r.consumer end)
    |> Enum.each(fn {_name, r} ->
      Enum.each([:unchanged, :hidden, :select, :toggle, :git, :fs], fn kind ->
        %{samples: samples, counters: counters} = Map.fetch!(r.consumer, kind)
        s = summary(samples)

        IO.puts(
          "| #{r.files} | #{kind} | #{s.p10} | #{s.p50} | #{s.p90} | #{s.red_p50} | #{s.gc_p50} | #{counters["row_builds"]} | #{counters["registry_reads"]} |"
        )
      end)

      IO.puts("| #{r.files} | memory | #{inspect(r.consumer.memory)} | | | | | | |")
    end)
  end

  # Other work on the machine moves wall time; record it beside every run.
  @spec load_average() :: String.t()
  defp load_average do
    case System.cmd("uptime", []) do
      {out, 0} -> String.trim(out)
      _ -> ""
    end
  end

  @spec write(String.t(), String.t(), [{String.t(), map()}]) :: :ok
  defp write(out, label, results) do
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {dirty, 0} = System.cmd("git", ["status", "--porcelain", "--", "lib"])

    payload = %{
      label: label,
      commit: String.trim(commit),
      lib_dirty: dirty != "",
      otp: System.otp_release(),
      elixir: System.version(),
      schedulers: :erlang.system_info(:schedulers_online),
      arch: to_string(:erlang.system_info(:system_architecture)),
      load_average: load_average(),
      results: Map.new(results)
    }

    File.write!(out, JSON.encode!(payload))
    :ok
  end
end

Minga.Bench.FileTreeFrames.run()
