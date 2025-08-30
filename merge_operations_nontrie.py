"""
merge_operations_nontrie.py
Header: **16 bits only** – the root counter (`root_cnt = L`)
Everything else (L, cw at each level, etc.) is derived at decode time.
Round-trips perfectly while keeping the header to two bytes.
"""
import math, os, random, sys
from typing import Dict

try:  # nicer console on Windows
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

F = float(sys.argv[sys.argv.index('-F')+1]) if '-F' in sys.argv else 0.25

class Node:
    def __init__(self):
        self.cnt: int = 0
        self.kids: Dict[str, "Node"] = {}   # keys ‘0’ or ‘1’


# ───────── bit helpers ─────────
def _width(n: int) -> int:
    return max(1, math.ceil(math.log2(n)) if n>0 else 0)


def _bits_to_bytes(bits: str) -> bytes:
    pad = (-len(bits)) % 8
    return int(bits + "0" * pad, 2).to_bytes((len(bits) + pad) // 8, "big")


def _bytes_to_bits(b: bytes) -> str:
    return "".join(f"{x:08b}" for x in b)


def _rd(buf: list[str], n: int) -> int:
    seg, buf[0] = buf[0][:n], buf[0][n:]
    return int(seg or "0", 2)


# ───────── build full-depth tree ─────────
def build_tree(text: bytes) -> Node:
    N_bits = max(1, len(text) * 8)           # original bit-count
    L = math.ceil(F*math.sqrt(N_bits))         # side length = tree depth
    L1 = math.ceil(N_bits/L)
    bitstream = "".join(f"{b:08b}" for b in text).ljust(L * L1, "0")
    print("L,L1 =", L, L1)

    root = Node()
    for r in range(L1):                       # L chunks, each L bits
        n = root; n.cnt += 1
        for bit in bitstream[r * L:(r + 1) * L]:
            n = n.kids.setdefault(bit, Node())
            n.cnt += 1

    root._L = L
    root._N = N_bits
    return root


# ───────── writer ─────────
def _write(node: Node, parent: int, depth: int, L: int, out: list[str], p=""):
    if depth >= L:
        return
    left_cnt = node.kids.get('0', Node()).cnt
    print(f"write path='{p or 'root':<11}' depth={depth} parent={parent:<3} left={left_cnt}, w_c= {_width(parent)}, L={L}")
    #out.append(f"{left_cnt:0{_width(parent)}b}")
    out.append(f"{left_cnt:01b}")

    if left_cnt and depth + 1 < L:
        _write(node.kids['0'], left_cnt, depth + 1, L, out, p + "0")
    right_cnt = parent - left_cnt
    if right_cnt and depth + 1 < L:
        _write(node.kids['1'], right_cnt, depth + 1, L, out, p + "1")


def persist(root: Node, fn: str = "local_tree.bin") -> str:
    # 16-bit header: root_cnt (= L), fits while L < 65536
    #bits = [f"{root._L:016b}"]
    bits = [f"{root._L:01b}"]
    _write(root, root.cnt, 0, root._L, bits)
    open(fn, "wb").write(_bits_to_bytes("".join(bits)))
    return fn


# ───────── reader ─────────
def _read(buf: list[str], parent: int, depth: int, L: int) -> Node:
    node = Node()
    if depth >= L:
        return node
    left_cnt = _rd(buf, _width(parent))
    #print("_read() left_cnt=", left_cnt)
    if left_cnt and depth + 1 < L:
        node.kids['0'] = _read(buf, left_cnt, depth + 1, L)
        node.kids['0'].cnt = left_cnt
    right_cnt = parent - left_cnt
    if right_cnt and depth + 1 < L:
        node.kids['1'] = _read(buf, right_cnt, depth + 1, L)
        node.kids['1'].cnt = right_cnt
    node.cnt = parent
    return node


def load(fn: str, text_len: int) -> bytes:
    buf = [_bytes_to_bits(open(fn, "rb").read())]
    L = _rd(buf, 16)                   # root counter
    root = _read(buf, L, 0, L)

    # number of original bits is ≤ L² and a multiple of 8 for our demo
    N_bits = text_len * 8
    chunks = []

    def dfs(n: Node, pre: str, d: int):
        if d == L:
            chunks.extend([pre] * n.cnt)
            return
        if '0' in n.kids: dfs(n.kids['0'], pre + '0', d + 1)
        if '1' in n.kids: dfs(n.kids['1'], pre + '1', d + 1)

    dfs(root, "", 0)
    bitstream = "".join(chunks)[:N_bits]
    return int(bitstream, 2).to_bytes(len(bitstream) // 8, "big")


# ───────── demo ─────────
if __name__ == "__main__":
    TEXT = b"Hello, world!"
    N=20
    L = math.ceil(F*math.sqrt(N*8))
    L1, p = math.ceil(N*8/L), math.ceil(math.log2(L))
    TEXT = "".join([random.choice("0123456789 abcdefghijoklmnopqrstuvwxyz") for _ in range(N)])
    TEXT = TEXT.encode()
    t = build_tree(TEXT)
    fname = persist(t)
    sz = os.path.getsize(fname) if L1 < 2**L else 0
    print("saved", fname, "(size:", sz, "bytes)", p, (sz+L1*p/8)/N)
    #print("round-trip ok:", load(fname, len(TEXT)) == TEXT)

