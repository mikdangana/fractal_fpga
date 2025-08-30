import math
import numpy as np
import glob, os, sys
import random
import matplotlib.pyplot as plt
import pickle
from collections import deque
from concurrent.futures import ThreadPoolExecutor, as_completed
from functools import lru_cache
from time import time
from pathlib import Path
from time import sleep
# ── ADD *once*, near the other imports ─────────────────────────────
import struct, itertools
from typing import Union
# ───────────────────────────────────────────────────────────────────
sys.stdout.reconfigure(encoding="utf-8", errors="replace")


visited = {}
debug = False
batch_mem = 0
GLOBAL_NODES = []
GLOBAL_OFFSET = 0
CACHE_SIZE = 8*2**29/(2**20) # wc => 500Mb on-chip integrated memory * 8 bytes
WC=2 #2.88
CACHE_DEPTH = math.log2(CACHE_SIZE/WC) # wc => 500Mb on-chip integrated memory
COMPUTABLES_DEPTH = 35-20 # 2**35 sparse subtree
global_recs = []
global_nmap = {}


# merge_operations.py  (add near the top, after the MergeNode definition)

# ------------------------------------------------------------------
# Map every MergeNode field onto a native NumPy dtype
# Adjust the names & dtypes if your class differs.
# ------------------------------------------------------------------
NODE_DTYPE = np.dtype([
    ("id",       np.uint32),    # ← MergeNode.id            (32-bit int)
    ("identifier", np.uint64),    # ← MergeNode.identifier  (32-bit int)
    ("left",      np.uint64),    # ← MergeNode.left_child    (identifier)
    ("leftid",   np.uint64),    # ← MergeNode.left_val    (index)
    ("right",     np.uint64),    # ← MergeNode.right_child   (identifier)
    ("rightid",  np.uint64),    # ← MergeNode.right_val   (index)
    ("path",     np.uint64),    # ← MergeNode.path         (optional)
    ("path1",     np.uint64),    # ← MergeNode.path         (optional)
    ("path2",     np.uint64),    # ← MergeNode.path         (optional)
    ("count",     np.uint64),    # ← MergeNode.count_or_sum  (64-bit)
    ("depth",     np.uint16),    # ← MergeNode.depth         (optional)
    # Add/remove lines to match the exact attributes you keep
])

# size check (optional)
assert NODE_DTYPE.itemsize == 4 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 2, "dtype size mismatch"

NODE_FILE=sys.argv[sys.argv.index("-f")+1] if "-f" in sys.argv else "global_nodes.dat"
NODE_FILE = str(Path(NODE_FILE))  # ensure it’s a string path, not Path object
beff_trace = []


def pad_to_same_length(trace_dict):
    """
    -> 2-D NumPy array shape = (len(P_LIST), max_len)
       with NaNs where a precision produced fewer batches.
    """
    max_len = max(len(v) for v in trace_dict.values())
    mat = np.full((len(trace_dict), max_len), np.nan, dtype=float)
    for row, (p_init, trace) in enumerate(trace_dict.items()):
        mat[row, :len(trace)] = trace
    return mat


def plot_beff_traces(traces, P_LIST  = [4, 8, 16]): #, 32, 64, 128, 256]):
    mat      = pad_to_same_length(traces)     # shape [len(P), max_batches]
    batches  = np.arange(mat.shape[1]) + 1    # x-axis = batch index

    plt.figure(figsize=(10, 6))
    for row, p_init in enumerate(P_LIST):
        plt.plot(
            batches,
            mat[row],
            marker="o",
            label=f"p = {p_init} bits"
        )

    plt.xlabel("Batch number")
    plt.ylabel("Bandwidth efficiency (b_eff)")
    plt.title("b_eff evolution over successive 512-node batches")
    plt.grid(True, ls="--", lw=0.4)
    plt.legend()
    plt.tight_layout()
    plt.savefig("b_eff_per_batch.png", dpi=300)
    plt.show()



def npint(bitstr, is64=True):
        if not bitstr:
            return np.uint64(2**64-1) if is64 else np.uint32(2**32-1) 
        val = int('1'+bitstr, 2)
        if val >= (2**63 if is64 else 2**31):  # handle two's complement for negative values
            val -= (2**64 if is64 else 2**32)
        print("npint.val,bitstr,len(bitstr),is64 = ", val, math.log(val,2), bitstr, len(bitstr), is64) if debug else None
        res = np.uint64(val) if is64 else np.uint32(val)
        return res


def flush_global_nodes_to_file():
    """Convert GLOBAL_NODES to a structured NumPy array and memory-map it."""
    global GLOBAL_NODES, GLOBAL_OFFSET, global_recs, global_nmap

    if not GLOBAL_NODES:
        return

    def to_rec(node):
        l, r = node.get_child(0), node.get_child(1)
        print("flush.id,path = ", node.identifier, node.path) if debug else None
        rec = (np.uint32(node.node_id), npint(node.identifier), l[0],l[1],r[0],r[1], npint(node.path[0:63]), npint(node.path[63:126]), npint(node.path[126:]), np.uint64(node.counter), np.uint16(node.depth))
        return rec
    # Build structured array from objects
    oldarr = []
    if os.path.exists(NODE_FILE):
        oldarr = np.memmap(NODE_FILE, dtype=NODE_DTYPE, mode='r')
    arr = np.empty(len(oldarr)+len(GLOBAL_NODES), dtype=NODE_DTYPE)
    for i, node in enumerate(oldarr):
        arr[i] =to_rec(global_nmap[i]) if i in global_nmap else tuple(oldarr[i])
    for i, node in enumerate(GLOBAL_NODES):
        arr[i+len(oldarr)] = to_rec(node)

    del oldarr
    global_recs = []
    global_nmap.clear()
    # Write to file (overwrite mode)
    with open(NODE_FILE, "wb") as f:
        f.write(arr.tobytes())
        f.close()

    GLOBAL_OFFSET += len(GLOBAL_NODES)
    GLOBAL_NODES.clear()  # free memory


def get_global_node_from_mmap(idx: int):
    if not os.path.exists(NODE_FILE):
        return None

    """Access one node from file without loading the whole array."""
    mmap = np.memmap(
        NODE_FILE,
        dtype=NODE_DTYPE,
        mode="r",
        offset=idx * NODE_DTYPE.itemsize,
        shape=(1,)
    )
    record = mmap[0].copy()
    mmap._mmap.close()
    del mmap

    mx32, mx64 = 2**32-1, 2**64-1
    def gets(b):
        return bin(b)[3:] if b!=mx32 and b!=mx64 else ""

    # Rehydrate a MergeNode (assuming class name is still MergeNode)
    node = MergeNode(int(record["id"]), gets(record["identifier"]), int(record["depth"]), gets(record["path"])+gets(record["path1"])+gets(record["path2"]))
    node.counter = int(record["count"])
    if record["left"] != mx64 or record["right"] != mx64:
        node.children[gets(record["left"])] = int(record["leftid"]) if record["leftid"] != mx64 else None
        if record["right"] != mx64:
            node.children[gets(record["right"])] = int(record["rightid"]) if record["rightid"] != mx64 else None
    del record
    global global_nmap
    global_nmap[idx] = node
    return node


