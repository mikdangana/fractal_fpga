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


import random
import string
import base64, io, math, sys, re, numpy as np
import ollama, os, pickle, tiktoken
import json
from collections import defaultdict

import tiktoken
from math import ceil, floor, log2, sqrt
from scipy.special import lambertw
from typing import Dict, List

# ────────────────────────── bit utils ──────────────────────────
sys.stdout = io.TextIOWrapper(sys.stdout.detach(), encoding='utf-8')

vb = False

enc = tiktoken.get_encoding("cl100k_base")

wtok_map = None

def get_wchar_tokens(w = 2):
    global wtok_map

    if not wtok_map is None:
        return wtok_map

    # Get all token IDs in the vocabulary
    token_ids = enc.encode_ordinary("")  # returns an empty list; use ._tokenizer instead

    # The vocabulary is accessible via enc._decode_cache or enc._mergeable_ranks/enc._tokenizer (undocumented)
    # Safest is to get the full list using private API
    all_tokens = []
    for tok in range(enc.n_vocab):
      try:
        decoded = enc.decode([tok])
        all_tokens.append(decoded)
      except KeyError:
        # Token is invalid for decoding, skip it
        continue

    # Filter for w-character tokens
    print("get_wchar_tokens().w0=", len([tok for tok in all_tokens if len(tok) >= 0]))
    print("get_wchar_tokens().w1=", len([tok for tok in all_tokens if len(tok) >= 1]))
    print("get_wchar_tokens().w2=", len([tok for tok in all_tokens if len(tok) >= 2]))
    print("get_wchar_tokens().w3=", len([tok for tok in all_tokens if len(tok) >= 3]))
    wchar_tokens = [tok for tok in all_tokens if len(tok) >= w]
    wtok_map = {}
    for tok in wchar_tokens:
        if not tok[0] in wtok_map.keys():
            wtok_map[tok[0]] = {} 
        if len(tok)>0 and not tok[1] in wtok_map[tok[0]].keys():
            wtok_map[tok[0]][tok[1]] = []
        if len(tok)>0:
            wtok_map[tok[0]][tok[1]].append(tok[2:]) 
        #else:
        #    wtok_map[tok[0]].append(tok[1:]) 
    print("get_wchar_tokens().keys,v.len =", len(wtok_map.keys()), sum([len(v) for k,v in wtok_map.items()])/len(wtok_map.keys())) if vb else None
    return wtok_map


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
    __slots__ = ("cnt", "kids", "_L", "_N", "_full")
    def __init__(self):
        self.cnt: int = 0
        self.kids: Dict[str, "Node"] = {}
        self._L: int = 0
        self._N: int = 0
        self._full: bool = False

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

    # --- iterative post-order to set `_full` without recursion ---
    def mark_full_iter(root: Node, L: int) -> None:
        # stack entries: (node, depth, processed_children)
        stack = [(root, 0, False)]
        while stack:
            node, depth, done = stack.pop()
            if not done:
                # push self back as "to finalize" after children
                stack.append((node, depth, True))
                if depth < L:
                    # push children (order doesn't matter for fullness calc)
                    # if a child is missing, we just won't push it; capacity still based on L
                    for kid in node.kids.values():
                        stack.append((kid, depth + 1, False))
            else:
                # post-order: children already processed; compute capacity at this depth
                remaining = max(0, L - depth)
                capacity = 1 << remaining  # max possible leaves under this node
                node._full = (node.cnt == capacity)
                for kid in node.kids.values():
                    node._full = node._full and kid._full

    mark_full_iter(root, 0)
    return root


def full_subtree(depth, L):
    return 2**(L-depth)


def create_full_subtree(n, depth, L, path=""):
    n.cnt = full_subtree(depth,L); n._L = L
    if depth < L:
        n.kids["0"] = create_full_subtree(Node(), depth + 1, L, path+"0")
        n.kids["1"] = create_full_subtree(Node(), depth + 1, L, path+"1")
    print("create_full_subtree().path,ncnt,d,L,kids =", path, n.cnt, depth, L, n.kids) if vb else None
    return n

def _write_subtree_taper(node: Node, parent: int, depth: int, L: int, out_bits: List[str], force=False):
    """
    Serialize tree in a single DFS pass AFTER the tree is built:
      • for each internal node (depth < L, parent > 0), write left_cnt using tapered width.
      • recurse into present children only.
    Each node appears exactly once in TREE_BITS.
    """
    if depth >= L or parent == 0:
        return
    left_cnt = node.kids.get("0", Node()).cnt
    out_bits.append(f"{left_cnt:0{_w_cnt(parent)}b}")
    print("write_subtree_taper().left_cnt,w,depth =", left_cnt, _w_cnt(parent), depth) if vb else None
    if left_cnt > 0:
        _write_subtree_taper(node.kids.get("0", Node()), left_cnt, depth + 1, L, out_bits)
    right_cnt = parent - left_cnt
    if right_cnt > 0:
        _write_subtree_taper(node.kids.get("1", Node()), right_cnt, depth + 1, L, out_bits)


def _read_subtree_taper(buf: List[str], parent: int, depth: int,L: int) -> Node:
    n = Node(); n.cnt = parent; n._L = L
    if depth >= L or parent == 0:
        return n
    left_cnt = _rd_u(buf, _w_cnt(parent))
    if left_cnt < 0: left_cnt = 0
    if left_cnt > parent: left_cnt = parent
    right_cnt = parent - left_cnt
    if left_cnt > 0:
        n.kids["0"] = _read_subtree_taper(buf, left_cnt, depth + 1, L)
    if right_cnt > 0:
        n.kids["1"] = _read_subtree_taper(buf, right_cnt, depth + 1, L)
    return n


