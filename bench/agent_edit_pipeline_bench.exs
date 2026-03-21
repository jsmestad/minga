# Benchmark: Full pipeline cost of filesystem agent edits
#
# Measures the downstream costs that the buffer GenServer path eliminates:
#   1. FSEvents detection latency (100ms debounce in Minga)
#   2. File.read inside buffer reload
#   3. Document.new (gap buffer reconstruction from full text)
#   4. Tree-sitter full reparse via parser port
#
# These costs are ADDED to the raw file I/O cost measured in agent_edit_bench.exs.
# The buffer GenServer path pays NONE of them.
#
# Run: mix run bench/agent_edit_pipeline_bench.exs

alias Minga.Buffer.Document

# --- Generate realistic files at different sizes ---

defmodule Bench.PipelineFileGen do
  def generate_elixir(line_count) do
    modules = div(line_count, 40)

    1..modules
    |> Enum.map(fn i ->
      """
      defmodule Bench.Mod#{i} do
        @moduledoc "Module #{i} for pipeline benchmarking."

        @type t :: %__MODULE__{id: integer(), name: String.t(), items: [term()]}
        @enforce_keys [:id, :name]
        defstruct [:id, :name, items: []]

        @spec new(integer(), String.t()) :: t()
        def new(id, name) when is_integer(id) and is_binary(name) do
          %__MODULE__{id: id, name: name}
        end

        @spec add_item(t(), term()) :: t()
        def add_item(%__MODULE__{} = state, item) do
          %{state | items: [item | state.items]}
        end

        @spec count(t()) :: non_neg_integer()
        def count(%__MODULE__{items: items}), do: length(items)

        @spec process(t(), (term() -> term())) :: t()
        def process(%__MODULE__{} = state, func) do
          %{state | items: Enum.map(state.items, func)}
        end

        @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
        def validate(%__MODULE__{name: ""}) do
          {:error, "name cannot be empty"}
        end

        def validate(%__MODULE__{} = state), do: {:ok, state}

        @spec summary(t()) :: String.t()
        def summary(%__MODULE__{id: id, name: name, items: items}) do
          count = length(items)
          "Mod#{i}(" <> Integer.to_string(id) <> ") " <> name <> ": " <> Integer.to_string(count)
        end
      end
      """
    end)
    |> Enum.join("\n")
  end
end

IO.puts("Generating test files...")

content_1k = Bench.PipelineFileGen.generate_elixir(1_000)
content_5k = Bench.PipelineFileGen.generate_elixir(5_000)
content_10k = Bench.PipelineFileGen.generate_elixir(10_000)

sizes = [
  {"1K lines (#{div(byte_size(content_1k), 1024)} KB)", content_1k},
  {"5K lines (#{div(byte_size(content_5k), 1024)} KB)", content_5k},
  {"10K lines (#{div(byte_size(content_10k), 1024)} KB)", content_10k}
]

for {label, _content} <- sizes do
  IO.puts("  #{label}")
end

IO.puts("")

tmp_dir = System.tmp_dir!()
file_path = Path.join(tmp_dir, "bench_pipeline.ex")

# ======================================================================
IO.puts("=" |> String.duplicate(70))
IO.puts("COMPONENT 1: FileWatcher Debounce Overhead")
IO.puts("  Fixed 100ms debounce per file change notification.")
IO.puts("  This is a wall-clock delay, not CPU cost.")
IO.puts("=" |> String.duplicate(70))
IO.puts("")
IO.puts("  FileWatcher debounce:     100ms (fixed, per file write)")
IO.puts("  Per 20 sequential edits:  100ms (debounce coalesces)")
IO.puts("  Per 20 rapid agent edits: 100ms × 20 = 2,000ms worst case")
IO.puts("  (if writes are >100ms apart, each triggers a separate event)")
IO.puts("")
IO.puts("  Buffer GenServer path:    0ms (no FileWatcher involved)")
IO.puts("")

# ======================================================================
IO.puts("=" |> String.duplicate(70))
IO.puts("COMPONENT 2: File.read (buffer reload reads from disk)")
IO.puts("  Every buffer reload reads the full file from disk.")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

