defmodule MimoHalow.Model.S1g.AirTest do
  use ExUnit.Case, async: true

  alias MimoHalow.Model.Fixed.Decim4
  alias MimoHalow.Model.S1g.{Air, Ppdu}

  test "with_fcs/1 makes fcs_ok?/1 hold, and a flipped bit breaks it" do
    p = Air.with_fcs("mimohalow air test")
    assert byte_size(p) == 22
    assert Ppdu.fcs_ok?(p)
    <<a, rest::binary>> = p
    refute Ppdu.fcs_ok?(<<Bitwise.bxor(a, 1), rest::binary>>)
  end

  test "interp4/1 then the fixed Decim4 gives back the base-rate samples" do
    psdu = Air.with_fcs(:binary.copy(<<0xA5, 0x3C>>, 20))
    x = Ppdu.tx(psdu, bw: 2, mcs: 2).samples
    y = Air.interp4(x)
    assert length(y) == 4 * length(x) + 2 * 58 + 14

    # 12-bit integers, as the AD9363 delivers them (and Decim4 expects).
    g = 1500.0 / (Enum.map(x, fn {a, b} -> abs(a) + abs(b) end) |> Enum.max())
    ints = Enum.map(y, fn {a, b} -> {round(a * g), round(b * g)} end)

    # Decim4 keeps odd 8 MS/s indices; try both phases and the delays near the
    # chain's 130 / 4 = 32.5 base samples, decode with the float receiver.
    found =
      for ph <- 0..3, d <- 30..35, reduce: nil do
        nil ->
          z =
            ints
            |> Enum.drop(ph)
            |> Decim4.run_cx()
            |> Enum.drop(d)
            |> Enum.map(fn {a, b} -> {a / g, b / g} end)

          case Ppdu.rx(z, 2) do
            {:ok, %{psdu: ^psdu}} -> {ph, d}
            _ -> nil
          end

        hit ->
          hit
      end

    assert found, "no phase/delay decoded the PSDU"
  end

  test "ring_image/2 is one 1 MB ring with copies at evenly spaced slots" do
    psdu = Air.with_fcs("ring")
    img = Air.ring_image(psdu, mcs: 0, copies: 4)
    assert byte_size(img) == 8 * Air.ring_frames()
    fr = Air.frames(img)
    slot = div(Air.ring_frames(), 4)
    starts = for k <- 0..3, do: Enum.at(fr, k * slot)
    # Every copy starts the same (first STF sample), TX2 silent.
    assert Enum.uniq(starts) |> length() == 1
    assert Enum.all?(fr, fn {_, t2} -> t2 == {0, 0} end)
    peak = fr |> Enum.map(fn {{a, b}, _} -> max(abs(a), abs(b)) end) |> Enum.max()
    assert peak in 900..2047
  end
end