def _write_subtree(node: Node, parent: int, depth: int, L: int, out_bits: List[str], w: int, force=False):
    """Serialize subtree in a single DFS pass: one left_cnt per internal node."""
    if depth >= L or parent == 0:
        if L <= 2 and force:
            print("write_subtree().d,L,parent,w =", depth, L, parent,w) if vb else None
            out_bits.append(f"{parent:0{w}b}")
        return
    left_cnt = node.kids.get("0", Node()).cnt
    right_cnt = parent - left_cnt
    print("write_subtree().d,left,right =", depth, left_cnt, right_cnt) if vb else None
    if depth == L-1:
        out_bits.append(f"{left_cnt:0{w}b}{right_cnt:0{w}b}")
    elif depth < L:
        left_bit = 1 if left_cnt > 0 else 0
        right_bit = 1 if right_cnt > 0 else 0
        if node._full:
            print("write_subtree().node full=True, l,r=0,0") if vb else None
            left_cnt, right_cnt, left_bit, right_bit = 0, 0, 0, 0
        out_bits.append(f"{left_bit:01b}{right_bit:01b}")
    if left_cnt > 0:
        _write_subtree(node.kids.get("0", Node()), left_cnt, depth + 1, L, out_bits, w)
    if right_cnt > 0:
        _write_subtree(node.kids.get("1", Node()), right_cnt, depth + 1, L, out_bits, w)

def _read_subtree(buf: List[str], parent: int, depth: int, L: int, w: int, force=False, path="") -> Node:
    n = Node(); n.cnt = parent; n._L = L
    if not force and (depth >= L or parent == 0):
        return n
    left_cnt = _rd_u(buf, 1 if depth < L-1 else max(w,1))
    right_cnt = _rd_u(buf, 1 if depth < L-1 else max(w,1))
    if left_cnt < 0: left_cnt = 0
    print("read_subtree().path,pnt,d,L=", path,parent, depth,L, ", lcnt=", left_cnt, ", rcnt=",right_cnt, ", w=", w) if vb else None
    if left_cnt == 0 and right_cnt == 0:
        return create_full_subtree(n, depth, L)
    if left_cnt > 0:
        n.kids["0"] = _read_subtree(buf, left_cnt, depth + 1, L, w, False, path+"0")
    if right_cnt > 0:
        n.kids["1"] = _read_subtree(buf, right_cnt, depth + 1, L, w, False, path+"1")
    return n

def _update_tree(node: Node, path: str, delta: int):
    """Update path in a single DFS pass: one cnt per internal node."""
    if len(path) == 0:
        return
    node.cnt += delta
    print("update_tree().path,delta,ncnt =", path, delta, node.cnt) if vb else None
    if len(path)>0 and path[0] == "0":
        _update_tree(node.kids.get("0", Node()), path[1:], delta)
    if len(path)>0 and path[0] == "1":
        _update_tree(node.kids.get("1", Node()), path[1:], delta)

def _enumerate_leaves(node: Node, prefix: str, depth: int, L: int, out_pairs: List[tuple]):
    """Collect (leaf_bits, count) in lexicographic order."""
    if depth >= L:
        if node.cnt > 0:
            out_pairs.append((prefix, node))
        return
    if "0" in node.kids:
        _enumerate_leaves(node.kids["0"], prefix + "0", depth + 1, L, out_pairs)
    if "1" in node.kids:
        _enumerate_leaves(node.kids["1"], prefix + "1", depth + 1, L, out_pairs)

# Balanced-prefix detection and frontier extraction
def _max_balanced_prefix(root: Node, L: int, N: int) -> int:
    """
    Return the largest s (<=L) such that levels 0..s-1 are perfectly balanced:
      for every node at those levels, left_cnt == right_cnt == parent//2 (parent even).
    """
    if N <= 0: return 0
    s = 0
    layer = [root]
    while s < L:
        next_layer = []
        for n in layer:
            l = n.kids.get("0", Node()).cnt
            r = n.cnt - l
            ##if (p & 1) != 0:  # odd => can't split evenly
            ##    return s
            #l = n.kids.get("0", Node()).cnt
            #r = n.kids.get("1", Node()).cnt
            if l==0 or r==0: #l != p // 2 or r != p // 2:
                return s
            next_layer.extend([n.kids["0"], n.kids["1"]])
        layer = next_layer
        s += 1
    return s

def _frontier_at_depth(root: Node, depth: int, L=-1) -> List[Node]:
    """Left-to-right list of nodes at exact 'depth'."""
    if depth <= 0 or depth == L:
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

def _build_balanced_prefix(root_cnt: int, s: int, L: int, buf: List[str], w: int) -> Node:
    """Construct a synthetic perfectly-balanced prefix of depth s from root_cnt."""
    root = Node(); root.cnt = 1 if root_cnt>0 else 0; root._L = L
    layer = [root]
    for _ in range(s):
        nxt = []
        for n in layer:
            l = Node(); r = Node()
            left_cnt = _rd_u(buf, max(w,1)) if len(buf) else 1
            right_cnt = _rd_u(buf, max(w,1)) if len(buf) else 1
            l.cnt = left_cnt; r.cnt = right_cnt; n.cnt = r.cnt + l.cnt
            print("build_balanced().l,r,w,s,L =", l.cnt,r.cnt,w,s,L) if vb else None
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


def serialize_taper(root, s, TRUNC, L, L2):
    # Serialize tree: if TRUNC, serialize from depth-s frontier (left→right)
    tree_bits_list: List[str] = []
    if False: #TRUNC>0:
        frontier = _frontier_at_depth(root, s)
        print("serialize_taper().trunc_level,frontier.len+nodes =", TRUNC, len(frontier), [n.cnt for n in frontier], " root.cnt=",root.cnt) if vb else None
        for n in frontier:
            _write_subtree_taper(n, n.cnt, s, L, tree_bits_list, s==L)
    else:
        _write_subtree_taper(root, L2, 0, L, tree_bits_list)

    tree_bits = "".join(tree_bits_list)
    tree_bits_len = len(tree_bits)
    return tree_bits


def serialize_tree(root, s, TRUNC, L, L2, max_c):
    # Serialize tree: if TRUNC, serialize from depth-s frontier (left→right)
    tree_bits_list: List[str] = []
    if TRUNC>0:
        frontier = _frontier_at_depth(root, s)
        print("persist().trunc_level,frontier.len+nodes =", TRUNC, len(frontier), [n.cnt for n in frontier], " root.cnt=",root.cnt, ", maxc=", max_c) if vb else None
        for n in frontier:
            _write_subtree(n, n.cnt, s, L, tree_bits_list, max_c, s==L)
    else:
        _write_subtree(root, L2, 0, L, tree_bits_list, max_c)

    tree_bits = "".join(tree_bits_list)
    return tree_bits


