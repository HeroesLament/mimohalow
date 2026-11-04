defmodule MimoHalow.Hw.PhyHostReplayTest do
  @moduledoc """
  Replay a board capture (`MimoHalow.Lab.Board.tail_capture/1` result saved
  as ETF, `MH_CAPTURE=path`) through PhyHost in iverilog: the same 8 MS/s
  two-chain words the fabric PHY saw. Separates the RTL from the toolchain
  when silicon does not detect. Skipped without MH_CAPTURE.

  MH_REPLAY_FROM / MH_REPLAY_LEN pick the sample window (default: the whole
  capture); MH_REPLAY_EMIN is the energy gate code (default 2, as phy_host_test).
  """
  use ExUnit.Case
  import Bitwise
  alias MimoHalow.Test.Cosim

  @moduletag :iverilog
  @moduletag timeout: 3_600_000

  defp s12(v) do
    v = v &&& 0xFFF
    if v >= 0x800, do: v - 0x1000, else: v
  end

  defp env_int(k, d),
    do: k |> System.get_env() |> then(&if(&1, do: String.to_integer(&1), else: d))

  test "replay a board capture through PhyHost" do
    path = System.get_env("MH_CAPTURE")
    if is_nil(path), do: flunk("set MH_CAPTURE")
    cap = path |> File.read!() |> :erlang.binary_to_term()
    from = env_int("MH_REPLAY_FROM", 0)
    len = env_int("MH_REPLAY_LEN", length(cap.u64))
    emin = env_int("MH_REPLAY_EMIN", 2)

    ws = cap.u64 |> Enum.drop(from) |> Enum.take(len)
    warm = List.duplicate("000 000 000 000", 4400)
    rows = Enum.map(ws, fn w -> Enum.map([w, w >>> 12, w >>> 24, w >>> 36], &s12/1) end)

    # MH_REPLAY_DC=1: subtract each component's mean over the window first.
    rows =
      if System.get_env("MH_REPLAY_DC") == "1" do
        means = rows |> Enum.zip_with(& &1) |> Enum.map(&round(Enum.sum(&1) / length(&1)))
        IO.puts("removing DC #{inspect(means)}")
        Enum.map(rows, fn r -> Enum.zip_with(r, means, &(&1 - &2)) end)
      else
        rows
      end

    stim = warm ++ Enum.map(rows, fn r -> Enum.map_join(r, " ", &Cosim.hex(&1, 12)) end)

    ctl = 1 <<< 5 ||| emin <<< 26

    # MH_REPLAY_STIM_OUT: also write the bench's stim.txt (for a netlist run).
    if out = System.get_env("MH_REPLAY_STIM_OUT") do
      File.write!(out, [
        "#{length(stim)} #{Integer.to_string(ctl, 16)}",
        "\n" | Enum.map(stim, &[&1, "\n"])
      ])
    end

    lines =
      Cosim.run([MimoHalow.Hw.PhyHost], "tb_phy_host.v", stim,
        header: "#{length(stim)} #{Integer.to_string(ctl, 16)}"
      )

    ["W " <> w | rest] = lines
    {["M " <> m], rs} = Enum.split_with(rest, &String.starts_with?(&1, "M "))
    entries = Enum.map(rs, fn "R " <> e -> String.to_integer(e, 16) end)
    [mon0, mon1, mon2] = m |> String.split() |> Enum.map(&String.to_integer(&1, 16))

    sigs =
      for e <- entries,
          e >>> 28 == 1,
          do: %{
            ok: e >>> 27 &&& 1,
            discard: e >>> 26 &&& 1,
            mcs: e >>> 22 &&& 15,
            length: e >>> 11 &&& 0x1FF
          }

    IO.puts(
      "replay #{path} from #{from} len #{length(ws)} emin #{emin}: words #{w} sync #{mon0 >>> 16} drop #{mon0 &&& 0xFFFF} " <>
        "det #{mon1 >>> 16} flags #{mon1 &&& 7} preempt #{mon2 >>> 16} sigs #{inspect(sigs)}"
    )

    bytes =
      entries
      |> Enum.filter(&(&1 >>> 31 == 1))
      |> Enum.flat_map(fn e ->
        for i <- 0..((e >>> 28 &&& 3) - 1)//1, do: e >>> (8 * i) &&& 0xFF
      end)

    IO.puts("psdu bytes: #{:binary.list_to_bin(bytes) |> inspect(limit: 80)}")
  end
end
