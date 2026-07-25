defmodule MingaEditor.Renderer.Caches do
  @moduledoc "Explicit render-pipeline cache state retained by the renderer."

  defstruct chrome_prev_fingerprint: nil,
            chrome_prev_result: nil,
            search_decoration_cache: nil,
            doc_highlight_cache: nil,
            cmd_hover_link_cache: nil,
            frame_rows_rasterized: 0,
            frame_render_path: :full,
            last_title: nil,
            last_window_bg: nil,
            last_link_cursor: nil,
            last_emitted_frame_seq: 0,
            last_acknowledged_frame_seq: 0,
            recovery_generation: 1,
            last_frame_keyframe?: false,
            adapter_gui_caches: Minga.Frontend.Adapter.GUI.Caches.new()

  @type t :: %__MODULE__{
          chrome_prev_fingerprint: integer() | nil,
          chrome_prev_result: term(),
          search_decoration_cache: term(),
          doc_highlight_cache: term(),
          cmd_hover_link_cache: term(),
          frame_rows_rasterized: non_neg_integer(),
          frame_render_path: :patch | :full,
          last_title: String.t() | nil,
          last_window_bg: non_neg_integer() | nil,
          last_link_cursor: boolean() | nil,
          last_emitted_frame_seq: non_neg_integer(),
          last_acknowledged_frame_seq: non_neg_integer(),
          recovery_generation: non_neg_integer(),
          last_frame_keyframe?: boolean(),
          adapter_gui_caches: Minga.Frontend.Adapter.GUI.Caches.t()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec reset_frame_rows_rasterized(t()) :: t()
  def reset_frame_rows_rasterized(%__MODULE__{} = caches),
    do: %{caches | frame_rows_rasterized: 0}

  @spec add_frame_rows_rasterized(t(), non_neg_integer()) :: t()
  def add_frame_rows_rasterized(%__MODULE__{} = caches, count)
      when is_integer(count) and count >= 0,
      do: %{caches | frame_rows_rasterized: caches.frame_rows_rasterized + count}

  @spec record_frame_render_path(t(), :patch | :full) :: t()
  def record_frame_render_path(%__MODULE__{} = caches, path) when path in [:patch, :full],
    do: %{caches | frame_render_path: path}

  @spec record_chrome_result(t(), integer(), term()) :: t()
  def record_chrome_result(%__MODULE__{} = caches, fingerprint, chrome),
    do: %{caches | chrome_prev_fingerprint: fingerprint, chrome_prev_result: chrome}

  @spec record_content_decoration_caches(t(), term(), term(), term()) :: t()
  def record_content_decoration_caches(
        %__MODULE__{} = caches,
        search_decoration_cache,
        doc_highlight_cache,
        cmd_hover_link_cache
      ) do
    %{
      caches
      | search_decoration_cache: search_decoration_cache,
        doc_highlight_cache: doc_highlight_cache,
        cmd_hover_link_cache: cmd_hover_link_cache
    }
  end

  @spec acknowledge_frame(t(), non_neg_integer(), non_neg_integer()) :: t()
  def acknowledge_frame(%__MODULE__{} = caches, frame_seq, generation)
      when is_integer(frame_seq) and frame_seq >= 0 and is_integer(generation) and generation >= 0 do
    %{caches | last_acknowledged_frame_seq: frame_seq, recovery_generation: generation}
  end

  @spec reset_frontend_state(t()) :: t()
  def reset_frontend_state(%__MODULE__{} = caches) do
    %{
      caches
      | adapter_gui_caches: Minga.Frontend.Adapter.GUI.Caches.new(),
        last_title: nil,
        last_window_bg: nil,
        last_link_cursor: nil,
        last_emitted_frame_seq: 0,
        last_acknowledged_frame_seq: 0,
        recovery_generation: caches.recovery_generation + 1
    }
  end
end
