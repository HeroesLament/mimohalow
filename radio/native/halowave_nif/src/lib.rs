//! NIF over halowave-rs for `MimoHalow.Halowave`. Entry points run on a
//! dirty CPU scheduler.

use halowave::air::{pack_into, Antennas};
use halowave::{one_shot, ppdu_8m, TxOpts};
use rustler::{Atom, Binary, Encoder, Env, NifResult, OwnedBinary, Term};

mod atoms {
    rustler::atoms! { ok, error, tx1, tx2, both }
}

fn antennas(a: Atom) -> NifResult<Antennas> {
    if a == atoms::tx1() {
        Ok(Antennas::Tx1)
    } else if a == atoms::tx2() {
        Ok(Antennas::Tx2)
    } else if a == atoms::both() {
        Ok(Antennas::Both)
    } else {
        Err(rustler::Error::BadArg)
    }
}

fn owned(bytes: &[u8]) -> NifResult<OwnedBinary> {
    let mut b = OwnedBinary::new(bytes.len()).ok_or(rustler::Error::Term(Box::new("alloc")))?;
    b.as_mut_slice().copy_from_slice(bytes);
    Ok(b)
}

/// 1 MB ring image: `lead` zero frames, the PPDU, silence.
/// -> {:ok, image, ppdu_frames} | {:error, reason}
#[rustler::nif(schedule = "DirtyCpu")]
fn one_shot_nif<'a>(env: Env<'a>, psdu: Binary<'a>, mcs: u8, lead: usize, ant: Atom) -> NifResult<Term<'a>> {
    let o = TxOpts { mcs, ..TxOpts::default() };
    match one_shot(psdu.as_slice(), &o, antennas(ant)?, lead) {
        Ok(s) => {
            let img = owned(&s.image)?.release(env);
            Ok((atoms::ok(), img, s.ppdu).encode(env))
        }
        Err(e) => Ok((atoms::error(), e.to_string()).encode(env)),
    }
}

/// Packed PPDU frames only (8 bytes each), no lead or padding.
#[rustler::nif(schedule = "DirtyCpu")]
fn frames_nif<'a>(env: Env<'a>, psdu: Binary<'a>, mcs: u8, ant: Atom) -> NifResult<Term<'a>> {
    let o = TxOpts { mcs, ..TxOpts::default() };
    match ppdu_8m(psdu.as_slice(), &o, antennas(ant)?) {
        Ok(f) => {
            let mut v = Vec::new();
            pack_into(&mut v, &f);
            let b = owned(&v)?.release(env);
            Ok((atoms::ok(), b).encode(env))
        }
        Err(e) => Ok((atoms::error(), e.to_string()).encode(env)),
    }
}

/// frames_nif/3 in PortWire wire order: each 32-bit word big-endian (the
/// ring's little-endian u64 frames with every 4-byte group reversed).
#[rustler::nif(schedule = "DirtyCpu")]
fn frames_wire_nif<'a>(env: Env<'a>, psdu: Binary<'a>, mcs: u8, ant: Atom) -> NifResult<Term<'a>> {
    let o = TxOpts { mcs, ..TxOpts::default() };
    match ppdu_8m(psdu.as_slice(), &o, antennas(ant)?) {
        Ok(f) => {
            let mut v = Vec::new();
            pack_into(&mut v, &f);
            for w in v.chunks_exact_mut(4) {
                w.reverse();
            }
            let b = owned(&v)?.release(env);
            Ok((atoms::ok(), b).encode(env))
        }
        Err(e) => Ok((atoms::error(), e.to_string()).encode(env)),
    }
}

/// CTRL3 command words for the PHY's fabric transmitter (`halowave::fabric`).
/// -> {:ok, [word]} | {:error, reason}
#[rustler::nif]
fn fabric_cmds_nif<'a>(env: Env<'a>, psdu: Binary<'a>, mcs: u8) -> NifResult<Term<'a>> {
    let o = TxOpts { mcs, ..TxOpts::default() };
    match halowave::fabric::commands(psdu.as_slice(), &o) {
        Ok(w) => Ok((atoms::ok(), w).encode(env)),
        Err(e) => Ok((atoms::error(), e.to_string()).encode(env)),
    }
}

rustler::init!("Elixir.MimoHalow.Halowave");
