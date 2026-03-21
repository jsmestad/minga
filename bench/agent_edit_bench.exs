# Benchmark: Filesystem I/O vs Buffer GenServer for agent edits
#
# Simulates real agent editing patterns:
#   - Single edit (EditFile tool)
#   - Batch of 20 edits (MultiEditFile tool)
#   - 5 concurrent "agents" each making 10 edits (multi-agent scenario)
#
# Run: mix run bench/agent_edit_bench.exs

defmodule Bench.BufferServer do
  @moduledoc """
  Minimal GenServer simulating Buffer.Server with atomic find-and-replace.
  Holds file content in memory. No disk I/O, no FileWatcher, no reparse.
  """
  use GenServer

  def start_link(content) do
    GenServer.start_link(__MODULE__, content)
  end

  def find_and_replace(server, old_text, new_text) do
    GenServer.call(server, {:find_and_replace, old_text, new_text})
  end

  def find_and_replace_batch(server, edits) do
    GenServer.call(server, {:find_and_replace_batch, edits})
  end

  def content(server), do: GenServer.call(server, :content)

  # --- Callbacks ---

  @impl true
  def init(content), do: {:ok, content}

  @impl true
  def handle_call({:find_and_replace, old_text, new_text}, _from, content) do
    case do_replace(content, old_text, new_text) do
      {:ok, new_content} -> {:reply, {:ok, "applied"}, new_content}
      {:error, _} = err -> {:reply, err, content}
    end
  end

  def handle_call({:find_and_replace_batch, edits}, _from, content) do
    {final, results} =
      Enum.reduce(edits, {content, []}, fn {old_text, new_text}, {c, acc} ->
        case do_replace(c, old_text, new_text) do
          {:ok, new_c} -> {new_c, [{:ok, "applied"} | acc]}
          {:error, _} = err -> {c, [err | acc]}
        end
      end)

    {:reply, {:ok, Enum.reverse(results)}, final}
  end

  def handle_call(:content, _from, content) do
    {:reply, content, content}
  end

  def handle_call({:reset, new_content}, _from, _content) do
    {:reply, :ok, new_content}
  end

  defp do_replace(content, old_text, new_text) do
    parts = String.split(content, old_text)

    case length(parts) - 1 do
      0 -> {:error, "not found"}
      1 -> {:ok, String.replace(content, old_text, new_text, global: false)}
      n -> {:error, "found #{n} times"}
    end
  end
end

# --- Generate a realistic source file ---

defmodule Bench.FileGen do
  @moduledoc "Generates a realistic Elixir source file for benchmarking."

  def generate(line_count) do
    modules = div(line_count, 50)

    1..modules
    |> Enum.map(fn i ->
      """
      defmodule Bench.Module#{i} do
        @moduledoc "Auto-generated module #{i} for benchmarking."

        @type state :: %{
          id: integer(),
          name: String.t(),
          items: [term()],
          counter: non_neg_integer(),
          active: boolean()
        }

        @spec process(state(), term()) :: state()
        def process(%{id: id, counter: counter} = state, item) do
          new_items = [item | state.items]
          new_counter = counter + 1

          if new_counter > 100 do
            reset_state(state)
          else
            %{state | items: new_items, counter: new_counter}
          end
        end

        defp reset_state(state) do
          %{state | items: [], counter: 0, active: false}
        end

        @spec validate(state()) :: {:ok, state()} | {:error, String.t()}
        def validate(%{name: name} = state) when is_binary(name) and byte_size(name) > 0 do
          {:ok, state}
        end

        def validate(_state) do
          {:error, "invalid state: name required"}
        end

        @spec transform(state(), (term() -> term())) :: state()
        def transform(state, func) do
          new_items = Enum.map(state.items, func)
          %{state | items: new_items}
        end

        @spec summary(state()) :: String.t()
        def summary(%{id: id, name: name, counter: counter}) do
          "Module#{i}[" <> Integer.to_string(id) <> "] " <> name <> ": " <> Integer.to_string(counter) <> " processed"
        end
      end
      """
    end)
    |> Enum.join("\n")
  end

  @doc "Generate unique edits that each match exactly once in the content."
  def generate_edits(content, count) do
    # Pick unique function names to edit (each appears once)
    1..count
    |> Enum.map(fn i ->
      old = "Module#{i} do"
      new = "Module#{i}V2 do"
      {old, new}
    end)
    |> Enum.filter(fn {old, _new} -> String.contains?(content, old) end)
    |> Enum.take(count)
  end
end

# --- Setup ---

IO.puts("Generating test files...")

content_1k = Bench.FileGen.generate(1_000)
content_5k = Bench.FileGen.generate(5_000)

IO.puts("  1K-line file: #{div(byte_size(content_1k), 1024)} KB")
IO.puts("  5K-line file: #{div(byte_size(content_5k), 1024)} KB")

tmp_dir = System.tmp_dir!()
file_path = Path.join(tmp_dir, "bench_agent_edit.ex")

edits_1k_single = Bench.FileGen.generate_edits(content_1k, 1)
edits_1k_batch = Bench.FileGen.generate_edits(content_1k, 20)
edits_5k_batch = Bench.FileGen.generate_edits(content_5k, 20)

IO.puts("  Edits for 1K: #{length(edits_1k_single)} single, #{length(edits_1k_batch)} batch")
IO.puts("  Edits for 5K: #{length(edits_5k_batch)} batch")
IO.puts("")

# --- Benchmark helpers ---

# Filesystem helpers — assume file already exists on disk (before_each writes it)
# Only measure the actual tool operation: read + replace + write

filesystem_single_edit = fn edits ->
  [{old_text, new_text}] = Enum.take(edits, 1)
  content = File.read!(file_path)
  new_content = String.replace(content, old_text, new_text, global: false)
  File.write!(file_path, new_content)
