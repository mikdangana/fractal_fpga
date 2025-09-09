# merge_operations_nontrie_fixed.py
# Merge tree (tapered counters) + per-chunk variable-width IDs (hbits).
# NEW: Top balanced prefix of the tree is NOT stored; a 1-bit TRUNC flag
#      indicates truncation, and the truncated depth s is inferred from L1
#      as tzcount(L1), capped at L. Persist verifies actual balance; if any
#      mismatch, TRUNC=0 and full tree is serialized.
#
# Header (big-endian bit fields):
#   [16b L][32b NBYTES][32b L1][1b TRUNC][32b TREE_BITS_LEN][32b HBITS_LEN]
#   [ TREE_BITS (possibly from depth s frontier) ][ HBITS ]
#
# On load, if TRUNC=1:
#   - s = tzcount(L1) capped at L
#   - build a synthetic balanced prefix of s levels (each left/right = parent//2)
#   - read TREE_BITS and attach subtrees below the depth-s frontier (left-to-right)
#
# Exact bit-accurate reconstruction preserved.

import math, sys
from math import ceil, log2
from typing import Dict, List

# ────────────────────────── bit utils ──────────────────────────

def _bytes_to_bits(b: bytes) -> str:
    return "".join(f"{x:08b}" for x in b)

def _bits_to_bytes(bitstr: str) -> bytes:
    if not bitstr:
        return b""
    if len(bitstr) % 8:
        bitstr += "0" * (8 - (len(bitstr) % 8))
    return int(bitstr, 2).to_bytes(len(bitstr) // 8, "big")

def _rd_bits(buf: List[str], n: int) -> str:
    if n == 0: return ""
    seg, buf[0] = buf[0][:n], buf[0][n:]
    return seg

def _rd_u(buf: List[str], nbits: int) -> int:
    if nbits == 0: return 0
    return int(_rd_bits(buf, nbits) or "0", 2)

def _w_cnt(parent: int) -> int:
    """Tapered counter width for value in [0..parent]."""
    if parent == 0: return 0
    return math.ceil(math.log2(parent + 1))

def _tzcount(n: int) -> int:
    """Number of trailing zero bits in n (largest s s.t. 2^s divides n)."""
    if n <= 0: return 0
    c = 0
    while (n & 1) == 0:
        c += 1
        n >>= 1
    return c

# Variable-width hbits reader: i-th id uses ceil(log2(i)) bits (1-based)
def _read_varwidth_ids(buf: List[str], L1: int) -> List[int]:
    ids = []
    # EXACT schedule (1-based): w1=0, w2=1, w3=2, w4=2, w5=3, ...
    for i in range(1, L1 + 1):
        w = 0 if i == 1 else math.ceil(math.log2(i))
        if w == 0:
            ids.append(0)
        else:
            ids.append(_rd_u(buf, w))
    return ids

# ──────────────────────── merge tree (counts) ────────────────────────

class Node:
    __slots__ = ("cnt", "kids", "_L", "_N")
    def __init__(self):
        self.cnt: int = 0
        self.kids: Dict[str, "Node"] = {}
        self._L: int = 0
        self._N: int = 0

def _build_tree_from_sequence(sequence: List[str], L: int, N_bits: int) -> Node:
    """Build full tree first (counts), independent of serialization order."""
    root = Node(); root._L = L; root._N = N_bits
    for chunk in sequence:
        n = root; n.cnt += 1
        for b in chunk:
            child = n.kids.get(b)
            if child is None:
                child = Node(); n.kids[b] = child
            child.cnt += 1; child._L = L; child._N = N_bits
            n = child
    return root

def _write_subtree(node: Node, parent: int, depth: int, L: int, out_bits: List[str]):
    """Serialize subtree in a single DFS pass: one left_cnt per internal node."""
    if depth >= L or parent == 0:
        return
    left_cnt = node.kids.get("0", Node()).cnt
    right_cnt = parent - left_cnt
    print("write_subtree().d,left,right =", depth, left_cnt, right_cnt)
    #out_bits.append(f"{left_cnt:0{_w_cnt(parent)}b}")
    if depth < L:
        left_bit = 1 if left_cnt > 0 else 0
        right_bit = 1 if right_cnt > 0 else 0
        out_bits.append(f"{left_bit:01b}{right_bit:01b}")
    if left_cnt > 0:
        _write_subtree(node.kids.get("0", Node()), left_cnt, depth + 1, L, out_bits)
    if right_cnt > 0:
        _write_subtree(node.kids.get("1", Node()), right_cnt, depth + 1, L, out_bits)

def _read_subtree(buf: List[str], parent: int, depth: int, L: int) -> Node:
    n = Node(); n.cnt = parent; n._L = L
    #print("read_sub().depth, L, parent, node =", depth, L, parent, n.cnt)
    if depth >= L or parent == 0:
        return n
    #left_cnt = _rd_u(buf, _w_cnt(parent))
    left_cnt = _rd_u(buf, 1)
    right_cnt = _rd_u(buf, 1)
    if left_cnt < 0: left_cnt = 0
    if left_cnt > parent: left_cnt = parent
    #right_cnt = parent - left_cnt
    print("read_subtree().parent=", parent, ", lcnt=", left_cnt, ", rcnt=",right_cnt)
    if left_cnt > 0:
        n.kids["0"] = _read_subtree(buf, left_cnt, depth + 1, L)
    if right_cnt > 0:
        n.kids["1"] = _read_subtree(buf, right_cnt, depth + 1, L)
    return n

def _enumerate_leaves(node: Node, prefix: str, depth: int, L: int, out_pairs: List[tuple]):
    """Collect (leaf_bits, count) in lexicographic order."""
    if depth >= L:
        if node.cnt > 0:
            out_pairs.append((prefix, node.cnt))
        return
    if "0" in node.kids:
        _enumerate_leaves(node.kids["0"], prefix + "0", depth + 1, L, out_pairs)
    if "1" in node.kids:
        _enumerate_leaves(node.kids["1"], prefix + "1", depth + 1, L, out_pairs)

# Balanced-prefix detection and frontier extraction
def _max_balanced_prefix(root: Node, L: int) -> int:
    """
    Return the largest s (<=L) such that levels 0..s-1 are perfectly balanced:
      for every node at those levels, left_cnt == right_cnt == parent//2 (parent even).
    """
    if root.cnt <= 0: return 0
    s = 0
    layer = [root]
    while s < L:
        next_layer = []
        for n in layer:
            p = n.cnt
            #print("max_bal().n =", n.cnt)
            #if (p & 1) != 0:  # odd => can't split evenly
            #    return s
            l = n.kids.get("0", Node()).cnt
            r = n.kids.get("1", Node()).cnt
            #print("max_bal().l,r =", l,r)
            if l==0 or r==0: #l != p // 2 or r != p // 2:
                return s
            next_layer.extend([n.kids["0"], n.kids["1"]])
        layer = next_layer
        s += 1
    return s

def _frontier_at_depth(root: Node, depth: int) -> List[Node]:
    """Left-to-right list of nodes at exact 'depth'."""
    if depth <= 0:
        return [root]
    layer = [root]
    for _ in range(depth):
        nxt = []
        for n in layer:
            if "0" in n.kids: nxt.append(n.kids["0"])
            if "1" in n.kids: nxt.append(n.kids["1"])
        layer = nxt
        if not layer:
            break
    return layer

def _build_balanced_prefix(root_cnt: int, s: int, L: int) -> Node:
    """Construct a synthetic perfectly-balanced prefix of depth s from root_cnt."""
    root = Node(); root.cnt = 1 if root_cnt>0 else 0; root._L = L
    layer = [root]
    for _ in range(s):
        nxt = []
        for n in layer:
            p = n.cnt
            l = Node(); r = Node()
            l.cnt = 1; r.cnt = 1; #p // 2; r.cnt = p // 2
            l._L = L; r._L = L
            n.kids["0"] = l
            n.kids["1"] = r
            nxt.extend([l, r])
        layer = nxt
    return root


def bytes_to_bit_chunks(data: bytes, L: int = None, f: float = 0.25, fn: str = "local_tree.bin") -> str:
    """
    Store:
      [16b L][32b NBYTES][32b L1][1b TRUNC][32b TREE_BITS_LEN][32b HBITS_LEN]
      [TREE_BITS (possibly truncated)][HBITS (variable widths by position)]
    """
    N_bytes = len(data)
    N_bits  = N_bytes * 8
    F = f

    # L = ceil(f * sqrt(N_bits)) if not given
    if L is None:
        L = max(1, math.ceil(f * math.sqrt(max(1, N_bits))))

    # Split into L-bit chunks (pad last chunk with zeros)
    bits = _bytes_to_bits(data)
    L1   = math.ceil(N_bits / L) if L > 0 else 0
    sequence: List[str] = []
    for i in range(L1):
        chunk = bits[i*L:(i+1)*L]
        if len(chunk) < L: chunk += "0" * (L - len(chunk))
        sequence.append(chunk)
    return sequence, L, L1


def num_permute_ids(nbits):
    i, pos = 0, 0
    while pos < nbits:
        pos += ceil(log2(i+1))
        i += 1
    return i


def permute_base(N):
    return ["0"*L if i<1 else "0"*(L-ceil(log2(i+1))) + f"{i:{ceil(log2(i+1))}b}" for i in range(N)]


def to_permute_bits(bits):
  L1 = 2**len(bits[0]) if len(bits) else 0
  hbits_list: List[str] = []
  excs_list = []
  for j in range(ceil(len(bits)/L1)):
    chunks, sequence = bits[j*L1:(j+1)*L1], permute_base(L1) #bits[j*L1:(j+1)*L1][:]
    excs = {}
    for s in list(filter(lambda s: s not in chunks, sequence)):
        excs[s] = 0
    print("to_permute().chunks,len,uniq =", chunks, len(chunks), len(set(chunks)))
    #sequence.sort()
    ids = []
    for item in sequence:
        ids.append(0) if item not in chunks else None
        while item in chunks:
            ids.append(chunks.index(item))
            chunks.remove(item)
            if item in chunks:
                excs[item] = excs[item] + 1 if item in excs else 2

    for i, val in enumerate(ids, start=1):
        i = len(ids)-i+1
        w = 0 if i <= 1 else math.ceil(math.log2(i))
        if w > 0:
            # Truncate higher bits if val >= 2^w (to match the reading schedule)
            hbits_list.append(f"{val:0{w}b}")
    excs_list.extend([f"{s}{c:02b}" for c,s in enumerate(excs)])
    print("to_permute().excs,ebits =", excs, len(excs), excs_list[-len(excs):])
    print("to_permute().ids =", ids)
  print("to_permute().hbits =", [f"{h}:{len(h)}" for h in hbits_list], len(hbits_list))
  hbits = "".join(hbits_list)
  return hbits, "".join(excs_list)


def from_permute_bits(hbits, ebits, L, L1):
  hbuf, pos, seq = [hbits], 0, []
  while pos < len(hbits):
    ids = []
    L1 = min(2**L, num_permute_ids(len(hbits)-pos))
    for i in range(L1):
        w = 0 if L1-i<=1 else math.ceil(math.log2(L1-i))
        if w == 0:
            ids.append(0)
        else:
            idx = _rd_bits(hbuf, w)
            pos = pos + w
            #if len(idx) != w:
                #raise ValueError(f"hbits underflow at i={i}, w,idx=", w, len(idx))
                #print(f"hbits underflow at i={i}, w,idx=", w, len(idx))
            if len(idx) == w:
                ids.append(int(idx, 2))

    w = L #math.ceil(math.log2(L1 + 1))
    print("from_permute().L,L1,log =", L, L1, ceil(log2(len(ids))))
    s_chunks = permute_base(len(ids)) #["0"*L if i<1 else "0"*(L-ceil(log2(i+1))) + f"{i:{ceil(log2(i+1))}b}" for i in range(len(ids))]
    sequence = []
    print("from_permute().ids =", ids, len(ids))
    ids.reverse()
    for i,idx in enumerate(ids):
        sequence.insert(idx, s_chunks[i]) if idx < 15 else None
        print("from_permute().sequence,idx =", sequence, idx)
    print("from_permute().sequence,pos,hbits =", sequence, pos, len(hbits))
    seq = seq + sequence
  return seq


# ─────────────────────────── persist/load ───────────────────────────
persist_calls = 0

def persist(data: bytes, L: int = None, f: float = 0.25, fn: str = "local_tree.bin") -> str:
    """
    Store:
      [16b L][32b NBYTES][32b L1][1b TRUNC][32b TREE_BITS_LEN][32b HBITS_LEN]
      [TREE_BITS (possibly truncated)][HBITS (variable widths by position)]
    """
    N_bytes = len(data)
    N_bits  = N_bytes * 8
    F = f

    # L = ceil(f * sqrt(N_bits)) if not given
    if L is None:
        L = max(1, math.ceil(f * math.sqrt(max(1, N_bits))))

    # Split into L-bit chunks (pad last chunk with zeros)
    bits = _bytes_to_bits(data)
    print("persist().bits =", bits)
    L1   = math.ceil(N_bits / L) if L > 0 else 0
    sequence: List[str] = []
    for i in range(L1):
        chunk = bits[i*L:(i+1)*L]
        if len(chunk) < L: chunk += "0" * (L - len(chunk))
        sequence.append(chunk)

    # Build the tree fully
    root = _build_tree_from_sequence(sequence, L, N_bits)

    # Decide truncation depth: s_target = tzcount(L1) capped at L
    s_target = min(_tzcount(L1), L)
    # Verify actual tree is perfectly balanced up to s_target; otherwise disable trunc
    s_actual = _max_balanced_prefix(root, L)
    TRUNC = 0 #1 if s_actual >= 0 else 0
    s = s_actual if TRUNC else 0
    print("persist().target,actual,trunc,s", s_target, s_actual, TRUNC, s)

    # Serialize tree: if TRUNC, serialize from depth-s frontier (left→right)
    tree_bits_list: List[str] = []
    if TRUNC:
        frontier = _frontier_at_depth(root, s)
        print("persist().trunc,frontier =", TRUNC, len(frontier), " root.cnt=",root.cnt)
        for n in frontier:
            _write_subtree(n, n.cnt, s, L, tree_bits_list)
    else:
        _write_subtree(root, L1, 0, L, tree_bits_list)

    tree_bits = "".join(tree_bits_list)
    tree_bits_len = len(tree_bits)

    # Build hbits (variable-width by position) from your ids logic.
    # Here we reconstruct a stable ids list: ids[i] = original position of sequence[i] among remaining.
    # If you already have your own ids list, plug it in instead.
    ids, seq = [], sequence[:]
    # Create a reproducible order per leaf (lexicographic by leaf, original-order within leaf)
    leaves_cnts: List[tuple] = []
    _enumerate_leaves(root, "", 0, L, leaves_cnts)
    leaves_expts = list(filter(lambda l: l[1]>1, leaves_cnts))
    per_leaf_rows: Dict[str, List[int]] = {leaf: [] for leaf, _ in leaves_cnts}
    for idx, ch in enumerate(sequence):
        per_leaf_rows[ch].append(idx)
    # ids := "stable positions" per leaf, in lexicographic leaf order
    print("persist().leaf_expts =", leaves_expts, "\n leaves_cnts=", leaves_cnts, "\n per_leaf_rows=", per_leaf_rows)
    for leaf, cnt in leaves_cnts:
        for _row in per_leaf_rows[leaf]:
            ids.append(seq.index(leaf))
            seq.remove(leaf)

    # Variable-width pack: w_i = ceil(log2(i)) for i=1..L1, store id_i truncated to w_i bits (id_1=0)
    hbits_list: List[str] = []
    print("persist().ids =", ids)
    for i, val in enumerate(ids):
        i = len(ids)-i
        w = 0 if i <= 1 else math.ceil(math.log2(i))
        if w > 0:
            # Truncate higher bits if val >= 2^w (to match the reading schedule)
            #hbits_list.append(f"{(val & ((1<<w)-1)):0{w}b}")
            hbits_list.append(f"{val:0{w}b}")
            print("persist().id,w =", val, w)
    hbits = "".join(hbits_list)
    HBITS_LEN = len(hbits)
    print("persist().tree_bits =", tree_bits, "\n hbits=", hbits)

    max_c = max([c for _,c in leaves_expts]) if len(leaves_expts) else 0
    exc_bits = "".join([f"{l}{c:0{max_c}b}" for l,c in leaves_expts])

    # Header + payload (note: TRUNC is 1 bit)
    header = (
        f"{L:016b}"
        f"{N_bytes:032b}"
        f"{L1:032b}"
        f"{TRUNC:01b}"
        f"{tree_bits_len:032b}"
        f"{HBITS_LEN:032b}"
        f"{len(exc_bits):032b}"
        f"{max_c:08b}"
    )
    payload = header + tree_bits + hbits + exc_bits 
    with open(fn, "wb") as f:
        f.write(_bits_to_bytes(payload))
    print("persist().hdr,tree,hbits,expts,N =",len(header)/8,tree_bits_len/8,HBITS_LEN/8, len(exc_bits)/8, N_bytes)
    print()
    global persist_calls
    if persist_calls < 0:
        persist_calls = persist_calls + 1
        fn1 = persist(_bits_to_bytes(tree_bits + hbits), fn="local_tree1.bin", f=F)
    return fn


def load(fn: str) -> bytes:
    """
    Decode with truncation support:
      - Read TRUNC flag.
      - If TRUNC=1: s = tzcount(L1) capped at L, synthesize balanced prefix of s levels.
                    Then read TREE_BITS for each depth-s frontier node and attach subtrees.
      - Else: read full tree normally.
      - Decode variable-width HBITS (same position-based schedule) into ids.
      - Rebuild original chunk stream (column-major with NR=L1 ⇒ original order).
    """
    raw = open(fn, "rb").read()
    buf = [_bytes_to_bits(raw)]

    # Header
    L       = _rd_u(buf, 16)
    N_bytes = _rd_u(buf, 32)
    L1      = _rd_u(buf, 32)
    TRUNC   = _rd_u(buf, 1)
    tree_bits_len = _rd_u(buf, 32)
    HBITS_LEN     = _rd_u(buf, 32)
    EBITS_LEN     = _rd_u(buf, 32)
    MAX_C     = _rd_u(buf, 8)

    # Tree bits slice (isolated buffer for subtree parsing)
    tree_bits = _rd_bits(buf, tree_bits_len)
    tbuf = [tree_bits]

    # Read tree with/without truncated prefix
    if TRUNC == 1:
        s = min(_tzcount(L1), L) # inference from L1 (validated at persist side)
        # Build balanced prefix of depth s
        root = _build_balanced_prefix(L1, s, L)
        # Attach subtrees from depth s frontier
        frontier = _frontier_at_depth(root, s)
        for n in frontier:
            print("load().tree[0] =", tbuf[0][0:5])
            # Read this subtree and graft it under n
            sub = _read_subtree(tbuf, n.cnt, s, L)
            n.kids = sub.kids  # counts already set; we keep n.cnt
    else:
        root = _read_subtree(tbuf, L1, 0, L)

    # Leaves and counts (lexicographic) for reconstruction
    leaves_cnts: List[tuple] = []
    _enumerate_leaves(root, "", 0, L, leaves_cnts)
    total_cnt = sum(cnt for _, cnt in leaves_cnts)
    if total_cnt != L1:
        # guard: if mismatch, trust tree counts
        L1 = total_cnt

    # Read HBITS and decode variable-width ids
    hbits_bits = _rd_bits(buf, HBITS_LEN)
    print("load().tree_bits =", tree_bits, "\n hbits=", hbits_bits)
    hbuf = [hbits_bits]
    ids = []
    pos = 0
    for i in range(L1):
        i = L1 - i
        w = 0 if i == 1 else math.ceil(math.log2(i))
        if w == 0:
            ids.append(0)
        else:
            chunk = _rd_bits(hbuf, w)
            if len(chunk) != w:
                raise ValueError(f"hbits underflow at i={i}")
            ids.append(int(chunk, 2))
            print("load().i,w,id =", i, w, ids[-1])
            pos += w

    # optional sanity: leftover bits in HBITS block?
    if len(hbuf[0]) != 0:
        # ignore final 0..7 bit padding if you ever pad HBITS separately
        pass

    leaf_exc = {}
    ex_bits = _rd_bits(buf, EBITS_LEN)
    ebuf, pos = [ex_bits], 0
    while pos <= EBITS_LEN:
        w = L
        leaf = _rd_bits(ebuf, w)
        cnt = _rd_bits(ebuf, MAX_C)
        if len(cnt) > 0:
            leaf_exc[leaf] = int(cnt, 2)
        pos += w + MAX_C

    for i,lc in enumerate(leaves_cnts):
        leaf, cnt = lc
        if leaf in leaf_exc:
            leaves_cnts[i] = (leaf, leaf_exc[leaf])

    # Reconstruct per-leaf row queues same as persist (ids semantics depend on your use)
    # Here we re-create the per-leaf emission order (lexicographic by leaf).
    per_leaf_rows: Dict[str, List[int]] = {leaf: [] for leaf, _ in leaves_cnts}
    rows, pos, cnt = [], len(leaves_cnts)-1, 0
    for idx in reversed(ids):
        cnt = leaves_cnts[pos][1] if cnt <= 1 else cnt - 1
        rows.insert(idx, leaves_cnts[pos][0])
        pos -= 1 if cnt<= 1 else 0
    for i, leaf in enumerate(rows):
        per_leaf_rows[leaf].append(i)
    print("load().rows=", rows, "\n per_leaf_rows =", per_leaf_rows)
    # Interpret ids as stable positions for a column-major NR=L1 layout:
    # original stream order is 0..L1-1; rows == indices.
    # Fill per-leaf queues by distributing occurrences in the same order as persist.
    # We will simply rebuild the original sequence by round-robin over rows (NR=L1),
    # pulling leaf labels from per-row FIFO queues.
    # Build per-leaf rows by walking leaves_cnts and using a working copy of ids
    wid = 0
    for leaf, cnt in leaves_cnts:
        cnt += leaf_exc[leaf] if leaf in leaf_exc else 0
        # grab cnt ids (even if many are zero due to small w_i early)
        chunk_ids = ids[wid:wid+cnt]
        wid += cnt
        # map them back to rows (here they are already row indices modulo schedule truncation)
        #for v in chunk_ids:
        #    per_leaf_rows[leaf].append(v)

    print("leaf_exc=", leaf_exc, "\n leaves_cnts=", leaves_cnts, "\n per_leaf_rows=", per_leaf_rows)

    # Build per-row queues of leaves using the order per_leaf_rows
    NR = L1
    queues: List[List[str]] = [[] for _ in range(NR)]
    for leaf, rows in per_leaf_rows.items():
        for r in rows:
            queues[r % NR].append(leaf)

    # Column-major interleave rows (with NR=L1 ⇒ original order)
    chunks: List[str] = []
    remaining = L1
    row = 0
    while remaining > 0:
        if queues[row]:
            chunks.append(queues[row].pop(0))
            remaining -= 1
        row = (row + 1) % NR

    # Convert to bytes (trim to exact bit length)
    bitstream = "".join(chunks)[: N_bytes * 8]
    if not bitstream:
        return b""
    return int(bitstream, 2).to_bytes(len(bitstream)//8, "big")


# ────────────────────────── tiny demo ──────────────────────────

if __name__ == "__main__":
    import os, random
    N = int(sys.argv[sys.argv.index("-N")+1]) if "-N" in sys.argv else 64
    f = float(sys.argv[sys.argv.index("-F")+1]) if "-F" in sys.argv else 0.25
    TEXT = "".join([random.choice("0123456789 abcdefghijoklmnopqrstuvwxyz") for _ in range(N)]).encode()

    fn = persist(TEXT, fn="local_tree.bin", f=f)
    out = load(fn)
    #chunks, L, L1 = bytes_to_bit_chunks(TEXT, fn="local_tree.bin", f=f)
    #hbits, ebits = to_permute_bits(chunks)
    #out = from_permute_bits(hbits, ebits, L, L1)
    #print("test().chunks,hbits,out,test =", len(chunks), len(hbits)/8, len(out), out[0:5], chunks[0:5], out==chunks)
    #if True:
    #    exit(0)

    print("saved", fn, "(size:", os.path.getsize(fn), "bytes)")
    print("round-trip ok:", out == TEXT)
    print("original    :", TEXT)
    print("reconstructed:", out)

