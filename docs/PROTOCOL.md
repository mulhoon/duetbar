# The ApogeeGlue protocol

How Apogee Control 2 talks to Apogee hardware on macOS. Worked out by capturing
localhost traffic on a Duet 2 I own. Unofficial, and Apogee could change it.

## Where control actually happens

Audio is class compliant and handled by macOS. Hardware control goes through
`ApogeeGlue`, a root daemon installed with Apogee's software. It listens on a
localhost TCP port (53435 on my machine, possibly assigned at startup) and serves
several clients at once, so you can connect alongside Control 2 without
disturbing it.

**CoreAudio is a dead end.** The Duet 2 advertises USB Audio Class volume and
gain controls with convincing ranges, 0 to 75 dB on the preamps, which matches
the spec. You can set them. You can read back the values you set. The firmware
ignores all of it. Measured: record the input at 0 dB and at 60 dB of "gain" and
the signal is identical, RMS 0.000546 against 0.000548.

## Transport

JUCE 7.0.12 `InterprocessConnection`:

```
f2b49e2c | length (uint32 LE) | payload
```

Send `21 00 bb 00`, framed, as your first message. The server stays silent until
you do.

## Messages

**Opcode `0x66`**, server to client: a zlib compressed JUCE `ValueTree` with all
state. Several arrive on connect. The one you want has a populated `dev` node;
the others carry app state with `dev` empty.

**Opcode `0x68`**: meter data, constant, ignore it. It's most of the traffic, and
draining the socket without a deadline never returns.

**Opcode `0x03`**, client to server: set one property.

```
byte 0      0x03
byte 1      length of byte 3 onwards
byte 2      CRC-8 of bytes 0 and 1
byte 3      JUCE var marker: 1 int32, 3 bool, 4 double, 5 string
bytes 4-7   property ID
bytes 8..   value: 1 byte bool, 4 byte LE int32, or 8 byte LE double
last byte   CRC-8 of every preceding byte
```

Both checksums are CRC-8, polynomial `0x07`, init `0x00`. Byte 2 is chosen so the
running CRC is zero by the time the body starts.

Example, mute the speakers:

```
f2b49e2c 0a000000  03 06 2d03 c0bfb2a1 01 58
```

## Property IDs, Duet 2

Opaque 32-bit values. They are **not** a hash of the tree path: crc32, JUCE's
`String::hashCode`, FNV-1, FNV-1a, djb2, sdbm and adler32 were all ruled out. They
are stable across sessions and reboots, and they're model specific, so another
interface needs its own set.

| Control | ID | Type |
| --- | --- | --- |
| Speaker level | `26b9afa1` | double, dB, -64 to 0 |
| Speaker mute | `c0bfb2a1` | bool |
| Speaker dim | `01469a91` | bool |
| Speaker sum to mono | `c47f9a91` | bool |
| Speaker line level | `a87cf0c6` | int32, 2 = +4 dBu, 3 = -10 dBV |
| Headphone level | `c59164a3` | double, dB |
| Headphone mute | `5f9867a3` | bool |
| Headphone dim | `825da891` | bool |
| Headphone sum to mono | `4597a891` | bool |
| Sample rate | `f1d635bf` | int32, Hz |
| Input 1 source | `6876875c` | int32, see below |
| Input 1 mic gain | `9c4a9874` | double, dB |
| Input 1 instrument gain | `09d48cc3` | double, dB |
| Input 1 48V | `41070c92` | bool |
| Input 1 soft limit | `aa6268e5` | bool |
| Input 1 phase invert | `4d938b39` | bool |
| Input 2 source | `4754193e` | int32 |
| Input 2 mic gain | `dd128189` | double, dB |
| Input 2 instrument gain | `e813bd4b` | double, dB |
| Input 2 48V | `c2fca49e` | bool |
| Input 2 soft limit | `6b154d7a` | bool |
| Input 2 phase invert | `2c711d1b` | bool |

Input source is one four-way picker, not a mode plus a separate level:

```
1 = Mic    2 = +4 dBu    3 = -10 dBV    4 = Instrument
```

## Things that will bite you

**Writing an inactive input gain corrupts both.** Each input stores a mic gain
and an instrument gain. Writing the gain ID for the mode the input is *not*
currently in overwrites both stored values. Only write the active mode's gain. To
change the other, switch the input's source first, then write.

**Instrument gain stops at 65 dB.** Mic goes to 75. Write 66 to the instrument
gain and it comes back 65.

**Verify your message builder against captured bytes.** An off-by-one in the
length field produces messages the daemon accepts and silently ignores, which
looks exactly like the write working.

## Reading state

The `0x66` payload is a standard JUCE `ValueTree`, zlib compressed. If you're
decoding by hand: a UTF-8 null terminated type name, a compressed int property
count, then name and `var` pairs, then a compressed int child count and the
children recursively.

Compressed int is a length byte, high bit meaning negative, followed by that many
little endian bytes. A `var` is a compressed int byte count, then a marker byte,
then the data.

Apple's Compression framework speaks raw DEFLATE, so skip the two byte zlib
header and let it ignore the trailer.

Types aren't consistent across the tree. The same logical flag can arrive as a
bool on one node and the string `"0"` on another, so accept both.