def deserialize_taper(tbuf, TRUNC, L, L2, MAX_C):
    if not len(tbuf):
        return Node()

    # Read tree with/without truncated prefix
    if TRUNC > 0:
        s = TRUNC # inference from L1 (validated at persist side)
        # Build balanced prefix of depth s
        root = _build_balanced_prefix(L2, s, L, [], MAX_C)
        # Attach subtrees from depth s frontier
        frontier = _frontier_at_depth(root, s-1 if s==L else s, L)
        for n in frontier:
            print("load().frontier.tree[0] =", tbuf[0][0:5], ", s=", s, ", L=",L, ", n.cnt=", n.cnt) if vb else None
            # Read this subtree and graft it under n
            sub = _read_subtree_taper(tbuf, n.cnt, s, L)
            n.kids = sub.kids  # counts already set; we keep n.cnt
    else:
        root = _read_subtree_taper(tbuf, L2, 0, L)
    print("deserialize_taper().root.cnt,kids,tbuff =", root.cnt, root.kids, tbuf) if vb else None
    return root


def deserialize_tree(tbuf, TRUNC, L, L2, MAX_C):
    # Read tree with/without truncated prefix
    if TRUNC > 0:
        s = TRUNC # inference from L1 (validated at persist side)
        # Build balanced prefix of depth s
        root = _build_balanced_prefix(L2, s, L, [], MAX_C)
        # Attach subtrees from depth s frontier
        frontier = _frontier_at_depth(root, s-1 if s==L else s, L)
        for n in frontier:
            print("load().frontier.tree[0] =", tbuf[0][0:5], ", s=", s, ", L=",L, ", n.cnt=", n.cnt) if vb else None
            # Read this subtree and graft it under n
            sub = _read_subtree(tbuf, n.cnt, s, L, MAX_C, s==L)
            n.kids = sub.kids  # counts already set; we keep n.cnt
    else:
        root = _read_subtree(tbuf, L2, 0, L, MAX_C)
    print("deserialize_tree().root.cnt,kids,tbuff =", root.cnt, root.kids, tbuf) if vb else None
    return root


def hbits_to_chunks(hbuf, k, Nk, L1, L2, leaves_cnts):
    chunks: List[str] = []
    for j in range(Nk):
      ids = []
      for i in range(L2):
        i = (L2 - i - 1) 
        w = 0 if i < 1 else math.ceil(math.log2(i+1))
        if w == 0:
            ids.append(0)
        else:
            chunk = _rd_bits(hbuf, w)
            if len(chunk) != w:
                raise ValueError(f"hbits underflow at i={i} chnk={chunk},w={w}")
            ids.append(int(chunk, 2)) 
        print("load().i,j,w,id =", i,j,w,ids[-1]) if vb else None
    # optional sanity: leftover bits in HBITS block?
        if len(hbuf[0]) != 0:
          # ignore final 0..7 bit padding if you ever pad HBITS separately
          pass

    # Reconstruct per-leaf row queues same as persist (ids semantics depend on your use)
    # Here we re-create the per-leaf emission order (lexicographic by leaf).
      per_leaf_rows: Dict[str, List[int]] = {leaf: [] for leaf, _ in leaves_cnts}
      rows, pos, cnt = [], len(leaves_cnts)-1, 0
      for idx in reversed(ids):
        cnt = leaves_cnts[pos][1].cnt if cnt <= 1 else cnt - 1
        if idx < k:
            rows.insert(idx, leaves_cnts[pos][0])
        pos -= 1 if cnt<= 1 and pos>0 else 0
      for i, leaf in enumerate(rows):
        per_leaf_rows[leaf].append(i)
      print("load().per_leaf_rows =", per_leaf_rows, ",\n leaves_cnts=", [(l,n.cnt) for l,n in leaves_cnts], ":", len(leaves_cnts), ",\n ids=", ids, "\n rows=", rows) if vb else None

    # Build per-row queues of leaves using the order per_leaf_rows
      queues: List[List[str]] = [[] for _ in range(L1)]
      for leaf, rows in per_leaf_rows.items():
        for r in rows:
            queues[r % L1].append(leaf)

    # Column-major interleave rows (with NR=L1 ⇒ original order)
      remaining = k
      row = 0
      while remaining > 0 and row < len(queues):
        if queues[row]:
            chunks.append(queues[row].pop(0))
            remaining -= 1
        row = (row + 1) #% #k

    return chunks


def rotate_left(bitstr, n):
    n = n % len(bitstr)
    return bitstr[n:] + bitstr[:n]



def get_L(n):
    # klog(k)=n => log(k)=n/k => 2log(k)=log(n) => k=sqrt(n)
    """
    Solve k * log2(k) = n for k using the Lambert W function.

    Parameters
    ----------
    n : float
        The right-hand side of the equation.

    Returns
    -------
    float
        Solution for k (real branch).
    """
    if n <= 0:
        raise ValueError("n must be positive.")

    # Argument for Lambert W
    z = n * np.log(2)

    # Use principal branch of Lambert W
    w = lambertw(z, k=0).real

    # Apply formula: k = (n * ln(2)) / W(n * ln(2))
    k = (n * np.log(2)) / w
    print("get_L().n,k,logk,klogk=", n, k, np.log2(k), k*np.log2(k))
    return ceil(np.log2(k))



def pad_bitstream(bitstream):
    padding = (8 - len(bitstream) % 8) % 8
    return bitstream + '0' * padding


def tokenize_gpt(bits):
    enc = tiktoken.get_encoding("cl100k_base")
    tokens = enc.encode(bits)
    print("tokenize_gpt().tokens =", tokens, ":", len(tokens)) if vb else None
    # Output: [token IDs]
    return tokens


def tokenize(bits):
    tokens = tokenize_gpt(bits)
    return tokens


def get_all_tokens():
    tokens_file = "all_tokens.pkl"
    all_tokens = []
    if os.path.exists(tokens_file):
        with open(tokens_file, "rb") as f:
            all_tokens = pickle.load(f)
    return all_tokens


def write_all_tokens(all_tokens):
    tokens_file = "all_tokens.pkl"
    with open(tokens_file, "wb") as f:
        pickle.dump(all_tokens, f)
    return


def to_basis_tokens(tokens):
    all_tokens = set(get_all_tokens())
    all_tokens.update(tokens)
    sort_tokens = sorted(all_tokens)
    print("to_basis().tokens =", tokens, ", sort_tokens=", sort_tokens) if vb else None
    basis = [sort_tokens.index(t) for t in tokens]
    write_all_tokens(sort_tokens)
    return basis, len(all_tokens)