end

filesystem_batch_edit = fn edits ->
  # MultiEditFile: one read, apply all in memory, one write
  content = File.read!(file_path)

  final =
    Enum.reduce(edits, content, fn {old, new}, c ->
      String.replace(c, old, new, global: false)
    end)

  File.write!(file_path, final)
end

filesystem_sequential_edits = fn edits ->
  # EditFile called N times: N reads + N writes
  Enum.each(edits, fn {old, new} ->
    c = File.read!(file_path)
    new_c = String.replace(c, old, new, global: false)
    File.write!(file_path, new_c)
  end)
end

IO.puts("=" |> String.duplicate(70))
IO.puts("BENCHMARK 1: Single Edit (EditFile)")
IO.puts("  One find-and-replace on a 1K-line file")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

{:ok, single_buf} = Bench.BufferServer.start_link(content_1k)
[{single_old, single_new}] = Enum.take(edits_1k_single, 1)

Benchee.run(
  %{
    "filesystem (read → replace → write)" => {
      fn _input -> filesystem_single_edit.(edits_1k_single) end,
      before_each: fn _ ->
        File.write!(file_path, content_1k)
        nil
      end
    },
    "buffer GenServer (atomic, pre-started)" => {
      fn _input ->
        Bench.BufferServer.find_and_replace(single_buf, single_old, single_new)
      end,
      before_each: fn _ ->
        GenServer.call(single_buf, {:reset, content_1k})
        nil
      end
    }
  },
  warmup: 2,
  time: 5,
  print: [configuration: false]
)

GenServer.stop(single_buf)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("BENCHMARK 2: 20 Sequential Edits (EditFile × 20)")
IO.puts("  Worst case: agent calls EditFile 20 times on the same file")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

edits_5k_20 = Bench.FileGen.generate_edits(content_5k, 20)
{:ok, seq_buf} = Bench.BufferServer.start_link(content_5k)

Benchee.run(
  %{
    "filesystem sequential (20× read + write)" => {
      fn _input -> filesystem_sequential_edits.(edits_5k_20) end,
      before_each: fn _ ->
        File.write!(file_path, content_5k)
        nil
      end
    },
    "buffer GenServer (20× atomic calls, pre-started)" => {
      fn _input ->
        Enum.each(edits_5k_20, fn {old, new} ->
          Bench.BufferServer.find_and_replace(seq_buf, old, new)
        end)
      end,
      before_each: fn _ ->
        GenServer.call(seq_buf, {:reset, content_5k})
        nil
      end
    }
  },
  warmup: 2,
  time: 5,
  print: [configuration: false]
)

GenServer.stop(seq_buf)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("BENCHMARK 3: Batch Edit (MultiEditFile)")
IO.puts("  20 edits batched in one tool call on a 5K-line file")
IO.puts("  Buffer GenServer is pre-started (realistic: buffer already open)")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

# Pre-generate fresh content for each iteration via hooks
# For the buffer path, pre-start the GenServer (the buffer is already open
# when the agent edits a file the user has open)
{:ok, batch_buf} = Bench.BufferServer.start_link(content_5k)

Benchee.run(
  %{
    "filesystem batch (1 read, N replaces, 1 write)" => {
      fn _input -> filesystem_batch_edit.(edits_5k_batch) end,
      before_each: fn _ ->
        File.write!(file_path, content_5k)
        nil
      end
    },
    "buffer GenServer (atomic batch, pre-started)" => {
      fn _input ->
        Bench.BufferServer.find_and_replace_batch(batch_buf, edits_5k_batch)
      end,
      before_each: fn _ ->
        # Reset content for fair comparison
        GenServer.call(batch_buf, {:reset, content_5k})
        nil
      end
    }
  },
  warmup: 2,
  time: 5,
  print: [configuration: false]
)

GenServer.stop(batch_buf)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("BENCHMARK 4: 5 Concurrent Agents (multi-agent scenario)")
IO.puts("  5 agents each making 10 edits to the same 5K-line file")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

edits_5k_50 = Bench.FileGen.generate_edits(content_5k, 50)
{:ok, conc_buf} = Bench.BufferServer.start_link(content_5k)

buffer_concurrent_prestarted = fn buf, edits, agent_count ->
  chunks = Enum.chunk_every(edits, div(length(edits), agent_count))

  tasks =
    Enum.map(chunks, fn chunk ->
      Task.async(fn ->
        Enum.each(chunk, fn {old, new} ->
          Bench.BufferServer.find_and_replace(buf, old, new)
        end)
      end)
    end)

  Task.await_many(tasks)
end

Benchee.run(
  %{
    "filesystem sequential (50 edits, no concurrency safe)" => {
      fn _input -> filesystem_sequential_edits.(edits_5k_50) end,
      before_each: fn _ ->
        File.write!(file_path, content_5k)
        nil
      end
    },
    "buffer GenServer (5 concurrent agents × 10 edits)" => {
      fn _input -> buffer_concurrent_prestarted.(conc_buf, edits_5k_50, 5) end,
      before_each: fn _ ->
        GenServer.call(conc_buf, {:reset, content_5k})
        nil
      end
    }
  },
  warmup: 2,
  time: 5,
  print: [configuration: false]
)

GenServer.stop(conc_buf)

# Cleanup
File.rm(file_path)

IO.puts("")
IO.puts("=" |> String.duplicate(70))
IO.puts("NOTE: Filesystem numbers do NOT include FileWatcher notification")
IO.puts("processing, buffer reload, or tree-sitter full reparse overhead.")
IO.puts("Real-world filesystem cost is significantly higher than shown.")
IO.puts("=" |> String.duplicate(70))
