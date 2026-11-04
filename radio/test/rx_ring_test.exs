defmodule MimoHalow.RxRingTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias MimoHalow.RxRing

  defp with_fcs(b), do: b <> <<:erlang.crc32(b)::little-32>>

  defp sig_word(len), do: 1 <<< 28 ||| 1 <<< 27 ||| (len &&& 0x1FF) <<< 11

  # Byte words of three, last one flagged.
  defp byte_words(bin) do
    chunks = for <<c::binary-size(3) <- bin>>, do: c
    rest = binary_part(bin, 3 * length(chunks), byte_size(bin) - 3 * length(chunks))
    chunks = if rest == "", do: chunks, else: chunks ++ [rest]
    last = length(chunks) - 1

    for {c, i} <- Enum.with_index(chunks) do
      bs = :binary.bin_to_list(c)
      v = bs |> Enum.with_index() |> Enum.reduce(0, fn {b, k}, a -> a ||| b <<< (8 * k) end)
      1 <<< 31 ||| (if i == last, do: 1 <<< 30, else: 0) ||| length(bs) <<< 28 ||| v
    end
  end

  defp frame_words(psdu), do: [sig_word(byte_size(psdu)) | byte_words(psdu)]

  test "fcs" do
    assert RxRing.fcs_ok?(with_fcs("123456789"))
    refute RxRing.fcs_ok?("123456789" <> <<0, 0, 0, 0>>)
    refute RxRing.fcs_ok?(<<1, 2>>)
  end

  test "one frame, every length mod 3" do
    for n <- [13, 14, 15, 500] do
      p = with_fcs(:crypto.strong_rand_bytes(n))
      {_, [f]} = RxRing.feed(%RxRing{}, frame_words(p))
      assert f.complete and f.fcs_ok and f.psdu == p
      assert f.sig.length == (byte_size(p) &&& 0x1FF)
    end
  end

  test "frame split across feeds" do
    p = with_fcs(:crypto.strong_rand_bytes(100))
    {a, b} = Enum.split(frame_words(p), 7)
    {st, []} = RxRing.feed(%RxRing{}, a)
    {st, [f]} = RxRing.feed(st, b)
    assert f.fcs_ok and f.psdu == p and st.cur == nil
  end

  test "SIG before last BYTES closes the open frame as partial" do
    p = with_fcs("hello there world")
    q = with_fcs("second")
    ws = Enum.take(frame_words(p), 3) ++ frame_words(q)
    {_, [f1, f2]} = RxRing.feed(%RxRing{}, ws)
    refute f1.complete or f1.fcs_ok
    assert f2.fcs_ok and f2.psdu == q
  end

  test "corrupt byte fails fcs" do
    <<h, t::binary>> = with_fcs("abcdefghij")
    {_, [f]} = RxRing.feed(%RxRing{}, frame_words(<<bxor(h, 1), t::binary>>))
    assert f.complete and not f.fcs_ok
  end

  test "spans" do
    assert RxRing.spans(nil, 77) == {0, []}
    assert RxRing.spans(10, 10) == {0, []}
    assert RxRing.spans(10, 20) == {0, [{10, 10}]}
    assert RxRing.spans(2040, 2050) == {0, [{2040, 8}, {0, 2}]}
    assert RxRing.spans(0, 5000) == {5000 - 2048, [{904, 1144}, {0, 904}]}
    assert RxRing.spans(0xFFFF_FFFE, 3) == {0, [{2046, 2}, {0, 3}]}
  end
end
