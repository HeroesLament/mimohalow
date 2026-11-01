defmodule MimoHalow.Lab.Session do
  @moduledoc """
  Controller-side 2x2 sounding against the LibreSDR boards over Erlang
  distribution. Runs on any node already connected to the boards (the
  fabfarm controller): prepend the `lab` and `model` ebin paths there.

  Board-side calls go to the nervezynq modules by name (`TxLoop`, `HPStream`,
  `SDR`, `TxTone`) and to `MimoHalow.Lab.Board`, which `install/1` compiles
  on each board from source. No compile-time dependency on nervezynq.

  Captures are saved as `cap_<tag>.etf` in `dir`:
  `%{tx: dma_burst_result, txb: node, caps: [{node, {:ok, cap} | {:error, _}}], at: DateTime}`,
  the format `mix mh.sounder.analyse` reads.
  """
  alias MimoHalow.Model.Sounder

  @boards [a: :"nerves@192.168.217.60", b: :"nerves@192.168.217.62", c: :"nerves@192.168.217.63"]
  @board_src Path.expand("../../../board/board.exs", __DIR__)

  def boards, do: @boards
  def node_of(name) when is_atom(name), do: Keyword.fetch!(@boards, name)
  def name_of(node), do: Enum.find_value(@boards, fn {k, v} -> if v == node, do: k end)

  def default_dir, do: Path.expand("~/.cache/oxl/sounder")

  @doc "Compile `MimoHalow.Lab.Board` on each board from source."
  def install(names \\ Keyword.keys(@boards)) do
    src = File.read!(@board_src)
    for n <- names, do: {n, :erpc.call(node_of(n), Code, :compile_string, [src], 30_000) |> Enum.map(&elem(&1, 0))}
  end

  @doc "TX and RX LO of each board to `hz`."
  def tune(hz, names \\ Keyword.keys(@boards)) do
    for n <- names, do: {n, :erpc.call(node_of(n), MimoHalow.Lab.Board, :tune, [hz], 20_000)}
  end

  @doc "Load a ring image (served at `url`) into each board's TX ring."
  def load_ring(url, names \\ Keyword.keys(@boards)) do
    for n <- names do
      b = node_of(n)
      :ok = :erpc.call(b, Nervezynq.TxLoop, :dma_stop, [], 5_000)
      {n, :erpc.call(b, Nervezynq.TxLoop, :dma_load, [url], 60_000)}
    end
  end

  @doc "One clean tail capture: retries on window errors and SEQ holes."
  def capture(name, opts \\ []) do
    bytes = Keyword.get(opts, :bytes, 262_144)
    tries = Keyword.get(opts, :tries, 4)

    Enum.reduce_while(1..tries, {:error, :no_attempt}, fn _, _ ->
      case :erpc.call(node_of(name), MimoHalow.Lab.Board, :tail_capture, [bytes], 20_000) do
        {:ok, %{seq: %{holes: 0}} = c} -> {:halt, {:ok, c}}
        {:ok, c} -> {:cont, {:error, {:holes, c.seq.holes}}}
        {:error, e} -> {:cont, {:error, e}}
      end
    end)
  end

  @doc """
  One sounding shot: `tx` keys the ring, every other board captures.
  Options: `:atten_db` (10.0), `:burst_ms` (4000), `:dir`, `:tag`.

  `TxLoop.dma_burst/2` returns at key-up and unkeys `burst_ms` later, so
  every capture (retries included) must finish before then: a capture that
  ends later than key-up + burst - 200 ms is replaced by `{:error, {:late, ms}}`.
  """
  def shot(tx, opts \\ []) do
    atten = Keyword.get(opts, :atten_db, 10.0)
    burst = Keyword.get(opts, :burst_ms, 4000)
    dir = Keyword.get(opts, :dir, default_dir())
    rxs = Keyword.keys(@boards) -- [tx]

    for r <- rxs, do: :erpc.call(node_of(r), MimoHalow.Lab.Board, :rx_on, [], 5_000)
    Process.sleep(50)
    txr = :erpc.call(node_of(tx), Nervezynq.TxLoop, :dma_burst, [burst, [atten_db: atten]], 15_000)
    t_key = System.monotonic_time(:millisecond)
    deadline = t_key + burst - 200
    Process.sleep(150)

    caps =
      rxs
      |> Task.async_stream(
        fn r ->
          res = capture(r)
          done = System.monotonic_time(:millisecond)
          {node_of(r), if(done < deadline, do: res, else: {:error, {:late, done - t_key}})}
        end,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, x} -> x end)

    Process.sleep(max(t_key + burst + 300 - System.monotonic_time(:millisecond), 0))
    d = %{tx: txr, txb: node_of(tx), caps: caps, at: DateTime.utc_now()}

    if tag = Keyword.get(opts, :tag) do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "cap_#{tag}.etf"), :erlang.term_to_binary(d))
    end

    d
  end

  @doc "Every board transmits once; tags `<tag>_<tx>`. Returns `%{tx => shot}`."
  def round_robin(tag, opts \\ []) do
    for tx <- Keyword.keys(@boards), into: %{} do
      {tx, shot(tx, Keyword.put(opts, :tag, "#{tag}_#{tx}"))}
    end
  end

  @doc "Compact per-link summary of a shot: `[{\"b->a\", power_db, snr_db, rejected}]`."
  def brief(%{txb: txb, caps: caps}) do
    for {r, res} <- caps do
      link = "#{name_of(txb)}->#{name_of(r)}"

      case res do
        {:ok, c} ->
          s = Sounder.summary(Sounder.analyse(Sounder.decode_capture(c.u64)))
          {link, Enum.map(List.flatten(s.power_db), &round/1), Enum.map(List.flatten(s.snr_db), &round/1), s.rejected}

        err ->
          {link, err}
      end
    end
  end
end
