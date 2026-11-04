defmodule MimoHalow.Hw.PhyHostTxTest do
  @moduledoc """
  PhyHost transmit end to end in digital loopback: PSDU, SIG bits and
  parameters written as CTRL3 commands -> Tx.TxPhy -> the held TX port
  sample, fed back as both receive chains -> Decim4 -> Rx.Eig1 -> receive
  ring -> PSDUs.
  """
  use ExUnit.Case
  import Bitwise
  alias MimoHalow.Model.S1g.{Coding, Params, Ppdu}
  alias MimoHalow.Test.Cosim

  @mod_code %{bpsk: 0, qpsk: 1, qam16: 2, qam64: 3, qam256: 4}
  @rate_code %{{1, 2} => 0, {2, 3} => 1, {3, 4} => 2, {5, 6} => 3}

  defp psdu(n, seed) do
    :rand.seed(:exsss, {seed, 2, 2})
    body = for _ <- 1..n, into: <<>>, do: <<:rand.uniform(256) - 1>>
    body <> Coding.bits_to_bytes(Coding.fcs(Coding.bytes_to_bits(body)))
  end

  @doc false
  def commands(p, mcs, seed) do
    t = Ppdu.tx(p, bw: 2, mcs: mcs, scrambler: seed)

    sig =
      for {tones, n} <- Enum.with_index(t.sig), {kk, j} <- Enum.with_index(Params.sig_data(2)), reduce: 0 do
        acc ->
          {_, im} = Map.fetch!(tones, kk)
          if im > 0, do: acc ||| 1 <<< (48 * n + j), else: acc
      end

    par = t.nsym ||| seed <<< 10 ||| @mod_code[t.rate.mod] <<< 17 ||| @rate_code[t.rate.rate] <<< 20
    lens = (t.nsym * t.rate.ndbps) ||| byte_size(p) <<< 16
    sigw = for k <- 0..3, do: 2 <<< 28 ||| k <<< 24 ||| (sig >>> (24 * k) &&& 0xFFFFFF)
    words = for <<chunk::binary-size(3) <- pad3(p)>>, do: (<<v::little-24>> = chunk; 1 <<< 28 ||| v)
    [3 <<< 28 ||| par, 4 <<< 28 ||| lens] ++ sigw ++ [6 <<< 28] ++ words ++ [5 <<< 28]
  end

  defp pad3(p), do: p <> :binary.copy(<<0>>, rem(3 - rem(byte_size(p), 3), 3))

  defp psdus(entries) do
    entries
    |> Enum.reject(fn e -> (e >>> 31) == 0 end)
    |> Enum.flat_map(fn e ->
      n = e >>> 28 &&& 3
      for i <- 0..(n - 1), do: {e >>> (8 * i) &&& 0xFF, if(i == n - 1, do: e >>> 30 &&& 1, else: 0)}
    end)
    |> Enum.chunk_while([], fn {b, l}, acc -> if l == 1, do: {:cont, Enum.reverse([b | acc]), []}, else: {:cont, [b | acc]} end, fn acc -> {:cont, acc} end)
    |> Enum.map(&:binary.list_to_bin/1)
  end

  @tag :iverilog
  @tag timeout: 3_600_000
  test "PhyHost TX: CTRL3 commands -> TX port -> loopback -> RX ring -> same PSDUs" do
    frames = [{2, psdu(60, 41), 0x5D}, {7, psdu(150, 42), 0x33}]

    cmds =
      ["Z 4400"] ++
        Enum.flat_map(frames, fn {mcs, p, seed} ->
          Enum.map(commands(p, mcs, seed), &"W #{Integer.to_string(&1, 16)}") ++ ["G", "Z 1500"]
        end)

    # phy_en, emin code 2, TX port to the PHY
    ctl = 1 <<< 5 ||| 2 <<< 26 ||| 1 <<< 14
    lines = Cosim.run([MimoHalow.Hw.PhyHost], "tb_phy_host_tx.v", cmds, header: "#{length(cmds)} #{Integer.to_string(ctl, 16)}")

    {tx, rest} = Enum.split_with(lines, &String.starts_with?(&1, "T "))
    ["W " <> w | rest] = rest
    {["M " <> m], rs} = Enum.split_with(rest, &String.starts_with?(&1, "M "))
    entries = Enum.map(rs, fn "R " <> e -> String.to_integer(e, 16) end)
    assert length(entries) == String.to_integer(w)
    [mon0, mon1, mon2] = m |> String.split() |> Enum.map(&String.to_integer(&1, 16))
    sigs = for e <- entries, (e >>> 28) == 1, do: {e >>> 27 &&& 1, e >>> 26 &&& 1, e >>> 22 &&& 15}

    diag =
      "tx #{length(tx)} samples, frames #{mon2 >>> 1 &&& 0x7F} under #{mon2 >>> 8 &&& 0xFF} busy #{mon2 &&& 1}, " <>
        "sync #{mon0 >>> 16} drop #{mon0 &&& 0xFFFF} det #{mon1 >>> 16} sigs #{inspect(sigs)}"

    IO.puts(diag)
    assert (mon2 &&& 0xFFFF) == length(frames) <<< 1, diag
    assert psdus(entries) == Enum.map(frames, fn {_, p, _} -> p end), diag
  end
end
