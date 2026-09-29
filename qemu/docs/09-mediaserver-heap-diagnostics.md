# Mediaserver Heap Diagnostics

The optional heap tracer records Froyo dlmalloc chunk geometry around the tiny
allocation used by the MPEG4 metadata size-wrap path. It is disabled during
normal boots and does not affect the standard `media` service.

## Usage

Start a fresh VM, attach the test card, and install the caller JAR as usual.
Then replace the normal mediaserver with the traced service:

```sh
./rlink-qemu heap-trace-start
./rlink-qemu heap-trace-arm

# Run exactly one parser request, for example:
./rlink-qemu exec \
  'CLASSPATH=/data/local/tmp/playfile.jar app_process /system/bin PlayFile /mnt/sdcard/allocator-lattice-probe.m4a'

./rlink-qemu heap-trace-show > heaptrace.txt
python3 ./analyze-heaptrace.py heaptrace.txt 0x000a2fd0 0x000a2198
./rlink-qemu heap-trace-stop
```

`heap-trace-arm` creates a marker checked only for zero/single-byte allocations,
so mediaserver can finish normal startup without an allocator walk. A traced
mediaserver automatically restarts after a crash and appends another `INIT`
record. Use `heap-trace-clear` between experiments and `heap-trace-disarm` to
leave the traced process running without new snapshots.

The log is `/data/local/tmp/mediaserver-heaptrace.log` in the guest.
`analyze-heaptrace.py` reports which pre-overflow dlmalloc chunk contains each
address and whether it points into the user area or allocator metadata. Addresses
from an old tombstone must be reproduced under tracing; they cannot be mapped
against a different process instance's heap.

## Record format

All values are hexadecimal except `FREE_SEQUENCE`:

- `INIT`: tracer address and the original dlmalloc/free dispatch functions.
- `SMALL_ALLOC`: user pointer, requested size, `prev_foot`, chunk `head`, caller.
- `WALK_BEGIN` / `WALK_END`: address window traversed with
  `dlmalloc_walk_heap`.
- `USED` / `FREE`: chunk pointer, chunk size, user pointer, usable size, raw
  `head` word before the overflow copy.
- `SMALL_FREE`: the wrapped allocation is about to be freed.
- `POST_FREE`: another pointer is about to be freed after the small allocation.

For an in-use dlmalloc chunk, `head & ~7` is its size; bit 0 is `PINUSE` and bit
1 is `CINUSE`. `prev_foot` is meaningful to `dlfree` only when `PINUSE` is clear.
The free records are written before calling the real allocator, so the last
record survives an allocator abort.

## Current allocator-lattice observation

One traced QEMU run placed the relevant small allocation at `0x0009eea8`:

```text
QHEAP SMALL_ALLOC ... a=0x0009eea8 b=0x00000000 ... d=0x00000013
QHEAP FREE_SEQUENCE 1
QHEAP SMALL_FREE ... a=0x0009eea8 b=0x8128f248 c=0x00000013 ...
QHEAP FREE_SEQUENCE 2
QHEAP POST_FREE ... a=0x0009ec38 b=0x8128f248 c=0x00000023 ...
```

Thus the first free after that overflow is the overflow buffer itself. Its
16-byte chunk header (`head=0x13`) retains both in-use bits, so the overwritten
`prev_foot` is ignored and that free survives. Later neighboring frees see a
different set of corrupted headers; this allocation adjacency, rather than a
different libc binary, explains why an untraced QEMU run can reach `deadbaad`
while the physical unit survives until a VectorImpl virtual dispatch.

## Perturbation warning

The diagnostic binary adds one DSO and replaces libc's malloc dispatch table.
Calls still reach the original allocator, but loader allocations, timing, and
the heap walk itself perturb the layout. Use the trace to identify chunk order
and headers, not as proof that exact addresses will match an uninstrumented run.
Always reproduce final crash signatures again with the normal mediaserver.

## Parser thread paths

`MediaMetadataRetriever` executes through a MediaPlayerService Binder thread.
A synchronous `MediaPlayer.prepare()` does likewise. `prepareAsync()` uses
AwesomePlayer's TimedEventQueue only after `setDataSource` accepts the track.

The playable-container work is now complete. `exploit/build_playable_variants.py`
preserves the known-good AAC file's original `ftyp/free/mdat`, sample tables,
chunk offsets, and mdat-before-moov ordering while replacing only its existing
`ilst` payload. `playable_minimal_only.m4a` reports both `SET_OK` and
`PREPARE_ASYNC_RETURN`, then reaches the malformed metadata read on
`TimedEventQueue`. The source builders and invariant tests retain the relevant
addresses and staged-execution checks.