def get_global_node(idx, global_nodes=None):
    global global_nmap, GLOBAL_NODES
    #print("get_global_node.nmap,contains(idx),global_off,idx,global_nodes.len = ", global_nmap, idx in global_nmap, GLOBAL_OFFSET, idx, len(GLOBAL_NODES))
    if idx in global_nmap:
        return global_nmap[idx]
    node = GLOBAL_NODES[idx-GLOBAL_OFFSET] if idx-GLOBAL_OFFSET>=0 and idx-GLOBAL_OFFSET < len(GLOBAL_NODES) else get_global_node_from_mmap(idx)
    #print("get_global_node.idx, node = ", idx, node.node_id, node.children)
    return node 


def get_visited(idx):
    global visited
    ncount = get_global_node(idx).counter
    return visited[idx] if idx in visited and ncount>=visited[idx] else 0


def get_update(idx):
    visit = get_visited(idx)
    return get_global_node(idx).counter - visit


def get_null_child_count(nd, cid, global_nodes):
    #def get_global_node(idx, global_nodes=GLOBAL_NODES):
    #    return global_nodes[idx] if idx < len(global_nodes) and global_nodes[idx] is not None else get_global_node_from_mmap(idx)
    ks = list(filter(lambda k: k!=cid, nd.children.keys()))
    if len(ks) == 0:
        return nd.counter
    v0 = nd.children[ks[0]]
    cnt = lambda: get_global_node(v0, global_nodes).counter
    c0 = int(nd.counter/len(nd.children.items())) if v0 is None else cnt()
    print("get_null_.nd,cid,v0,c0,n.cnt,cnt = ", ((nd.children,nd.node_id,nd.counter), cid, v0, c0, nd.counter, max(0, nd.counter-c0))) if debug else None
    return max(0, nd.counter - c0)


def timed(fn, label):
    start = time()
    res = fn()
    print(f"timed {label} = {(time()-start)*1000} ms", flush=True)
    return res


################################################################
# local partial-match tree classes + function
################################################################
class LocalNode:
    def __init__(self, identifier=""):
        self.identifier = identifier
        self.counter = 0
        self.children = {}

def local_common_prefix_len(a,b):
        i=0
        limit=min(len(a), len(b))
        while i<limit and a[i]==b[i]:
            i+=1
        return i

def local_write(node, bits):
        # standard partial-match logic
        best_px=0
        best_cid=None
        node.counter += 1
        for cid, cnd in node.children.items():
            px= local_common_prefix_len(cid, bits)
            if px> best_px:
                best_px=px
                best_cid=cid

        if best_px==0:
            # no match => create child
            nn= LocalNode(bits)
            nn.counter=1
            node.children[bits]= nn
        else:
            leftover_s= bits[best_px:]
            leftover_c= best_cid[best_px:]
            cnode= node.children[best_cid]

            if leftover_s=="" and leftover_c=="":
                cnode.counter += 1
            elif leftover_s=="" and leftover_c!="":
                prefix= best_cid[:best_px]
                new_parent= LocalNode(prefix)
                cnode.counter+=1
                new_parent.counter=cnode.counter
                del node.children[best_cid]
                cnode.identifier= leftover_c
                new_parent.children[leftover_c]= cnode
                node.children[prefix]= new_parent
            elif leftover_s!="" and leftover_c=="":
                local_write(cnode, leftover_s)
            else:
                prefix= best_cid[:best_px]
                new_parent= LocalNode(prefix)
                new_parent.counter=cnode.counter+1
                del node.children[best_cid]
                cnode.identifier= leftover_c
                new_parent.children[leftover_c]= cnode
                brand= LocalNode(leftover_s)
                brand.counter=1
                new_parent.children[leftover_s]= brand
                node.children[prefix]= new_parent

# ── REPLACE the old build_local_tree() with this version ───────────
def build_local_tree(data: Union[str, list[int]]):
    """
    If *data* is a string:
        • N  = len(data) * 8  (bits in the text)
        • p  = ceil(log2(N) / 2)
        • chunk_size = ceil(N / p)  → number of *bytes* per chunk
        • feed every chunk into local_write() as an 8-bit-per-char bit-string

    If *data* is a list/iterable of integers (legacy behaviour):
        • fall back to the original logic.
    """
    root = LocalNode("")            # same local-tree root

    # ── text mode ──────────────────────────────────────────────────
    if isinstance(data, str):
        text           = data
        N              = len(text) * 8                         # total bits
        p_local        = max(1, math.ceil(math.log2(N) / 2))   # precision
        chunk_len_bits = math.ceil(N / p_local)                # bits / chunk
        chunk_len_chr  = math.ceil(chunk_len_bits / 8)         # bytes / chunk

        for i in range(0, len(text), chunk_len_chr):
            chunk      = text[i : i + chunk_len_chr]           # substring
            chunk_bits = ''.join(f"{ord(c):08b}" for c in chunk)
            local_write(root, chunk_bits)

        # expose the precision we just computed so other code can
        # reference it (persist_local_tree needs it)
        root._p = p_local
        return root

    # ── legacy integer mode (unchanged) ────────────────────────────
    else:
        # assume iterable/sequence of ints
        for val in data:
            bs = f"{val:0{p}b}"            # *global* p from caller
            local_write(root, bs)
        root._p = p                         # keep a copy for persistence
        return root
# ───────────────────────────────────────────────────────────────────


