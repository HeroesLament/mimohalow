defmodule MimoHalow.Hw.Tx.EncoderTest do
  use ExUnit.Case
  import Bitwise
  alias MimoHalow.Model.{Bcc, Scrambler}
  alias MimoHalow.Model.S1g.{Coding, Params, Ppdu}
  alias MimoHalow.Test.Cosim

  @rate_code %{{1, 2} => 0, {2, 3} => 1, {3, 4} => 2, {5, 6} => 3}

  # Model: the coded (punctured) DATA bits, as in Ppdu.data_tones/5.
  defp model(psdu, r, seed) do
    ns = Ppdu.nsym(r, byte_size(psdu))
    nbits = ns * r.ndbps
    payload = [0 | Coding.bits(0, 7)] ++ Coding.bytes_to_bits(psdu)
    pad = nbits - length(payload) - 6
    {seq, _} = Scrambler.sequence(nbits, seed)
    s = Enum.zip_with(payload ++ List.duplicate(0, pad + 6), seq, &bxor/2)
    s = Enum.take(s, nbits - 6) ++ List.duplicate(0, 6)
    {nbits, s |> Bcc.encode() |> Coding.puncture(r.rate)}
  end

  @tag :iverilog
  test "emitted Verilog == model DATA coded bits (rates 1/2, 3/4, 5/6; stalls)" do
    cases =
      for {mcs, len, seed} <- [{0, 13, 0x5D}, {0, 100, 1}, {2, 37, 0x7F}, {4, 160, 0x22}, {7, 496, 0x5D}, {7, 14, 0x41}] do
        :rand.seed(:exsss, {mcs, len, seed})
        {:ok, r} = Params.rate(2, mcs)
        psdu = :rand.bytes(len)
        {nbits, want} = model(psdu, r, seed)
        {mcs, r, seed, nbits, psdu, want}
      end

    stim =
      Enum.flat_map(cases, fn {_, r, seed, nbits, psdu, _} ->
        ["#{seed} #{@rate_code[r.rate]} #{nbits} #{byte_size(psdu)}" | for(<<b <- psdu>>, do: Cosim.hex(b, 8))]
      end)

    out = Cosim.run([MimoHalow.Hw.Tx.Encoder], "tb_tx_encoder.v", stim, header: "#{length(cases)}")
    groups = out |> Enum.chunk_while([], fn
      "E " <> cyc, acc -> {:cont, {Enum.reverse(acc), String.to_integer(cyc)}, []}
      bit, acc -> {:cont, [String.to_integer(bit) | acc]}
    end, fn [] -> {:cont, []}; acc -> {:cont, acc, []} end)

    assert length(groups) == length(cases)

    for {{mcs, r, _, nbits, psdu, want}, {got, cyc}} <- Enum.zip(cases, groups) do
      assert length(got) == length(want), "MCS#{mcs} len #{byte_size(psdu)}: #{length(got)} bits, want #{length(want)}"
      first = Enum.zip(got, want) |> Enum.find_index(fn {g, w} -> g != w end)
      assert first == nil, "MCS#{mcs} len #{byte_size(psdu)}: first differing coded bit #{first}"
      # Throughput: well under 3 cycles per info bit plus handshake stalls.
      assert cyc < 12 * nbits, "MCS#{mcs}: #{cyc} cycles for #{nbits} info bits (rate #{inspect(r.rate)})"
    end
  end
end