File.write!(file_path, content_10k)

Benchee.run(
  %{
    "File.read 1K lines" => fn -> File.read!(file_path) end
  },
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

File.write!(file_path, content_5k)

Benchee.run(
  %{
    "File.read 5K lines" => fn -> File.read!(file_path) end
  },
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

File.write!(file_path, content_10k)

Benchee.run(
  %{
    "File.read 10K lines" => fn -> File.read!(file_path) end
  },
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# ======================================================================
IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("COMPONENT 3: Document.new (gap buffer reconstruction)")
IO.puts("  Buffer reload creates a fresh Document from the full file text.")
IO.puts("  This rebuilds the gap buffer and line index from scratch.")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

Benchee.run(
  for {label, content} <- sizes, into: %{} do
    {"Document.new #{label}", fn -> Document.new(content) end}
  end,
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# ======================================================================
IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("COMPONENT 4: Full buffer reload (File.read + Document.new)")
IO.puts("  What Buffer.Server.reload/1 actually does per file change.")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

Benchee.run(
  for {label, content} <- sizes, into: %{} do
    File.write!(file_path, content)

    {"full reload #{label}",
     fn ->
       text = File.read!(file_path)
       _doc = Document.new(text)
     end}
  end,
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# ======================================================================
IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("COMPONENT 5: Tree-sitter full reparse cost")
IO.puts("  After reload, the parser re-parses the entire file from scratch.")
IO.puts("  (Measured via Protocol.encode_parse_buffer — the encoding cost.)")
IO.puts("  (Actual parse happens in the Zig process; this is the BEAM overhead.)")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

alias Minga.Port.Protocol

Benchee.run(
  for {label, content} <- sizes, into: %{} do
    {"encode_parse_buffer #{label}",
     fn ->
       Protocol.encode_parse_buffer(1, 1, content)
     end}
  end,
  warmup: 1,
  time: 3,
  print: [configuration: false]
)

# ======================================================================
IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("TOTAL PIPELINE COST SUMMARY")
IO.puts("=" |> String.duplicate(70))
IO.puts("")
IO.puts("For each filesystem agent edit, the downstream pipeline adds:")
IO.puts("")
# Representative values from a prior run (Apple M5, macOS 26.3).
# These are NOT auto-populated from the benchmark above.
IO.puts("  ┌─────────────────────────────────┬──────────────────────┐")
IO.puts("  │ Stage                           │ Cost (1K / 5K / 10K) │")
IO.puts("  ├─────────────────────────────────┼──────────────────────┤")
IO.puts("  │ FileWatcher debounce            │ 100ms fixed          │")
IO.puts("  │ File.read (reload)              │ 25 / 19 / 25µs       │")
IO.puts("  │ Document.new (gap buffer)       │ 13 / 65 / 126µs      │")
IO.puts("  │ encode_parse_buffer (BEAM side) │ 0.6 / 2.2 / 4.5µs   │")
IO.puts("  │ Zig tree-sitter full reparse*   │ ~1 / ~5 / ~10ms      │")
IO.puts("  │ Highlight response processing   │ ~0.5 / ~1 / ~2ms     │")
IO.puts("  ├─────────────────────────────────┼──────────────────────┤")
IO.puts("  │ TOTAL per write                 │ ~102 / ~106 / ~112ms │")
IO.puts("  │ × 20 sequential edits           │ ~2.0 / ~2.1 / ~2.2s │")
IO.puts("  └─────────────────────────────────┴──────────────────────┘")
IO.puts("")
IO.puts("  * Zig reparse is measured separately (runs in the Zig process).")
IO.puts("    Typical: 1-3ms for 1K lines, 5-10ms for 10K lines.")
IO.puts("")
IO.puts("  The buffer GenServer path pays NONE of these costs.")
IO.puts("  Edits update the in-memory gap buffer directly.")
IO.puts("  Tree-sitter receives incremental EditDelta (bytes changed),")
IO.puts("  not the full file content.")
IO.puts("")

# Cleanup
File.rm(file_path)
