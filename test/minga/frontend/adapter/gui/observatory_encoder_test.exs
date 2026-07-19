defmodule Minga.Frontend.Adapter.GUI.ObservatoryEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ObservatoryEncoder
  alias Minga.RenderModel.UI.Observatory
  alias Minga.RenderModel.UI.Observatory.Node

  @op_gui_observatory Minga.Protocol.Opcodes.gui_observatory()

  describe "encode/2" do
    test "encodes hidden observatory exactly" do
      assert ObservatoryEncoder.encode_command(%Observatory{}) ==
               <<@op_gui_observatory, 6::32, 0x01, 3::16, 0, 0::16>>
    end

    test "encodes visible empty observatory exactly" do
      assert ObservatoryEncoder.encode_command(%Observatory{visible?: true, nodes: []}) ==
               <<@op_gui_observatory, 6::32, 0x01, 3::16, 1, 0::16>>
    end

    test "encodes one visible node with sparkline fields" do
      node = observatory_node()

      <<@op_gui_observatory, payload_len::32, payload::binary-size(payload_len)>> =
        ObservatoryEncoder.encode_command(%Observatory{visible?: true, nodes: [node]})

      sections = observatory_sections(payload)
      assert sections_by_id(sections, 0x01) == [<<1, 1::16>>]

      [node_section] = sections_by_id(sections, 0x02)
      pid_string = node.pid |> :erlang.pid_to_list() |> List.to_string()

      assert <<pid_len::8, ^pid_string::binary-size(pid_len), 0::8, name_len::16,
               name::binary-size(name_len), 5, 0, 1024::32, 1::16, 10::32>> = node_section

      assert name == ":minga_test"

      [sparkline_section] = sections_by_id(sections, 0x03)

      assert <<pid_len::8, ^pid_string::binary-size(pid_len), 1, 32_768::16>> =
               sparkline_section
    end

    test "chunks large node and sparkline streams into repeated sections below the section limit" do
      child_count = 1_800

      nodes =
        Enum.map(
          1..child_count,
          &observatory_node(
            name: "Minga.Buffer.content/#{&1}",
            sparkline_values: List.duplicate(0.0, 30)
          )
        )

      <<@op_gui_observatory, payload_len::32, payload::binary-size(payload_len)>> =
        ObservatoryEncoder.encode_command(%Observatory{visible?: true, nodes: nodes})

      assert payload_len > 65_535

      sections = observatory_sections(payload)
      node_sections = sections_by_id(sections, 0x02)
      sparkline_sections = sections_by_id(sections, 0x03)

      assert Enum.count(node_sections) > 1
      assert Enum.count(sparkline_sections) > 1
      assert Enum.all?(node_sections, &(byte_size(&1) < 65_535))
      assert Enum.all?(sparkline_sections, &(byte_size(&1) < 65_535))

      node_stream = IO.iodata_to_binary(node_sections)
      sparkline_stream = IO.iodata_to_binary(sparkline_sections)

      assert count_observatory_nodes(node_stream, 0) == child_count
      assert count_observatory_sparklines(sparkline_stream, 0) == child_count
    end

    test "returns nil on second call with same fingerprint" do
      model = %Observatory{}
      caches = Caches.new()

      {cmd1, caches} = ObservatoryEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = ObservatoryEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-emits visible-to-hidden and hidden-to-visible semantic changes" do
      hidden = %Observatory{}
      visible = %Observatory{visible?: true, nodes: []}
      caches = Caches.new()

      {_cmd, caches} = ObservatoryEncoder.encode(visible, caches)
      {hidden_cmd, caches} = ObservatoryEncoder.encode(hidden, caches)
      {visible_cmd, _caches} = ObservatoryEncoder.encode(visible, caches)

      assert hidden_cmd == ObservatoryEncoder.encode_command(hidden)
      assert visible_cmd == ObservatoryEncoder.encode_command(visible)
    end

    test "re-emits changed semantic node content" do
      model1 = %Observatory{visible?: true, nodes: [observatory_node(name: "one")]}
      model2 = %Observatory{visible?: true, nodes: [observatory_node(name: "two")]}
      caches = Caches.new()

      {_cmd, caches} = ObservatoryEncoder.encode(model1, caches)
      {cmd, _caches} = ObservatoryEncoder.encode(model2, caches)

      assert cmd == ObservatoryEncoder.encode_command(model2)
    end
  end

  defp observatory_node(opts \\ []) do
    %Node{
      pid: Keyword.get(opts, :pid, self()),
      parent_pid: Keyword.get(opts, :parent_pid),
      name: Keyword.get(opts, :name, ":minga_test"),
      process_class: Keyword.get(opts, :process_class, :worker),
      depth: Keyword.get(opts, :depth, 0),
      memory: Keyword.get(opts, :memory, 1024),
      message_queue_len: Keyword.get(opts, :message_queue_len, 1),
      reductions: Keyword.get(opts, :reductions, 10),
      sparkline_values: Keyword.get(opts, :sparkline_values, [0.5])
    }
  end

  defp observatory_sections(payload), do: parse_observatory_sections(payload, [])

  defp parse_observatory_sections("", acc), do: Enum.reverse(acc)

  defp parse_observatory_sections(
         <<id::8, len::16, section::binary-size(len), rest::binary>>,
         acc
       ) do
    parse_observatory_sections(rest, [{id, section} | acc])
  end

  defp sections_by_id(sections, id) do
    sections
    |> Enum.filter(fn {section_id, _section} -> section_id == id end)
    |> Enum.map(fn {_section_id, section} -> section end)
  end

  defp count_observatory_nodes("", count), do: count

  defp count_observatory_nodes(
         <<pid_len::8, _pid::binary-size(pid_len), parent_len::8,
           _parent::binary-size(parent_len), name_len::16, _name::binary-size(name_len),
           _class::8, _depth::8, _memory::32, _queue::16, _reductions::32, rest::binary>>,
         count
       ) do
    count_observatory_nodes(rest, count + 1)
  end

  defp count_observatory_sparklines("", count), do: count

  defp count_observatory_sparklines(
         <<pid_len::8, _pid::binary-size(pid_len), sample_count::8,
           _samples::binary-size(sample_count * 2), rest::binary>>,
         count
       ) do
    count_observatory_sparklines(rest, count + 1)
  end
end
