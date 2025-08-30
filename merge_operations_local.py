# merge_operations_local.py
import math, random, sys
from typing import Union

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


# ──────────────────────────  Basic node  ──────────────────────────
class LocalNode:
    def __init__(self, ident: str = ""):
        self.identifier: str = ident     # bit-string (RAM-only)
        self.counter: int = 0
        self.children: dict[str, "LocalNode"] = {}


# ───────────────  Trie insertion (unchanged)  ───────────────
def _px(a: str, b: str) -> int:
    i = 0
    while i < len(a) and i < len(b) and a[i] == b[i]:
        i += 1
    return i


def local_write(node: LocalNode, bits: str) -> None:
    node.counter += 1
    best, key = 0, None
    for cid in node.children:
        px = _px(cid, bits)
        if px > best:
            best, key = px, cid

    if best == 0:
        leaf = LocalNode(bits); leaf.counter = 1
        node.children[bits] = leaf
        return

    s_rest, c_rest = bits[best:], key[best:]
    child = node.children[key]

    if s_rest == c_rest == "":
        child.counter += 1
    elif s_rest == "":
        mid = LocalNode(key[:best]); mid.counter = child.counter + 1
        child.identifier = c_rest
        mid.children[c_rest] = child
        node.children[mid.identifier] = mid; del node.children[key]
    elif c_rest == "":
        local_write(child, s_rest)
    else:
        mid = LocalNode(key[:best]); mid.counter = child.counter + 1
        child.identifier = c_rest
        mid.children[c_rest] = child
        leaf = LocalNode(s_rest); leaf.counter = 1
        mid.children[s_rest] = leaf
        node.children[mid.identifier] = mid; del node.children[key]


# ───────────────  Helpers  ───────────────
def _cnt_w(parent_cnt: int) -> int:
    return max(1, math.ceil(math.log2(parent_cnt + 1)))


def _bits_to_bytes(bits: str) -> bytes:
    pad = (-len(bits)) % 8
    return int(bits + "0" * pad, 2).to_bytes((len(bits) + pad) // 8, "big")


def _bytes_to_bits(data: bytes) -> str:
    return "".join(f"{b:08b}" for b in data)


def _read_bits(cur: list[str], n: int) -> int:
    seg, cur[0] = cur[0][:n], cur[0][n:]
    return int(seg or "0", 2)            # empty → 0


# ───────────────  Variable-length identifier  ───────────────
def _enc_id(id_bits: str, out: list[str]) -> None:
    for i, b in enumerate(id_bits):
        out.append(b)
        out.append("0" if i == len(id_bits) - 1 else "1")   # 0 = last


def _dec_id(cur: list[str]) -> str:
    bits = []
    while True:
        bits.append(str(_read_bits(cur, 1)))
        cont = _read_bits(cur, 1)
        if cont == 0:
            break
    return "".join(bits)


# ───────────────  Recursive write / read  ───────────────
def _write(node: LocalNode, parent_cnt: int, out: list[str]):
    kids = list(node.children.items())          # insertion order
    left  = kids[0][1] if kids else None
    right = kids[1][1] if len(kids) == 2 else None

    # left identifier
    _enc_id(left.identifier, out)

    # has_right flag & optional left counter
    if right:
        out.append("1")
        out.append(f"{left.counter:0{_cnt_w(parent_cnt)}b}")
        _enc_id(right.identifier, out)
    else:
        out.append("0")     # no right child, no counter, no right id

    # recurse (skip leaves with counter == 1)
    if left and left.counter > 1:
        _write(left, node.counter, out)
    if right and right.counter > 1:
        _write(right, node.counter, out)


def _read_node(cur: list[str], parent_cnt: int) -> LocalNode:
    node = LocalNode("")

    left_bits = _dec_id(cur)
    has_right = _read_bits(cur, 1)

    left_cnt = (_read_bits(cur, _cnt_w(parent_cnt))
                if has_right else parent_cnt)

    right_bits = _dec_id(cur) if has_right else ""

    if left_bits:
        left = LocalNode(left_bits); left.counter = left_cnt
        node.children[left.identifier] = left
        if left_cnt > 1:
            _fill(left, cur)

    if right_bits:
        right_cnt = parent_cnt - left_cnt
        right = LocalNode(right_bits); right.counter = right_cnt
        node.children[right.identifier] = right
        if right_cnt > 1:
            _fill(right, cur)

    return node


def _fill(node: LocalNode, cur: list[str]):
    if not cur[0] or cur[0] == "0":          # next bit is a 'has_right' flag of 0
        return                               # or padding → leaf
    child = _read_node(cur, node.counter)
    node.children = child.children


# ───────────────  Public API  ───────────────
def build_local_tree(text: str) -> LocalNode:
    root = LocalNode("")
    N = len(text) * 8
    p = max(1, math.ceil(math.log2(N) / 2))          # precision
    chunk_bits  = math.ceil(N / p) if N else 8
    chunk_bytes = math.ceil(chunk_bits / 8)
    for i in range(0, len(text), chunk_bytes):
        chunk = text[i:i + chunk_bytes]
        local_write(root, "".join(f"{ord(c):08b}" for c in chunk))
    root._p = p
    return root


def persist_local_tree(root: LocalNode, filename="local_tree.bin") -> str:
    p = root._p
    root_w = _cnt_w(root.counter)
    bits = [
        f"{p:016b}",                  # precision
        f"{root_w:08b}",              # root counter width
        f"{root.counter:0{root_w}b}", # root counter
    ]
    _write(root, root.counter, bits)
    open(filename, "wb").write(_bits_to_bytes("".join(bits)))
    return filename


def read_from_binary_file(filename: str) -> str:
    cur = [_bytes_to_bits(open(filename, "rb").read())]
    _ = _read_bits(cur, 16)            # p (unused for decode)
    root_w = _read_bits(cur, 8)
    root_cnt = _read_bits(cur, root_w)

    root = LocalNode(""); root.counter = root_cnt
    if root_cnt > 1:
        _fill(root, cur)

    leaves = []
    def dfs(nd: LocalNode, pre: str):
        if not nd.children:
            leaves.extend([pre] * nd.counter)
        else:
            for bits, ch in nd.children.items():
                dfs(ch, pre + bits)
    dfs(root, "")

    bitstream = "".join(leaves)
    pad = (-len(bitstream)) % 8
    return int(bitstream + "0" * pad, 2).to_bytes((len(bitstream) + pad) // 8,
                                                 "big").decode("utf-8")


# ───────────────  Demo  ───────────────
if __name__ == "__main__":
    N = 10000
    txt = "".join([random.choice("0123456789") for _ in range(N)]) #"Hello, world!"
    tree = build_local_tree(txt)
    fname = persist_local_tree(tree)
    print("txt =", len(txt))
    print("saved", fname, "(size:", len(open(fname, "rb").read()), "bytes)")
    print("round-trip ok:", read_from_binary_file(fname) == txt)