# ── NEW helper functions used by the serializer / deserializer ────
def _bits_to_bytes(bitstr: str) -> bytes:
    """Pad to full bytes and return a big-endian byte string."""
    pad = (-len(bitstr)) % 8
    bitstr += "0" * pad
    return int(bitstr, 2).to_bytes(len(bitstr) // 8, "big")


def _bytes_to_bits(data: bytes, total_bits: int) -> str:
    """Convert *data* back to a bit-string of exactly *total_bits* bits."""
    return f"{int.from_bytes(data, 'big'):0{total_bits}b}"

def _write_node(node, parent_cnt, p, out_bits):
    """Recursive preorder serialiser."""
    # 1️⃣  counter  – width = ceil(log2(parent_cnt + 1))
    cnt_w  = max(1, math.ceil(math.log2(parent_cnt + 1)))
    out_bits.append(f"{node.counter:0{cnt_w}b}")

    # 2️⃣  identifier length + bits
    len_w  = max(1, math.ceil(math.log2(p + 1)))
    id_len = len(node.identifier)
    out_bits.append(f"{id_len:0{len_w}b}")
    out_bits.append(node.identifier)

    # 3️⃣  children
    children = sorted(node.children.items())           # deterministic order
    left  = children[0][1] if len(children) > 0 else None
    right = children[1][1] if len(children) > 1 else None

    out_bits.append("1" if left else "0")
    if left:
        _write_node(left,  node.counter, p, out_bits)

    out_bits.append("1" if right else "0")
    if right:
        _write_node(right, node.counter, p, out_bits)

def _read_node(cursor, parent_cnt, p):
    """Recursive preorder deserialiser (mirrors _write_node)."""
    cnt_w  = max(1, math.ceil(math.log2(parent_cnt + 1)))
    counter = _read_bits(cursor, cnt_w)

    len_w   = max(1, math.ceil(math.log2(p + 1)))
    id_len  = _read_bits(cursor, len_w)
    identifier_bits, cursor[0] = cursor[0][:id_len], cursor[0][id_len:]

    node = LocalNode(identifier_bits)
    node.counter = counter

    # left
    has_left = _read_bits(cursor, 1)
    if has_left:
        left_child = _read_node(cursor, node.counter, p)
        node.children[left_child.identifier] = left_child

    # right
    has_right = _read_bits(cursor, 1)
    if has_right:
        right_child = _read_node(cursor, node.counter, p)
        node.children[right_child.identifier] = right_child

    return node


def _read_bits(cursor, n):
    """Pop *n* bits from the front of cursor[0] and return as int."""
    bits, cursor[0] = cursor[0][:n], cursor[0][n:]
    return int(bits, 2)


def _read_node(cursor, parent_cnt, p):
    """Recursive deserialiser – mirrors _write_node() exactly."""
    cnt_w  = max(1, math.ceil(math.log2(max(1, parent_cnt))))
    counter = _read_bits(cursor, cnt_w)

    len_w   = math.ceil(math.log2(p))
    id_len  = _read_bits(cursor, len_w)
    identifier_bits = cursor[0][:id_len]
    cursor[0] = cursor[0][id_len:]

    node = LocalNode(identifier_bits)
    node.counter = counter

    # left
    has_left = _read_bits(cursor, 1)
    if has_left:
        left_child = _read_node(cursor, node.counter, p)
        node.children[left_child.identifier] = left_child

    # right
    has_right = _read_bits(cursor, 1)
    if has_right:
        right_child = _read_node(cursor, node.counter, p)
        node.children[right_child.identifier] = right_child

    return node
# ───────────────────────────────────────────────────────────────────

# ── persist_local_tree ────────────────────────────────────────────
def persist_local_tree(local_root: "LocalNode",
                       filename = None) -> str:
    if filename is None:
        filename = "local_tree.bin"

    p           = getattr(local_root, "_p", 1)
    root_cnt_w  = max(1, math.ceil(math.log2(local_root.counter + 1)))

    bits_out = [f"{p:016b}", f"{root_cnt_w:08b}"]  # header: p (16) + root_cnt_w (8)

    _write_node(local_root, local_root.counter, p, bits_out)

    with open(filename, "wb") as f:
        f.write(_bits_to_bytes("".join(bits_out)))
    return filename



# ------------------------------------------------------------------
# 2) DESERIALISER  – read_from_binary_file()
# ------------------------------------------------------------------
def read_from_binary_file(filename: str) -> str:
    """
    Rebuild the local tree from *filename* and return the original text.
    Also prints the text for convenience.
    """
    with open(filename, "rb") as fh:
        raw = fh.read()

    # ── read_from_binary_file (header part only) ──────────────────────
    bitstr = "".join(f"{b:08b}" for b in raw)
    cursor = [bitstr]

    p           = _read_bits(cursor, 16)
    root_cnt_w  = _read_bits(cursor, 8)
    dummy_parent_cnt = (1 << root_cnt_w) - 1     # ensures cnt_w == root_cnt_w

    local_root = _read_node(cursor,
                        parent_cnt=dummy_parent_cnt,
                        p=p)

    # ------------------------------------------------------------------
    # continue inside read_from_binary_file(), right after local_root is built
    # ------------------------------------------------------------------

    # ─── gather complete bit-chunks in left-to-right order ─────────
    chunks: list[str] = []

    def dfs(node, prefix: str):
        """Depth-first traversal that accumulates path bits."""
        current = prefix + node.identifier          # path so far
        if not node.children:                       # leaf → full chunk
            if current:                             # skip true empties
                chunks.extend([current] * node.counter)
        else:                                       # recurse on children
            for _, child in sorted(node.children.items()):
                dfs(child, current)

    dfs(local_root, "")

    def bits_to_bytes(bs: str) -> bytes:
        # Ensure length multiple of 8
        if not bs:
            return b""
        pad = (-len(bs)) % 8
        return int(bs + "0" * pad, 2).to_bytes((len(bs) + pad) // 8, "big")

    # Join bytes and decode safely
    byte_data = b"".join(bits_to_bytes(b) for b in chunks)
    try:
        text = byte_data.decode("utf-8")  # strict UTF-8 decode
    except UnicodeDecodeError:
        # Fallback: ISO-8859-1 for binary-safe mapping (no errors)
        text = byte_data.decode("latin-1")


    print(text)
    return text
    # ------------------------------------------------------------------



# Global partial-match node structure
class MergeNode:
        __slots__ = ['node_id','identifier','counter','children','depth','path']
        def __init__(self, node_id, identifier="", depth=0, path=""):
            self.node_id = node_id
            self.identifier = identifier
            self.counter = 0
            self.children = {}
            self.path = path
            self.depth = depth

        def get_child(self, i):
            ks, vs = list(self.children.keys()), list(self.children.values())
            mx = 2**64-1
            child = (npint(ks[i]) if len(ks[i]) else mx, mx if i>=len(vs) or vs[i] is None else vs[i]) if len(ks)>i else (mx,mx)
            print("get_child.ks,vs,child = ", ks, vs, child) if debug else None
            return (np.uint64(child[0]), np.uint64(child[1]))

        def clone(self):
            cp = MergeNode(self.node_id, self.identifier, self.depth, self.path)
            cp.counter = self.counter
            cp.children = self.children.copy()
            return cp


def print_merge_tree_dfs(idx, global_nodes, identifier="", prefix="",parent="0",
                         nodes=None):
    node = get_global_node(idx, global_nodes)
    nodes.append(idx) if nodes is not None else None
    cnt = 1 if identifier else 0
    child_keys= sorted(node.children.items(), reverse=False) if node and node.children else []
    print(f"{prefix}[{idx}] id='{identifier}' c={node.counter} d={node.depth} children={child_keys} val={int(parent+identifier,2)}") if debug else None
    for cid, c_idx in child_keys:
        if c_idx is None:
            c0 = get_null_child_count(node, cid, global_nodes)
            print(f"  {prefix}[{c_idx}] id='{cid}' c={c0} d={node.depth+1} children=None val={int(parent+identifier+cid,2)}") if debug else None
        elif len(get_global_node(c_idx, global_nodes).children.items()) == 0:
            # These nodes can be compressed out of the histogram, ignore in cnt
            c0 = get_global_node(c_idx, global_nodes).counter
            print(f"  {prefix}[{c_idx}] id='{cid}' c={c0} d={node.depth+1} children=None val={int(parent+identifier+cid,2)}") if debug else None
        else:
            cnt += print_merge_tree_dfs(c_idx, global_nodes, cid, prefix+"  ", parent+identifier, nodes=nodes)
    return cnt


def get_beff(call_log, n, p):
    global CACHE_SIZE, WC
    sum_read = 0 #call_log["read.sum"]
    sum_write = call_log["counter.sum"] # TODO: Key Feature: cached counters
    sum_write += call_log["id.sum"]+call_log["pointer.sum"] #call_log["write.sum"] # TODO: Key Feature: use computable pointers for top 2^32 nodes
    read_count = 0 #call_log["read.len"]
    write_count = call_log["write.len"] 
    total_calls = read_count + write_count
    glen = max(1,call_log["write.len"])
    [cnt,ptrs,ids]=[call_log[k+'.sum']/glen for k in ['counter','pointer','id']]
    b_eff = (n*p)/(n*p+sum_read+sum_write+min(CACHE_SIZE, n*WC))
    beff_trace.append(b_eff)
    return b_eff, sum_read, sum_write, glen, cnt, ptrs, ids


def run_bfs_merge(n=32, p=64):
    """
    1) Generate n random integers (seed=42).
    2) Partition into sorted batches (size=5).
    3) For each batch:
       - Build a local partial-match tree, ensuring each integer is
         converted to a p-bit binary string (leading zeros).
       - BFS-merge that local tree into the global partial-match tree.
    4) Return final_data, is_sorted, call_log, global_nodes, root_idx.
    """

    global batch_mem, simple_nodes

    simple_nodes = None
    max_depth = p
    root_max_bits = p

    random.seed(42)
    print("data:", n)

    # Partition into sorted batches
    batch_size = min(int(n/(2*8)), 2**9)
    sorted_batches = []
    data = []
    i = 0
    while i < n:
        def generate():
            data = [random.randint(0, 2**p if p<64 else 2**64-1) for _ in range(min(n, batch_size))]
            print("data:", data[:2**5], ":", len(data)) if debug else None
            chunk = data #[i:end]
            chunk.sort()
            return chunk
        sorted_batches.append(lambda: timed(lambda: generate(), "generate random keys"))
        i = min(i + batch_size, n)


    call_log = {"read.sum": 0, "read.len": 0, "write.sum": 0, "write.len": 0, "counter.sum": 0, "pointer.sum": 0, "id.sum": 0}

    @lru_cache(None)
    def compute_node_size(node):
        # node_size = counter_width + len(identifier) + (#children * log2(n))
        cwidth = math.log2(node.counter) if node.counter>0 else 0
        #iwidth = math.log2(p) + len(node.identifier)
        childsize = sum([math.log2(p) + len(k) + (math.log2(n)-1 if idx else 0) for k,idx in node.children.items()])
        return cwidth + childsize


    def new_global_node(identifier, parent):
        global GLOBAL_OFFSET
        # If root => cap bits (though we won't exceed p below)
        depth = 0 if parent is None else parent.depth+1
        identifier = "" if identifier is None else identifier
        path = "" if parent is None or parent.path is None else parent.path+identifier
        if depth == 0 and len(identifier) > root_max_bits:
            identifier = identifier[:root_max_bits]
        idx = GLOBAL_OFFSET + len(GLOBAL_NODES)
        GLOBAL_NODES.append(MergeNode(idx, identifier, depth, path))
        return idx

    #def get_global_node(idx, global_nodes=GLOBAL_NODES):
    #    return global_nodes[idx] if idx < len(global_nodes) and global_nodes[idx] is not None else get_global_node_from_mmap(idx)


    @lru_cache(None)
    def common_prefix_len(a,b):
        limit=min(len(a), len(b))
        i=0
        while i<limit and a[i] == b[i]:
            i+=1
        return i


    @lru_cache(None)
    def is_leaf_adjacent(node):
        child_ptrs = lambda nd: list(filter(lambda v:v, nd.children.values()))
        sub_child_ptrs = list(filter(lambda v:v, [len(child_ptrs(GLOBAL_NODES[ptr]))>0 for ptr in child_ptrs(node)]))
        return len(sub_child_ptrs) == 0
       
   
    def call_log_append(ctype, node_id, field, val=""):
        #global CACHE_DEPTH
        def size():
            if field == "count":
                return math.log2(val if val else n)
            elif field == "id":
                return len(val)*2 # + math.log2(p)
            else:
                return val if val else math.log2(n) 
        node = get_global_node(node_id)
        #print("call_log.node.depth, CACHE_DEPTH = ", node.depth, CACHE_DEPTH)
        #if node.depth < CACHE_DEPTH:
        #    return 
        (ntype, ctype) = (ctype, "read" if ctype=="nread" else ctype)
        if ctype not in call_log:
            call_log[ctype] = {}
        c = call_log[ctype]
        if node_id not in c:
            c[node_id] = {}
        nd = c[node_id]
        nd[field] = nd[field]+size() if field in nd else size()
        if ntype == "nread":
            nd[field] -= 2*size()


    ################################################################
    # Simplified write_op for the global partial-match tree
    ################################################################
    def write_op(node_idx, bitstr, count=0, identifier="", parent=None,is_leaf=False):
        node = get_global_node(node_idx)
        siblings, keys = {}, node.children.keys()
        for k1,k2 in zip(sorted(keys), sorted(keys,reverse=True)):
            siblings[k1] = k2
        # Here we read this node and two child ids (& compute the mean id size)

        first_visit = node_idx not in visited
        # Step 1: increment node.counter
        print("write_op.bitstr,id,cnt,n.cnt,n.cs,idx,n.d,first_visit = ", (bitstr, identifier, count, node.counter, node.children, f"idx={node_idx}", node.depth, first_visit)) if debug else None
        #if first_visit:
        #visited[node_idx] = node.counter
        call_log_append("read", node_idx, "count", node.counter) # counter
        call_log_append("write", node_idx, "count", node.counter) # counter
        #if not is_leaf and not is_leaf_adjacent(node):
        #    call_log_append("read", node_idx, "pointer") # counter
        node.counter += max(1,count) #1 if count == 0 else max(count,0)


        # partial match with node.identifier
        px = common_prefix_len(identifier, bitstr)
        leftover_node = identifier[px:]
        leftover_str  = bitstr[px:]
        new_idx = None

        # Step 2) if leftover_node != "" => create new child node
        if leftover_node != "" and px > 0: #identifier[:px] != "":
            pre_idx = new_global_node(identifier[:px], parent)
            pre_node = get_global_node(pre_idx)
            pre_node.children[leftover_node] = None if max(1,count)==node.counter/2 and len(node.children.items())==0 else node_idx
            pre_node.counter = node.counter 
            node.counter -= max(1,count) 
            ncount = 0
            new_idx = pre_idx
            if leftover_str != "":
                pre_node.children[leftover_str] = None
                pre_node.counter -= max(1,count)
                ncount =get_null_child_count(pre_node,leftover_str,GLOBAL_NODES)
                pre_node.counter += max(1,count)
                if max(1,count) != ncount:
                    new_idx = new_global_node(leftover_str, pre_node)
                    get_global_node(new_idx).counter = max(1,count)
                    pre_node.children[leftover_str] = new_idx
            node.identifier = leftover_node
            if not parent is None:
                if identifier in parent.children:
                    del parent.children[identifier]
                parent.children[identifier[:px]] = pre_idx # if v is None else v
            print("write_op.nd.children, idx, cnt,pre.cnt,node.cnt,ncnt, nchild, leftover_node, parent, pre, id = ", (node.children, node_idx, max(1,count),pre_node.counter,node.counter,ncount, len(node.children.items()), leftover_node, None if parent is None else (parent.children,parent.node_id,parent.counter), (pre_node.children,pre_node.node_id,pre_node.counter), identifier)) if debug else None
            return new_idx, True

        # Step 3) if leftover_str != "", see if partial child => else new child => call write_op
        if leftover_str=="" and leftover_node=="": # and first_visit:
            all_null, ncid = True, ""
            # Case of node has null child where node & child counts diverge
            for cid,cdx in node.children.copy().items():
               all_null = all_null and cdx is None
            cs = {}
            if all_null and len(node.children.items())>1:
                for cid,c_idx in node.children.copy().items():
                  call_log_append("read", node_idx, "id", cid) # id
                  if c_idx is None:
                    c_idx = new_global_node(cid, node)
                    node.counter -= max(1,count)
                    get_global_node(c_idx).counter = get_null_child_count(node, cid, GLOBAL_NODES)
                    node.counter += max(1,count)
                    cs[cid] = c_idx
                node.children.update(cs)
                print("write_op.cid,ncs,nid,count = ", (cid, node.children,node.node_id,node.counter )) if debug else None
            return node_idx, False
        elif leftover_str!="":
            best_px2=0
            best_cid2=None
            best_idx2=-1
            for cid, cdx in node.children.items():
                call_log_append("read", node_idx, "id", cid) # id
                px2 = common_prefix_len(cid, leftover_str)
                if px2>best_px2:
                    best_px2= px2
                    best_cid2= cid
                    best_idx2= cdx
            if best_px2==0:
                node.children[leftover_str] = None
                ncount = get_null_child_count(node, leftover_str, GLOBAL_NODES)
                if max(1,count) != ncount: 
                    new_idx = new_global_node(leftover_str, node)
                    get_global_node(new_idx).counter = max(1,count)
                    node.children[leftover_str] = new_idx
                    node_idx = new_idx
                print("write_op.nd.children, nchild, new_idx, leftover_str, cnt, n.cnt,ncnt = ", (node.children, len(node.children.items()), node_idx, leftover_str, count, node.counter,ncount)) if debug else None
                return node_idx, True
            else:
                if best_idx2 is None:
                    node.counter -= max(1,count)
                    ncount = get_null_child_count(node,best_cid2,GLOBAL_NODES)
                    node.counter += max(1,count)
                if best_idx2 is None and best_px2>0 and (leftover_str!=best_cid2 or ncount!=node.counter/2 and ncount != node.counter):
                    best_idx2 = new_global_node(best_cid2, node)
                    get_global_node(best_idx2).counter = ncount
                    node.children[best_cid2] = best_idx2
                    print("write_op.best_idx2,best_px2,best_cid2,leftover_str,node.cnt,ncnt,cnt = ", (best_idx2,best_px2,best_cid2,leftover_str,node.counter,ncount,get_global_node(best_idx2).counter)) if debug else None
                    call_log_append("nread", best_idx2, "count", ncount) 
                if best_idx2 is not None:
                    return write_op(best_idx2,leftover_str,count,best_cid2,node,is_leaf)

        return node_idx if new_idx is None else new_idx, False


    ################################################################
    # BFS merges from local partial-match trees
    ################################################################
    def gather_data(root_idx):
        results=[]
        def dfs(i, identifier="", pre="", parent="0"):
            nd= get_global_node(i) #GLOBAL_NODES[i]
            print("gather_data.i,nd,cnt,child,ident = ", i, nd, nd.counter, nd.children, identifier) if debug else None
            if identifier and len(nd.children.items())==0:
                val=int(pre+identifier,2)
                results.extend([val]*nd.counter)
            else:
                pre += identifier
            for cid,cx in sorted(nd.children.items()):
                if cx is None:
                    val=int(parent+identifier+cid,2)
                    c0 = get_null_child_count(nd, cid, GLOBAL_NODES)
                    results.extend([val]*c0)
                else:
                    dfs(cx, cid, pre, parent+identifier)
        dfs(root_idx)
        return results

    ################################################################
    # local partial-match tree classes + function
    ################################################################
    class LocalNode:
        def __init__(self, identifier=""):
            self.identifier = identifier
            self.counter = 0
            self.children = {}

    @lru_cache(None)
    def local_common_prefix_len(a,b):
        i=0
        limit=min(len(a), len(b))
        while i<limit and a[i]==b[i]:
            i+=1
        return i

    def local_write(node, bits):
        # standard partial-match logic
        best_px=0
        best_cid=None
        node.counter += 1
        for cid, cnd in node.children.items():
            px= local_common_prefix_len(cid, bits)
            if px> best_px:
                best_px=px
                best_cid=cid

        if best_px==0:
            # no match => create child
            nn= LocalNode(bits)
            nn.counter=1
            node.children[bits]= nn
        else:
            leftover_s= bits[best_px:]
            leftover_c= best_cid[best_px:]
            cnode= node.children[best_cid]

            if leftover_s=="" and leftover_c=="":
                cnode.counter += 1
            elif leftover_s=="" and leftover_c!="":
                prefix= best_cid[:best_px]
                new_parent= LocalNode(prefix)
                cnode.counter+=1
                new_parent.counter=cnode.counter
                del node.children[best_cid]
                cnode.identifier= leftover_c
                new_parent.children[leftover_c]= cnode
                node.children[prefix]= new_parent
            elif leftover_s!="" and leftover_c=="":
                local_write(cnode, leftover_s)
            else:
                prefix= best_cid[:best_px]
                new_parent= LocalNode(prefix)
                new_parent.counter=cnode.counter+1
                del node.children[best_cid]
                cnode.identifier= leftover_c
                new_parent.children[leftover_c]= cnode
                brand= LocalNode(leftover_s)
                brand.counter=1
                new_parent.children[leftover_s]= brand
                node.children[prefix]= new_parent

    def build_local_tree(b):
        r= LocalNode("")
        for val in b:
            # zero-pad the bitstring to length p
            bs= f"{val:0{p}b}" #format(val,'b').zfill(p)
            local_write(r, bs)
        return r

    def print_local_tree(node, prefix=""):
        # DFS on local partial-match nodes
        child_keys= sorted(node.children.keys())
        print(f"{prefix}[local] id='{node.identifier}' c={node.counter}, children={child_keys}")
        for cid in child_keys:
            cnd= node.children[cid]
            print_local_tree(cnd, prefix+"  ")


    def process_bfs_item(args):
        """
        This helper function processes a single BFS item (one node at the current level).
        It returns a list of new items that will form the next level of the BFS.
        """
        curr_idx, identifier, ln, copy, pnt = args
    
        curr = get_global_node(curr_idx)
        bitstr = identifier + ln.identifier

        px = len(curr.path) - len(curr.identifier)
        count, cs = curr.counter, curr.children.copy()

        # The 'write_op' call (same logic as in your snippet)
        # returns (nxt_idx, copyFlag). We'll keep that logic unchanged
        nxt_idx, _ = write_op(curr_idx, bitstr[px:], ln.counter, curr.identifier, pnt, False) 

        nxt = get_global_node(nxt_idx)
        px = len(bitstr)

        # Gather the items (children) we want to enqueue for the next level
        next_items = []
    
        cs_nxt = nxt.children.copy().items()
        for cid, cnd in ln.children.items():
            npx, (ncid, ncdx) = sorted(
                [(common_prefix_len(bitstr + cid, nxt.path + k), (k,v)) for k,v in cs_nxt],
                reverse=True
            )[0] if len(cs_nxt) else (0,(cid,None))

            if npx <= px and len(nxt.children.items()) <= 1:
                ncid, ncdx = (bitstr + cid)[px:], None

            # Adjust counters
            nxt.counter -= ln.counter
            ncount = get_null_child_count(nxt, ncid, GLOBAL_NODES) if ncid in nxt.children and ncdx is None else 0
            nxt.counter += ln.counter

            # Create or reuse the child
            ncdx = new_global_node(ncid, nxt) if ncdx is None else ncdx
            if ncount > 0:
                get_global_node(ncdx).counter = ncount
        
            nxt.children[ncid] = ncdx
            # Prepare the BFS item for next level
            next_items.append([ncdx, identifier + ln.identifier, cnd, copy, nxt])

        return next_items


    def bfs_merge_local_into_global_parallel(local_root, global_root_idx, first_batch):
        global visited
        visited = {}
    
        queue = deque([[global_root_idx, "", local_root, False, None]])
    
        while queue:
            # Collect all items in this level
            size = len(queue)
            level_items = [queue.popleft() for _ in range(size)]
        
            # We'll process each item in parallel threads
            next_level = []
            with ThreadPoolExecutor() as executor:
                # Submit each BFS item for processing
                futures = [executor.submit(process_bfs_item, item) for item in level_items]
            
                # Gather results (new BFS items from each thread) 
                for f in as_completed(futures):
                    child_items = f.result()  # this should be a list of BFS items
                    next_level.extend(child_items)
        
            # Enqueue all children for the next BFS level
            for item in next_level:
                queue.append(item)

        visited = {}


    def bfs_merge_local_into_global(local_root, global_root_idx, first_batch):
        global visited
        visited = {}
        queue = deque([[global_root_idx, "", local_root, False, None]])
        while queue:
            size = len(queue)
            for _ in range(size):
                    [curr_idx, identifier, ln, copy, pnt] = queue.popleft()
                    curr = get_global_node(curr_idx)
                    bitstr = identifier+ln.identifier
                    px = len(curr.path) - len(curr.identifier)
                    args = (identifier,curr.identifier,curr.node_id,curr.children,ln.identifier,px,len(identifier),curr.path,bitstr,bitstr[px:],copy,curr_idx in visited)
                    print("bfs_merge.id,curr.id,curr.nodeid,curr.cs,ln.id,px,id.len,path,bitstr,bitstr.px,cp,is_visited = ", args) if debug else None
                    count, cs = curr.counter, curr.children.copy()
                    is_leaf = len(ln.children.items())==0
                    if copy:
                        nxt_idx, copy = write_op(curr_idx, bitstr[px:], ln.counter, curr.identifier,pnt, is_leaf)
                    else:
                        nxt_idx, copy = write_op(curr_idx, bitstr[px:], ln.counter, curr.identifier,pnt, is_leaf)
                    nxt = get_global_node(nxt_idx)
                    cs = nxt.children.copy().items()
                    px = len(bitstr)
                    for cid,cnd in ln.children.items():
                        (npx,(ncid,ncdx)) = sorted([(common_prefix_len(bitstr+cid,nxt.path+k),(k,v)) for k,v in cs], reverse=True)[0] if len(cs) else (0,(cid,None))
                        if npx <= px and len(nxt.children.items())<=1:
                            ncid, ncdx = (bitstr+cid)[px:], None
                        nxt.counter -= ln.counter
                        ncount = get_null_child_count(nxt, ncid, GLOBAL_NODES) if ncid in nxt.children and ncdx is None else 0
                        nxt.counter += ln.counter
                        ncdx = new_global_node(ncid, nxt) if ncdx is None else ncdx
                        if ncount>0:
                            get_global_node(ncdx).counter = ncount 
                        node = get_global_node(ncdx)
                        nxt.children[ncid] = ncdx
                        queue.append([ncdx,identifier+ln.identifier,cnd,copy,nxt])
                        print("px,npx,bitstr,ncid,ncdx,cid,cs,bits,nbits = ", (px,npx,bitstr, ncid, ncdx, cid,cs,bitstr+cid, nxt.path+ncid,common_prefix_len(bitstr+cid,nxt.path+ncid))) if debug else None
        visited = {}

    # Build global tree
    GLOBAL_NODES.clear()
    call_log.clear()
    call_log = {"read.sum": 0, "read.len": 0, "write.sum": 0, "write.len": 0, "counter.sum": 0, "pointer.sum": 0, "id.sum": 0}
    root_idx= GLOBAL_OFFSET + len(GLOBAL_NODES)
    GLOBAL_NODES.append(MergeNode(root_idx, "",0))
   

    def get_simple_nodes():
        """
        Return all child-node IDs of 'simple' parents in a single pass.
   
        A parent 'p' is considered simple if:
          - It has exactly 1 child whose .counter equals p.counter, OR
          - It has exactly 2 children whose counters are the same.
        """
        sns = []
        for p in GLOBAL_NODES:
            # Build a list of counters for each child
            counters = []
            for cid, n_id in p.children.items():
                if n_id in GLOBAL_NODES:
                    counters.append(GLOBAL_NODES[n_id].counter)
                else:
                    counters.append(get_null_child_count(p, cid, GLOBAL_NODES))

            # Check if 'p' meets the "simple" criteria
            if (len(counters) == 1 and counters[0] == p.counter) \
               or (len(counters) == 2 and counters[0] == counters[1]):
                # Gather all non-None child IDs for this parent
                for n_id in p.children.values():
                    if n_id is not None:
                        sns.append(n_id)

        return sns


    def is_simple(node_idx):
        """
        Checks whether a given node index is in the "simple" node set.
        Caches the set after the first call for efficiency.
        """
        global simple_nodes
        if simple_nodes is None:
            # Build the list of simple children and store as a set
            node_list = timed(lambda: get_simple_nodes(), "simple nodes")
            # If absolutely none, store a dummy set with [None]
            # so we don't repeat next time
            simple_nodes = set(node_list) if node_list else {None}
            print("simple_nodes =", len(simple_nodes))
        return node_idx in simple_nodes


    def get_simple_nodes1():
        def has_simple(entry):
            (p, c) = entry
            return len(c)==1 and c[0]==p.counter or len(c)==2 and c[0]==c[1]
        counts = [(p,[GLOBAL_NODES[n_id].counter if n_id in GLOBAL_NODES else get_null_child_count(p, cid, GLOBAL_NODES) for cid,n_id in p.children.items()]) for p in GLOBAL_NODES]
        cids=[p.children.values() for p,cnts in list(filter(has_simple,counts))]
        sns = []
        for c in cids:
            sns += list(filter(lambda n_id: n_id is not None, c))
        return sns

    def is_simple1(node_idx):
        global simple_nodes
        if simple_nodes == []:
            simple_nodes = get_simple_nodes()
            simple_nodes = [None] if simple_nodes == [] else simple_nodes
        return node_idx in simple_nodes

   
    global CACHE_DEPTH, COMPUTABLES_DEPTH

    gnodes = []
    # For each sorted batch => build local partial-match tree => BFS merge
    for batch_i, batch_gen in enumerate(sorted_batches):
        batch = batch_gen()
        global_len = GLOBAL_OFFSET + len(GLOBAL_NODES)
        print(f"\n--- BATCH {batch_i} of {len(sorted_batches)} => {batch[:20]}:{len(batch)} ---") if debug else None
        local_root= timed(lambda: build_local_tree(batch), "build_local_tree")
        # print the local tree
        print("Local Tree (DFS):") if debug else None
        print_local_tree(local_root) if debug else None
        timed(lambda: bfs_merge_local_into_global(local_root, root_idx, batch_i==0), "bfs_merge")
        print(f"\n==== Global Merge Tree(DFS order) {GLOBAL_OFFSET + len(GLOBAL_NODES)} nodes ====") if debug else None
        gnodes = []
        ncnt = print_merge_tree_dfs(root_idx, GLOBAL_NODES, nodes=gnodes) 
        print(f"==== Global Merge Tree(DFS order) {ncnt} actual nodes ====\n") if debug else None
        batch_mem += len(batch)*math.log2(n)*(0.2+1)*(math.log2(p)+(p/math.log2(n)))
        collect= lambda k,fn: sum([fn(log.values()) for _,log in call_log[k].items()])
        collect_fld = lambda k,fld,fn: sum([fn(log.values()) if f==fld else 0 for f,log in call_log[k].items()]) 
        print("read.keys = ", call_log["read"].keys()) if debug else None
        gnodes = set(gnodes)
        #pnode_ids = gnodes & set(call_log["read"].keys())
        node_ids = list(gnodes & set([n.node_id for n in GLOBAL_NODES]))
        pnode_ids = list(gnodes & set(call_log["read"].keys()) - set(node_ids))
        pnodes = [get_global_node(i) for i in set(pnode_ids)]
        nodes0 = [get_global_node(i) for i in set(node_ids)]
        gnodes, pnode_ids, node_ids = [], [], []
        call_log["read.sum"] += collect("read", sum)
        #call_log["write.sum"] += sum([compute_node_size(g) for g in nodes]) 
        csum0 = sum([0.5*math.ceil(math.log2(g.counter)) if g.depth>CACHE_DEPTH and g.counter>0 else 0 for g in pnodes]) 
        csum1 = sum([0.5*math.ceil(math.log2(g.counter)) if g.depth>CACHE_DEPTH and g.counter>0 else 0 for g in nodes0])
        print("pnodes, nodes0, cache, csum0, csum1 = ", len(pnodes), len(nodes0), CACHE_DEPTH, csum0, csum1)
        call_log["counter.sum"] += csum0 
        call_log["counter.sum"] += csum1 
        call_log["pointer.sum"] += 0.5*math.ceil(math.log2(n)) * len(list(filter(lambda nd: nd.depth>COMPUTABLES_DEPTH and len(list(filter(lambda v:v, nd.children.values())))==0, nodes0+pnodes))) #lambda nd: not is_leaf_adjacent(nd), nodes))]) 
        call_log["id.sum"] += sum([2*len(g.identifier) if g.depth>COMPUTABLES_DEPTH else 0 for g in nodes0+pnodes])
        call_log["read.len"] += collect("read", len)
        call_log["write.len"] += len(nodes0)+len(pnodes)
        call_log["read"], call_log["write"], nodes = {}, {}, []
        gnodes, nodes0, pnodes, pnode_ids, node_ids = [], [], [], [], []
        currn = (batch_i+1)*len(batch)
        b_eff, sum_read, sum_write, glen = get_beff(call_log,currn,p)[0:4]
        print(f" batch {batch_i} b_eff={b_eff}, write={sum_write},calls={glen}")
        flush_global_nodes_to_file()
        batch.clear()

    final_data= gather_data(root_idx)
    final_data_sorted= sorted(final_data)
    is_sorted= (final_data== final_data_sorted)
    return final_data, is_sorted, call_log, GLOBAL_NODES, root_idx, sorted(data)

def gather_counters(root_idx):
    """
    Traverse the binary tree in BFS order and collect all counter values.

    :param root: The root node of the binary tree
    :return: A list of integer/float counter values from every node in the tree
    """
    counters = []
    queue = deque([root_idx])
    while queue:
        node_idx = queue.popleft()
        node = get_global_node(node_idx)
        counters.append(math.log2(node.counter) if node.counter>0 else 0)
        for cid,cdx in node.children.items():
            if cdx is not None:
                queue.append(cdx)
    #print("gather_counters().counters = ", (counters, len(counters)))
    return counters


def plot_counters(all_counters):

    # Gather all counters in the tree
    #all_counters = gather_counters(root_idx)
    mean_log2 = np.mean(all_counters)

    # Plot a histogram of the counter distribution

    plt.rcParams.update({"font.size": 20})
    plt.figure()
    plt.hist(all_counters, bins=10, edgecolor='black')
    plt.title("Distribution of log2(Counter Values)")
    plt.ylabel("Frequency")          # X-axis is frequency now
    plt.xlabel("log2(Counter)")      # Y-axis is the bin variable

    # 5) Add a horizontal line at the mean and label it
    plt.axvline(mean_log2, color='red', linestyle='--',
                label=f"Mean log2 = {mean_log2:.2f}")
    plt.legend(loc='upper right')


    # Display the plot
    #plt.show()


def plot_experiments(experiments):
    """
    Draw one histogram per experiment and show the *mean counter width*
    ( log₂ ) as a vertical dashed line **with a legend entry**, instead of
    a text box inside the axes.
    """
    # ── lay out a grid of subplots ────────────────────────────────────
    num_expts = len(experiments)
    ncols     = 2
    nrows     = (num_expts + ncols - 1) // ncols           # round-up
    plt.rcParams.update({"font.size": 20})

    fig, axes = plt.subplots(
        nrows=nrows, ncols=ncols, figsize=(14, 6), squeeze=False
    )
    axes_flat = axes.ravel()

    # ── one panel per experiment ─────────────────────────────────────
    for i, (n, p, log2_counters) in enumerate(experiments):
        ax = axes_flat[i]

        # histogram
        ax.hist(log2_counters, bins=20, edgecolor="black")

        # title + labels
        ax.set_title(rf"$n=2^{{{n}}}$,  $p={p}$")
        ax.set_xlabel(r"$w_c$")
        ax.set_ylabel("Frequency")

        # mean → red dashed line **with label for legend**
        if log2_counters:
            mean_log2 = np.mean(log2_counters)
            ax.axvline(
                mean_log2,
                color="red",
                linestyle="--",
                linewidth=2.0,
                label=rf"$\mu={mean_log2:.2f}$",
            )
            ax.legend(loc="upper right", frameon=False)

    # hide unused axes cells
    for j in range(i + 1, len(axes_flat)):
        axes_flat[j].set_visible(False)

    plt.tight_layout()
    plt.savefig("w_c.png", dpi=300, bbox_inches="tight")
    plt.show()


def plot_from_tuples(data_tuples, title="Bandwidth Efficiency", xlabel="n", ylabel="b_eff"):
    """
    Plot a graph from a list of tuples.
   
    Parameters:
    data_tuples: List of tuples where each tuple contains (x, y) coordinates
    title: Title of the graph (default: "Graph")
    xlabel: Label for x-axis (default: "X-axis")
    ylabel: Label for y-axis (default: "Y-axis")
    """
    # Separate x and y coordinates
    x_coords = [point[0] for point in data_tuples]
    y_coords = [point[1] for point in data_tuples]
   
    # Create the plot
    plt.figure(figsize=(10, 6))
    plt.plot(x_coords, y_coords, 'b-o')  # 'b-o' means blue line with circle markers
   
    # Add labels and title
    plt.title(title)
    plt.xlabel(xlabel)
    plt.ylabel(ylabel)
   
    # Add grid
    plt.grid(True)
   
    # Display the plot
    plt.show()


def save_tuple(tup, filename="cache_file.pkl"):
    """
    Saves the given tuple 'tup' to a file using pickle.
    """
    with open(filename, "wb") as f:
        pickle.dump(tup, f)


def load_tuple(supplier, filename="cache_file.pkl"):
    """
    Loads a tuple from a pickle file and returns it.
    """
    if not os.path.isfile(filename):
        save_tuple(supplier(), filename)

    with open(filename, "rb") as f:
        return pickle.load(f)


def main(n_init=2**17, p=2**5):
    global GLOBAL_NODES, NODE_FILE, global_recs, beff_trace
    GLOBAL_NODES, global_recs, beff_trace = [], global_recs, []
    if os.path.exists(NODE_FILE):
        os.remove(NODE_FILE)
    for fp in glob.glob("*.pk1"):
        try:
            os.remove(fp)
        except OSError as e:
            print("Error cleaning pk1 file: ", e)
    n = n_init # For illustration
    (final_data, is_sorted, call_log, global_nodes, root_idx, sorted_data) = load_tuple(lambda: (run_bfs_merge(n, p)), f"experiment_n{n}_p{p}.pk1")
    if not len(GLOBAL_NODES):
        GLOBAL_NODES = global_nodes

    print(f"\nFinal data size: {len(final_data)} = 2**{math.log2(len(final_data))}")
    print(f"Is sorted? {is_sorted}")
    print(f"Is Equal? {sorted_data == final_data}")
    print(f"Final data: {final_data[:2**5]}:{len(final_data)}")

    [b_eff, sum_read, sum_write, glen, cnts,ptrs,ids]= get_beff(call_log, n, p)

    print("\nOperation Summary:")
    print(f"  counter calls total size:  {call_log['counter.sum']/glen}")
    print(f"  pointer calls total size:  {call_log['pointer.sum']/glen}")
    print(f"  id calls total size:  {call_log['id.sum']/glen}")
    print(f"  read calls total size:  {sum_read}")
    print(f"  write calls total size: {sum_write}")
    print(f"  combined total size:    {sum_read + sum_write}")
    print(f"  #read calls: {0}, #write calls: {glen}, total calls: {glen}")
    print(f"  batch read/write memory size: {batch_mem}")

    print(f"\nb_eff,n,p = (n*p)/(n*p+sum_read+sum_write) = {b_eff:.4f},{(math.log2(n),p)}")

    print(f"\n==== Global Merge Tree(DFS order) {GLOBAL_OFFSET+len(global_nodes)} nodes ====")
    ncnt = print_merge_tree_dfs(root_idx, global_nodes)
    print(f"==== Global Merge Tree(DFS order) {ncnt} actual nodes ====\n") 
    #plot_counters(root_idx)
    return beff_trace, b_eff, gather_counters(root_idx), p, cnts, ptrs, ids


if __name__=="__main__1":
    timing_data, all_counters, ps, cnts, ptrs, ids, exps = [], [], [], [], [], [], [20] #[12, 16, 18, 20] #, 24] #[4, 6, 8, 10] #, 12, 16, 20, 24] #[7, 11, 15] #[30] #[7, 11, 15] #, 18, 20]
    traces = {}
    for i in exps: 
        start=time()
        p_init=int(sys.argv[sys.argv.index("-p")+1] if "-p" in sys.argv else 32)
        print("p_init = ", p_init)
        btrace, beff, counters, p, icts, ipts, iids = main(n_init=2**i,p=p_init)
        traces[p_init] = btrace
        ps.append(p)
        all_counters.append(counters)
        print(f"i = {i}, b_eff = {beff}, Experiment n=2**{i}")
        timing_data.append((i, beff, icts, ipts, iids)) 
    plot_experiments(list(zip(exps, ps, all_counters)))
    plot_from_tuples(timing_data)
    print(timing_data)


if __name__=="__main__1":
   # data = [None for i in range(2**32)]
    data = np.memmap(NODE_FILE, dtype=NODE_DTYPE, mode='r')
    print(len(data))
    for i in range(2**32): #range(2**32): #enumerate(data):
        d = data[i % len(data)]
        print(i, d)
    print("done")



if __name__ == "__main__1":
    # --------------------------------------------------------------
    # 1) choose the n-range you want to test
    # --------------------------------------------------------------
    exps = [16] #, 16, 18, 20]        #  n = 2**12 … 2**20  (edit at will)

    # --------------------------------------------------------------
    # 2) run every experiment for every p_init in P_LIST
    # --------------------------------------------------------------
    p_init = int(sys.argv[sys.argv.index("-p")+1]) if "-p" in sys.argv else 32
    show_plot = sys.argv[sys.argv.index("-s")+1] if "-s" in sys.argv else "true"
    tfile=sys.argv[sys.argv.index("-t")+1] if "-t" in sys.argv else "traces.pk1"
    P_LIST = [p_init] #[16, 32, 64, 128, 256]
    traces = {}
    if os.path.exists(tfile):
        with open(tfile, "rb") as f:
            traces = pickle.load(f)

    for i,p_init in enumerate(P_LIST):
        print(f"\n=== running all n for p_init = {p_init} ===")
        for k in exps:
            n_val = 2 ** k
            print(f"  » n = 2**{k} ({n_val})")
            btrace, b_eff, *_ = main(n_init=n_val, p=p_init)
            traces[p_init] = btrace
        #plot_beff_traces(traces, list(traces.keys()))
    with open(tfile, "wb") as f:
        pickle.dump(traces, f)

    # --------------------------------------------------------------
    # 3) draw everything on one figure
    # --------------------------------------------------------------
    if show_plot == "true":
        sleep(180)
        for fp in glob.glob("traces.pk1"):
          try:
            trace = {}
            if os.path.exists(fp):
                with open(fp, "rb") as f:
                    trace = pickle.load(f)
            print("trace =", trace.keys())
            traces.update(trace)
          except OSError as e:
            print("Error cleaning pk1 file: ", e)
        plot_beff_traces(traces, list(traces.keys()))


if __name__ == "__main__":
    # 1) build a local tree directly from text
    intext = "H" #ello, world!"
    local_root = build_local_tree(intext)

    # 2) write it to disk
    fname = persist_local_tree(local_root)
    print("saved ", fname)

    # 3) read it back and print the reconstructed text
    text = read_from_binary_file(fname)
    print("intext, text =", (intext, text))

    print(text == intext)