def from_basis_tokens(basis):
    all_tokens = get_all_tokens()
    tokens = [all_tokens[i] for i in basis]
    return " ".join(tokens)



# ─────────────────────────── persist/load ───────────────────────────
persist_calls = 0

def persist(data: bytes, L: int = None, f: float = 0.25, fn: str = "local_tree.bin", Nk = 2, write_file=True) -> str:
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
    L_init = L
    L1, dL   = math.ceil(N_bits / L) if L > 0 else 0, 0

    # Split into L-bit chunks (pad last chunk with zeros)
    bits = _bytes_to_bits(data)
    if False: #not L * L1 == len(bits):
        print("persist().bits,L,L1,L*L1 =", len(bits), L, L1, L*L1) if vb else None
        for i in range(1,9):
            if len(bits) % (L-i) == 0 or len(bits) % (L+i) == 0:
                L = L-i if len(bits) % (L-i) == 0 else L+i
                L1 = int(len(bits) / L)
                print("persist().adjusted.bits,L, L1, L*L1 =", len(bits), L, L1, L*L1) if vb else None
                break
    print("persist().bits =", bits) if vb else None

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
    s_actual = _max_balanced_prefix(root, L, len(sequence))
    TRUNC = s_actual if s_actual > 0 else 0
    s = s_actual if TRUNC else 0
    print("persist().target,actual,trunc,s", s_target, s_actual, TRUNC, s) if vb else None

    leaves_cnts: List[tuple] = []
    _enumerate_leaves(root, "", 0, L, leaves_cnts)

    for i in range(len(leaves_cnts)):
        _update_tree(root, leaves_cnts[i][0], -leaves_cnts[i][1].cnt)
        leaves_cnts[i][1].cnt = 0
    print("persist().init leaves_cnts=", [(l,n.cnt) for l,n in leaves_cnts], ":", len(leaves_cnts)) if vb else None

    # Build hbits (variable-width by position) from your ids logic.
    # Here we reconstruct a stable ids list: ids[i] = original position of sequence[i] among remaining.
    # If you already have your own ids list, plug it in instead.
    k = int(L1/Nk) #L1 #2**L #len(sequence) #2**L
    seq, sequences = sequence[:], [sequence[i:i+k] for i in range(0,len(sequence), k)]
    hbits_list: List[str] = []
    # Compute max counts for each leaf over all subset
    for sequence in sequences:
      leaves_cnts_i: List[tuple] = [(l,0) for l,_ in leaves_cnts]
      # Create a reproducible order per leaf (lexicographic by leaf, original-order within leaf)
      for idx, ch in enumerate(sequence):
        for i in range(len(leaves_cnts_i)):
            l, c = leaves_cnts_i[i]
            if ch == l:
                leaves_cnts_i[i] = (l, c+1)

      for i in range(len(leaves_cnts_i)):
          if leaves_cnts[i][1].cnt < leaves_cnts_i[i][1]:
              _update_tree(root, leaves_cnts[i][0], leaves_cnts_i[i][1] - leaves_cnts[i][1].cnt)
              leaves_cnts[i][1].cnt = leaves_cnts_i[i][1]

    print("persist().sequences.len =", len(sequences), ", k =", k, ", leaves_cnts =", sum([n.cnt for _,n in leaves_cnts]))

    # Populate hbits
    for sequence in sequences:
      ids, seq = [], sequence[:]
      per_leaf_rows: Dict[str, List[int]] = {leaf: [] for leaf, _ in leaves_cnts}
      for idx, ch in enumerate(sequence):
        per_leaf_rows[ch].append(idx)
      # ids := "stable positions" per leaf, in lexicographic leaf order
      for leaf, n in leaves_cnts:
        for i in range(n.cnt):
            print("persist().id, leaf, seq, per_leaf_rows =", ids, leaf, seq, len(seq), per_leaf_rows) if vb else None
            ids.append(seq.index(leaf) if leaf in seq else len(seq))
            seq.remove(leaf) if leaf in seq else None

      # Variable-width pack: w_i = ceil(log2(i)) for i=1..L1, store id_i truncated to w_i bits (id_1=0)
      print("persist().ids =", ids) if vb else None
      for i, val in enumerate(ids):
        i = (len(ids)-i-1) 
        w = 0 if i < 1 else math.ceil(math.log2(i+1))
        if w > 0:
            # Truncate higher bits if val >= 2^w (to match the reading schedule)
            hbits_list.append(f"{val:0{w}b}")
        print("persist().hbits.id,w,i =", val, w, i) if vb else None

    hbits = "".join(hbits_list)
    HBITS_LEN = len(hbits)

    leaves_expts = list(filter(lambda l: l[1].cnt>1, leaves_cnts))
    max_c = ceil(log2(max([c.cnt for _,c in leaves_expts])+1)) if len(leaves_expts) else 1
    exc_bits = "".join([f"{l}{n.cnt:0{max_c}b}" for l,n in leaves_expts])
    log_exc_bits = "".join([f"{l}{n.cnt:0{max_c}b}" for l,n in leaves_expts])
    L2 = sum(n.cnt for _,n in leaves_cnts)
    print("persist().leaf_expts =", [(l,n.cnt) for l,n in leaves_expts], "\n excpt_bits=", len(log_exc_bits)/8, "\n leaves_cnts=", [(l,n.cnt) for l,n in leaves_cnts], ":", len(leaves_cnts), "\n per_leaf_rows=", per_leaf_rows, "\n L2=", L2) if vb else None

    tree_bits = serialize_tree(root, s, TRUNC, L, L2, max_c)
    #tree_bits = serialize_taper(root, s, TRUNC, L, L2, max_c)
    old_tree_bits_len = len(tree_bits)

    taper_tree = serialize_taper(root, s, TRUNC, L, L2)
    tree_bits = taper_tree
    tree_bits_len = len(tree_bits)
    print("persist().tree_bits =", tree_bits, "\n hbits=", hbits, "\n ebits=", log_exc_bits, "\n max_c=", max_c,"\n tapered =",len(taper_tree)/8) if vb else None

    # Header + payload (note: TRUNC is 1 bit)
    header = (
        f"{L:016b}"
        f"{N_bytes:032b}"
        f"{L1:032b}"
        f"{TRUNC:04b}"
        f"{tree_bits_len:032b}"
        f"{HBITS_LEN:032b}"
        f"{L2:016b}"
        f"{max_c:08b}"
    )
    payload = header + tree_bits + hbits #+ exc_bits 
    if write_file:
        with open(fn, "wb") as f:
            f.write(_bits_to_bytes(payload))

    print("persist().hdr,tree,hbits,expts,tapered,L,L1,f,N,N_new =",len(header)/8,old_tree_bits_len/8,HBITS_LEN/8, len(exc_bits)/8,len(taper_tree)/8, L, L1, F, N_bytes,len(payload)/8)
    print()

    global persist_calls
    if persist_calls < 0:
        persist_calls = persist_calls + 1
        L_new = L #get_L(len(hbits))
        tbits = header + tree_bits + hbits
        #tbits = pad_bitstream(tbits)
        #tbytes = _bits_to_bytes(tbits)
        #print("persist().recursion.tbits =",len(tbits),len(_bits_to_bytes(tbits)))
        fn1 = persist(_bits_to_bytes(hbits), L=L_new, fn=f"local_tree{persist_calls}.bin", Nk=Nk)
    return fn, hbits, tree_bits, L2


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
    TRUNC   = int(_rd_u(buf, 4))
    tree_bits_len = _rd_u(buf, 32)
    HBITS_LEN     = _rd_u(buf, 32)
    L2     = _rd_u(buf, 16)
    EBITS_LEN     = 0 #_rd_u(buf, 32)
    MAX_C     = _rd_u(buf, 8)

    # Tree bits slice (isolated buffer for subtree parsing)
    tree_bits = _rd_bits(buf, tree_bits_len)
    tbuf = [tree_bits]

    root = deserialize_taper(tbuf, TRUNC, L, L2, MAX_C)
    #root = deserialize_tree(tbuf, TRUNC, L, L2, MAX_C)

    # Leaves and counts (lexicographic) for reconstruction
    leaves_cnts: List[tuple] = []
    _enumerate_leaves(root, "", 0, L, leaves_cnts)
    w, n = ceil(log2(L1)), Node()
    n.cnt = 1
    leaves_cnts = [(f"{i:0{w}b}", n) for i in range(L1)]
    print("load().leaves_cnts =", [(l,n.cnt) for l,n in leaves_cnts]) if vb else None
    L2 = sum(n.cnt for _,n in leaves_cnts)

    # Read HBITS and decode variable-width ids
    hbits_bits = _rd_bits(buf, HBITS_LEN)
    print("load().tree_bits =", tree_bits, "\n hbits=", hbits_bits) if vb else None
    L1, Nk = int(N_bytes*8/L), ceil(L1/max(1,L2))
    print("load().nk,L1,L2 =", ceil(L1/max(1,L2)), L1, L2) if vb else None
    k, k2 = int(L1/Nk), int(L2/Nk) #2**L
    print("load().L,L1,L2,N_bytes,k,k2 =",L,L1,L2,N_bytes,k,k2) if vb else None
    hbuf = [hbits_bits]
    chunks = hbits_to_chunks(hbuf, k, Nk, L1, L2, leaves_cnts)

    # Convert to bytes (trim to exact bit length)
    bitstream = "".join(chunks)[: N_bytes * 8]
    print("load().bitstream =", len(bitstream), ", chunks =", len("".join(chunks))) if vb else None
    if not bitstream:
        return b""
    bitstream = pad_bitstream(bitstream)
    return int(bitstream, 2).to_bytes(len(bitstream)//8, "big")


def repersist(L: int = None, f: float = 0.25, fn: str = "local_tree.bin", Nk = 2) -> str:
    raw_bytes = open(fn, "rb").read()
    i = sum([int(n) for n in re.findall(r'\d+', fn)])
    print("repersist().fn =", fn, ", new.fn=", f"local_tree{i+1}.bin")
    fn = persist(raw_bytes, L=L, fn=f"local_tree{i+1}.bin", f=f, Nk=Nk)
    return fn


def get_payload(msg):
    basis, blen = to_basis_tokens(tokenize(msg))
    print("get_payload().basis,blen =", basis, blen) if vb else None
    bblen = ceil(log2(blen))
    fn, hbits, tbits, L2 = persist(_bits_to_bytes("".join([f"{i:0{bblen}b}" for i in basis])), L=L, fn="local_tree.bin", f=f, Nk=Nk)
    print("get_payload().q.size=", len(msg), ", payload.size=", len(hbits) + len(tbits)) if vb else None
    return hbits, tbits, L2


def encode_tokens(tokens):
    return b''.join([t.to_bytes(4, 'big') for t in tokens]).decode("utf-8", "replace")


def is_alpha_numeric(b):
    #return b > 96 and b < 123
    return b > 47 and b < 58 or b > 64 and b < 91 or b > 96 and b < 123


def is_printable(b):
    return b > 31 and b < 127 or b >= 160


def printable_idx(idx):
    print("printable_idx.p =", floor(idx/95)*128 + 32 + (idx % 95), "idx=", idx) if vb else None
    return floor(idx/95)*128 + 32 + (idx % 95)


def token_idx(idx, key=None, key1=None, w=2):
    tokmap = get_wchar_tokens(w=w)
    print("token_idx().idx,len,k,k1,w =", idx, len(tokmap.keys()), prt(key), prt(key1), w) if vb else None
    if key is None:
        if idx >= len(tokmap.keys()):
            key = list(tokmap.keys())[len(tokmap.keys())-1] 
            return key # + token_idx(idx % len(tokmap.keys()), key)
        return list(tokmap.keys())[idx]
    if key1 is None:
        print("token_idx().k.len =", len(tokmap[key].keys()), tokmap[key])
        if idx >= len(list(tokmap[key].keys())):
            return list(tokmap[key].keys())[-1]
        return list(tokmap[key].keys())[idx]
    else:
        #key1 = -1 if not key1 in tokmap[key] else key1
        print("token_idx().map.k.k1 =", len(tokmap[key][key1]), tokmap[key][key1])
        if idx >= len(tokmap[key][key1]):
            return tokmap[key][key1][-1]
        return tokmap[key][key1][idx]


def token_to_idx(token_char, key=None, key1=None, w=2):
    """
    Inverse of token_idx():
    """
    tokmap = get_wchar_tokens(w=w)
    print("token_char_to_idx().token,key,key1,w =", token_char, key, key1, w) if vb else None

    if key is None:
        print("token_char_to_idx().key.len=", len(list(tokmap.keys())))
        return list(tokmap.keys()).index(token_char)
    if key1 is None:
        print("token_char_to_idx().key1.len=", len(list(tokmap[key].keys())))
        return list(tokmap[key].keys()).index(token_char)
    print("token_char_to_idx().len=", len(list(tokmap[key][key1])))
    return tokmap[key][key1].index(token_char)



def encode_str(bit_str):
    # Pad with zeros if needed
    pad = bit_str + "0" * ((8 - len(bit_str) % 8) % 8)

    # Group every 8 bits, convert to bytes
    byte_arr = bytearray(int(pad[i:i+8], 2) for i in range(0, len(pad), 8))
    seen, a, non_print = set(), None, {}
    for b in byte_arr:
        if is_alpha_numeric(b): # or is_printable(b)
            if not a is None:
                seen.add(a + chr(b))
            a = chr(b)
    packed_str, a = "", ""
    for b in byte_arr:
        if is_alpha_numeric(b): # or is_printable(b)
            packed_str += chr(b)
            a = chr(b)
        else:
            if b in non_print.keys():
                packed_str += non_print[b] 
            else:
              for i in range(256):
                if is_alpha_numeric(i) and not a+chr(i) in seen:
                #if is_printable(i) and not a+chr(i) in seen:
                    a = "a" if len(a)==0 else a
                    packed_str += a+chr(i) 
                    non_print[b] = a+chr(i)
                    seen.add(a + chr(i))
                    break
    print("encode_str().packed_str =", packed_str, ":", len(packed_str), ", non_print =", non_print, ":", len(non_print.keys())) if vb else None
    return packed_str, {v:k for k,v in non_print.items()}, 0


def encode_str_offset(bit_str):
    # Pad with zeros if needed
    pad = bit_str + "0" * ((8 - len(bit_str) % 8) % 8)

    # Group every 8 bits, convert to bytes
    byte_arr = bytearray(int(pad[i:i+8], 2) for i in range(0, len(pad), 8))
    packed_str = ""
    offset = 32 #(31-min_b) if min_b < 31 else 0
    remainder = 0
    for b in byte_arr:
        c = printable_idx(b * (1<<ceil(log2(remainder+1))) + remainder) 
        c, remainder = c % (2**8), c // (2**8)
        print("encode_str().b,c,r,logr = ", b, c, remainder, 1<<ceil(log2(remainder+1))) if vb else None
        packed_str += chr(c) 
    packed_str += chr(remainder) if remainder > 0 else ""
    return packed_str, {}, offset


def prt(c):
    return str(c) if c else "None"


def encode_subtoken(bit_str):
    # Pad with zeros if needed
    b = 16
    #pad = bit_str + "0" * ((8 - len(bit_str) % 8) % 8)
    pad = bit_str + "0" * ((b - len(bit_str) % b) % b)

    # Group every 8 bits, convert to bytes
    #byte_arr = bytearray(int(pad[i:i+8], 2) for i in range(0, len(pad), 8))
    packed_str = "".join([enc.decode([int(pad[i:i+16],2)]) for i in range(0,len(pad),16)])
    print("encode_subtoken().packed_str = ", len(packed_str), packed_str, enc.encode(packed_str)) if vb else None
    #c, c1, w = None, None, 3
    #for i,b in enumerate(byte_arr):
        #v = token_idx(b,w=w) if i%w == 0 else token_idx(b, key=c, key1=c1, w=w) 
        #c = v if i%3 == 0 or w<3 else c
        #c1 = v if i%3 == 1 and w==3 else None
        #print("encode_subtoken().b,c,v,c1=",b,prt(c),prt(v),prt(c1)) if vb else None
        #packed_str += v
    return packed_str, {}, None


def decode_subtoken(packed_str, w=2):
    #k, k1, byte_arr = None, None, []
    #for i,c in enumerate(packed_str):
    #    b = token_to_idx(c, w=w, key=k, key1=k1)
    #    print("decode_subtoken().b =", b)
    #    k = c if i % w == 0 or w < 3 else k
    #    k1 = c if i % w == 1 and w == 3 else None
    #    byte_arr.append(b)
    bitstr = ''.join(f"{b:016b}" for b in enc.encode(packed_str))
    #bitstr = ''.join(f"{b:08b}" for b in byte_arr)
    print("decode_subtoken().packed_str,bitstr = ", len(packed_str), packed_str, enc.encode(packed_str), bitstr) if vb else None
    return bitstr



# assume you have: from your_module import tokenize
# and an optional global `vb` for verbose logging

def load_basis_sorted(txt, basis_fn="basis.json", refresh=False):
    """
    Maintains a sorted histogram (most frequent first) of basis strings (single-token strings).
    - Persists a JSON list of {"token": int, "text": str, "count": int} to `basis_fn`.
    - Updates counts based on tokenization of `txt`.
    - Returns a tuple for backward-compatibility:
        basis_txt (space-joined sorted strings),
        basis (sorted list of strings),
        basis_tokens (sorted list of token ids),
        new_txt (space-joined strings added for the first time),
        new_toks (list of token ids added for the first time),
        txts (decoded strings for tokens in `txt`),
        txt_tokens (token ids for `txt`)
    """
    enc = tiktoken.get_encoding("cl100k_base")

    # Tokenize the new input text (single-token handling downstream)
    txt_tokens = tokenize(txt)
    txts = [enc.decode([tok]).strip() for tok in txt_tokens]
    # Filter out empty/whitespace-only decodes
    pairs = [(tok, s) for tok, s in zip(txt_tokens, txts) if s]

    # Load existing histogram
    hist = {}  # token_id -> {"token": int, "text": str, "count": int}
    added_this_run = set()  # track which token ids are *newly* added in this call

    if os.path.exists(basis_fn) and not refresh:
        try:
            with open(basis_fn, "r", encoding="utf-8") as f:
                data = json.load(f)
            # Validate/normalize loaded data
            for item in data:
                tok = int(item["token"])
                txt_str = str(item["text"])
                cnt = int(item.get("count", 0))
                if txt_str:
                    hist[tok] = {"token": tok, "text": txt_str, "count": max(cnt, 0)}
        except Exception:
            # Fallback if file exists but is not JSON (legacy whitespace basis)
            with open(basis_fn, "r", encoding="utf-8", errors="ignore") as f:
                legacy = f.read()
            legacy_tokens = tokenize(legacy)
            for tok in legacy_tokens:
                s = enc.decode([tok]).strip()
                if s:
                    if tok not in hist:
                        hist[tok] = {"token": tok, "text": s, "count": 0}
                    hist[tok]["count"] += 1
    else:
        # refresh -> start from empty histogram
        hist = {}

    # Update histogram with the new text tokens
    for tok, s in pairs:
        if tok not in hist:
            hist[tok] = {"token": tok, "text": s, "count": 0}
            added_this_run.add(tok)
        hist[tok]["count"] += 1

    # Sort by count desc, then by text asc (stable secondary)
    sorted_items = sorted(hist.values(), key=lambda d: (-d["count"], d["text"]))

    # Build outputs in sorted order
    basis = [item["text"] for item in sorted_items]
    basis_tokens = [item["token"] for item in sorted_items]
    basis_txt = " ".join(basis)

    # New tokens/strings added *this* call (not previously in hist)
    new_toks = [tok for tok in basis_tokens if tok in added_this_run]
    new_txt_items = [enc.decode([tok]).strip() for tok in new_toks]
    new_txt_items = [s for s in new_txt_items if s]
    new_txt = (" " + " ".join(new_txt_items)) if new_txt_items else ""

    # Persist updated histogram (robust JSON)
    with open(basis_fn, "w", encoding="utf-8") as f:
        json.dump(sorted_items, f, ensure_ascii=False, indent=2)

    if 'vb' in globals() and vb:
        print("define().basis (top 20) =", basis[:20])

    return basis_txt, basis, basis_tokens, new_txt, new_toks, txts, txt_tokens



def load_basis(txt, basis_fn="basis.txt", refresh=False):
    basis_txt, new_txt = "Sample basis", "" # today? Lets see if its possible to get a basis going on this date or now."
    new_toks, txt_tokens = [], tokenize(txt)
    if os.path.exists(basis_fn):
        with open(basis_fn, "r") as f:
            basis_txt = f.read()
    #basis = basis_txt.split(" ")
    basis_tokens = tokenize(basis_txt)
    basis = [enc.decode([tok]).strip() for tok in basis_tokens]
    print("define().basis =", basis) if vb else None
    txts = [enc.decode([tok]).strip() for tok in txt_tokens]
    for word, tok in zip(txts, txt_tokens): 
        if not word in basis:
            basis_tokens.append(tok)
            new_toks.append(tok)
            new_txt += f" {word.strip()}"
            basis.append(word.strip())
    if len(new_txt) > 0:
        with open(basis_fn, "w") as f:
            f.write(basis_txt + new_txt)
    basis_txt += new_txt
    return basis_txt, basis, basis_tokens, new_txt, new_toks, txts, txt_tokens


def decode_basis_prompt(packed_str="", fn="basis.txt", refresh=False, encode_fn=encode_str_offset, w=2, Nbits=16, Ntok=-1):
    basis_txt, basis, basis_tokens, new_txt, new_toks, txts, txt_tokens = load_basis_sorted("",fn,refresh)
    txt = decode_subtoken(packed_str, w=w)
    txts = [txt[i:i+Nbits] for i in range(0, len(txt), Nbits)][:Ntok]
    print("decode_prompt().txt,txts =", txt, txts, [int(t,2) for t in txts]) 
    msg = " ".join([basis[int(txt,2)] for txt in txts])
    print("decode_prompt().msg =", msg, ", basis_txt =", basis_txt, ", basis =", basis_tokens, len(txt_tokens), len(txt.split(" ")), len(list(zip(txt_tokens, txt.split(" "))))) if vb else None
    return msg


def define_basis_prompt(txt="What is the time now?", fn="basis.txt", refresh=False, encode_fn=encode_str_offset):
    basis_txt, basis, basis_tokens, new_txt, new_toks, txts, txt_tokens = load_basis_sorted(txt,fn,refresh)
    used_toks = 0
    print("define_basis().basis_txt =", basis_txt, ", basis =", basis_tokens, len(txt_tokens), len(txt.split(" ")), len(list(zip(txt_tokens, txt.split(" "))))) if vb else None

    basis_decode = str("basis_decode = [" + enc.decode(basis_tokens) + "]")
    if refresh:
        basis_msg = str("basis = "+" ".join([enc.decode([t]) for t in basis_tokens]))
    else:
        basis_msg =str("Append to basis = "+" ".join([enc.decode([t]) for t in new_toks]))

    tokens = [basis.index(t) for t in txts]
    Nbits = max([ceil(log2(t+1)) for t in tokens])
    txt_bits = "".join([f"{t:0{Nbits}b}" for t in tokens])
    used_toks += len(tokenize(basis_msg))
    specific_toks = len(new_toks)
    print("define().basis_decode =", basis_decode, ",\n\n ---------------\n", basis_msg, ":", len(basis_tokens if refresh else new_toks), "\n---------------\n , tokens =", tokens, ":", len(tokens), ", Nbits=", Nbits, txt_bits, ":", len(txt_bits)) if vb else None
    s, np, offset = encode_fn(txt_bits)
    print("define().s=", s, ":", len(s), ", np=", np, ", Nbits=", Nbits, ", txt=", txt, ":", len(txt)) if vb else None
    msg = str("\n-----------------\nThe encoded strings I will provide are produced by packing bit arrays into bit-strings. The np strings are provided in this map: "+str(np)+" where a string of quoted characters is considered the key and the value is interpreted as a byte. Replace the key/value pairs in the np map, from the encoded string: '"+s+"'.  Do not produce any code. Treat single quotes as end-of string markers. Treat every value as a "+str(Nbits)+" bit tuple lookup the corresponding entries from the basis_decode list.\n\n Execute the resulting query.\n--------------------\n")
    used_toks += len(tokenize(msg))
    specific_toks = len(tokenize(s))
    print("define_basis().specific_toks =", specific_toks, ", txt_toks =", len(tokenize(txt)), ", s=", len(s)) if vb else None 

    print("define_basis().msg =", msg, "\n\n original_toks =", len(txt_tokens), " total_used_toks =", used_toks, " actual_toks =", len(tokenize(txt)), " used_toks =", specific_toks) if vb else None
    if True:
        return s, Nbits, len(txt_tokens), used_toks, specific_toks

    def_resp = ollama.chat(model='llama3', messages=[
        {"role": "user", "content": msg }
    ])
    print("define().resp =", def_resp['message']['content']) if vb else None
    if True:
        return s, Nbits, len(txt_tokens), used_toks, specific_toks


    # ----------------- Done ------------------

    torder, tbasis, tw = get_payload("This is a test")
    qorder, qbasis, qw = get_payload("What is the date today")
    all_tokens = get_all_tokens()
    print("define().tbasis, qbasis =", str(tbasis), len(tbasis), str(qbasis), len(qbasis)) if vb else None
    print("define().all_tokens =", all_tokens) if vb else None

    msg = str("This is the definition of a translation basis set we will be using on future prompts. The basis is a set of all tokens used in the prompts. Each prompt will consist of a basis subset (tree-encoded with a root node of count n, where each node consists of a single left child count and the right child count is inferred as the parent count - left child count and the counter width is the parent count width - ceil(log2(parent-count))) and a packed bitstring of ids defining basis token sort order where the first half use full precision (w bits), half of the remainder use w-1 bits, half of the remainder w-2 bits, etc. Use these, and the basis superset (below) to decode the full prompt: \n" + encode_tokens(all_tokens))

    def_resp = ollama.chat(model='llama3', messages=[
        {"role": "user", "content": msg }
    ])
    print("define().resp =", def_resp['message']['content']) if vb else None

    msg = str("An example encoding is shown below: basis-subset0: \n" + encode_fn(tbasis) + " (encoded value "+str(tbasis)+") \n sort-order0: \n" + encode_fn(torder) + " (encoded value "+str(torder)+") \n w0=" + str(tw) + "\n original-text0: 'This is a test'" + ".\n Answer the following in encoded format (with basis-subset and sort-order keys): basis-subset1: \n" + encode_fn(qbasis) + "\n sort-order1: \n" + encode_fn(qorder) + "\n w=" + str(qw))
    print("define().basis test msg =", msg) if vb else None

    test_resp = ollama.chat(model='llama3', messages=[
        {"role": "user", "content": msg}
    ])

    with open("test_resp.txt", "w") as f:
        f.write(test_resp['message']['content'])
    return test_resp['message']['content'], Nbits, len(txt_tokens), used_toks, specific_toks


def prompt(q):
    tokens = tokenize(q)
    print("prompt().tokens =", tokens) if vb else None
    basis, blen = to_basis_tokens(tokens)
    print("prompt().basis,blen =", basis, blen) if vb else None
    bblen = ceil(log2(blen))
    fn, hbits, tbits = persist("".join([f"{i:0{bblen}b}" for i in basis]), L=L, fn="local_tree.bin", f=f, Nk=Nk)
    payload = hbits + tbits
    print("q.size=", len(q), ", payload.size=", len(payload))

    response = ollama.chat(model='llama3', messages=[
        {"role": "user", "content": str("Here is the payload: " + payload)}
    ])
    print("prompt().resp =", response['message']['content']) if vb else None

    return response['message']['content']


def chat():
    global vb
    vb = True
    txt = ""
    while txt.lower() != "no":
        print("\n\nEnter your prompt: \n")
        inp = input()
        out, _, _, _ = define_basis_prompt(txt=inp)
        print("\n\nContinue? (yes|no) \n")
        txt = input()
    return

def random_word(min_len=2, max_len=10):
    """Generate a random 'word' with letters a-z."""
    length = random.randint(min_len, max_len)
    return ''.join(random.choice(string.ascii_lowercase) for _ in range(length))

def random_sentence(num_words=5):
    """Generate a random sentence of a given number of words."""
    words = [random_word() for _ in range(num_words)]
    sentence = " ".join(words).capitalize() + "."
    return sentence


# ────────────────────────── tiny demo ──────────────────────────

if __name__ == "__main__":
    import os, random
    N = int(sys.argv[sys.argv.index("-N")+1]) if "-N" in sys.argv else 64
    f = float(sys.argv[sys.argv.index("-F")+1]) if "-F" in sys.argv else 0.25
    Nk = float(sys.argv[sys.argv.index("-Nk")+1]) if "-Nk" in sys.argv else 2 
    L = int(sys.argv[sys.argv.index("-L")+1]) if "-L" in sys.argv else None
    if "-R" in sys.argv:
        fn = repersist(L=L, fn=sys.argv[sys.argv.index("-R")+1], f=f, Nk=Nk)
        exit(0)
    TEXT = "".join([random.choice("0123456789 abcdefghijoklmnopqrstuvwxyz") for _ in range(N)]).encode()

    fn = "" #persist(TEXT, L=L, fn="local_tree.bin", f=f, Nk=Nk)
    #out = load(fn)
    if "-C" in sys.argv:
        chat()
        exit(0)

    #get_wchar_tokens(3)
    #if True:
    #   exit(0)
    #out, _ = define_basis_prompt()
    s = "what time of day is it?"
    #vb = True
    packed,Nbits,ntok,_,_ = define_basis_prompt(s, encode_fn=encode_subtoken)
    #vb = True
    out = decode_basis_prompt(packed, w=3, Nbits=Nbits, Ntok=ntok)
    print("s =", s, ":", len(tokenize(s)), ", packed =", packed, ":", len(tokenize(packed)), ", out =", out)
    if True:
        exit(0)

    # Example: generate 5 sentences with different lengths
    for i in range(1):
      for length in [3]: #, 5, 7, 10, 12]: #, 5, 7, 10, 12]:
        s = random_sentence(length)
        out, toks, total, specific = define_basis_prompt(s,encode_fn=encode_subtoken)
        #print("in.len=",s, "out.len=", out, "in.toks=", toks,"out.total=", total, "out.specific=",specific)
        print("in.len=",len(s), "out.len=", len(out), "in.toks=", toks,"out.total=", total, "out.specific=",specific)
    #out = prompt("what time of day is it?")

    #print("saved", fn, "(size:", os.path.getsize(fn), "bytes)")
    #print("round-trip ok:", out == TEXT)
    #print("original    :", TEXT)
    #print("reconstructed:", out)

