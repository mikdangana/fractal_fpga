from time import time;
from concurrent.futures import ThreadPoolExecutor, as_completed
from random import randint;
#from merge_operations_timsort import *;


p=32
a = [[0,1,2,3,4,5,6,7,8,9] for i in range(2**3)]
b = [randint(0,2**32) for i in range(2**25)]
c = b.copy()
result = []
n_workers = 400
executor = ThreadPoolExecutor(max_workers=n_workers)


    ################################################################
    # local partial-match tree classes + function
    ################################################################
class LocalNode:
        def __init__(self, identifier=""):
            self.identifier = identifier
            self.counter = 0
            self.children = {}

def new_local_node1(identifier="", counter=0):
    return (identifier, counter, {})

def new_local_node(bits=0, length=0, counter=0):
    # use a *list* so we can mutate fields in place
    return [bits, length, counter, {}]

def local_common_prefix_len(a,b):
        i=0
        limit=min(len(a), len(b))
        while i<limit and a[i]==b[i]:
            i+=1
        return i

################################################################
# helpers (put these near the top of the file)
################################################################
def common_prefix_len(a_bits: int, a_len: int,
                      b_bits: int, b_len: int) -> int:
    """
    How many leading bits are identical in the two bit sequences?
    The sequences are the high-order `a_len` / `b_len` bits of a_bits / b_bits.
    """
    max_len = min(a_len, b_len)
    # Align both numbers so that the MSB of the relevant window is bit (max_len-1)
    a_aligned = a_bits >> (a_len - max_len)
    b_aligned = b_bits >> (b_len - max_len)
    diff      = a_aligned ^ b_aligned
    if diff == 0:                      # all max_len bits match
        return max_len
    return max_len - diff.bit_length() # leading zeros before first 1-bit


def low_bits(value: int, n: int) -> int:
    """Return the lowest-order n bits of *value* ( n may be 0 )."""
    if n == 0:
        return 0
    return value & ((1 << n) - 1)


def local_write(node, bits: int, bits_len: int):
    """
    Insert (bits,bits_len) into a *Patricia* node whose children are
    indexed by the first bit (0-child, 1-child).

    Node layout (mutable list):
        [0] key_bits        (int)   – the compressed edge-label leading here
        [1] key_len         (int)   – number of valid bits in key_bits
        [2] counter         (int)   – visits / payload
        [3] children dict   {0: child, 1: child}
    """
    node[2] += 1                               # bump counter on the way down

    if bits_len == 0:                          # nothing left ⇒ we’re done
        return

    first_bit   = (bits >> (bits_len - 1)) & 1
    children    = node[3]

    # ------------------------------------------------------------
    # No child on that first bit → create a brand-new node in O(1)
    # ------------------------------------------------------------
    if first_bit not in children:
        child = [bits, bits_len, 1, {}]        # new leaf
        children[first_bit] = child
        return

    # ------------------------------------------------------------
    # We *do* have a child on this first bit; find longest prefix
    # ------------------------------------------------------------
    child         = children[first_bit]
    c_bits, c_len = child[0], child[1]

    px = common_prefix_len(bits, bits_len, c_bits, c_len)

    # 1 ▶ exact same key
    if px == bits_len == c_len:
        child[2] += 1                          # just bump counter
        return

    # 2 ▶ child key is a prefix of the value we’re inserting
    if px == c_len:
        # strip the shared prefix and recurse
        leftover_bits = bits & ((1 << (bits_len - px)) - 1)
        local_write(child, leftover_bits, bits_len - px)
        return

    # 3 ▶ value is a prefix of the child key  →  split the edge
    if px == bits_len:
        leftover_child_bits = c_bits & ((1 << (c_len - px)) - 1)
        new_parent = [bits, bits_len, child[2] + 1, {              # ↑
            (leftover_child_bits >> (c_len - px - 1)) & 1: [       # │
                leftover_child_bits,                               # │ old edge
                c_len - px,                                        # │
                child[2],                                          # │
                child[3]                                           # ↓
            ]
        }]
        children[first_bit] = new_parent
        return

    # 4 ▶ keys diverge *after* the shared prefix  →  three-way split
    #     new parent hangs off the current node
    leftover_val_bits   = bits   & ((1 << (bits_len - px)) - 1)
    leftover_child_bits = c_bits & ((1 << (c_len   - px)) - 1)
    parent_bit          = (c_bits >> (c_len - 1)) & 1

    new_parent = [c_bits >> (c_len - px), px, child[2] + 1, {}]

    # existing child becomes one branch …
    child_bit = (leftover_child_bits >> (c_len - px - 1)) & 1
    child[0], child[1] = leftover_child_bits, c_len - px
    new_parent[3][child_bit] = child

    # … and the new value becomes the other
    val_bit = (leftover_val_bits >> (bits_len - px - 1)) & 1
    new_parent[3][val_bit] = [leftover_val_bits, bits_len - px, 1, {}]

    # replace old child with the new parent
    children[parent_bit] = new_parent


def build_local_tree(b):
        r= new_local_node()
        for val in b:
            # zero-pad the bitstring to length p
            bs= val #f"{val:0{p}b}" #format(val,'b').zfill(p)
            local_write(r, bs, p)
        return r

def process_item(i):
    b = int(len(c)/n_workers)
    items = c[i*b:(i+1)*b]
    #items.sort()
    root = build_local_tree(items)
    return items


def run_threads():
                # Submit each BFS item for processing
                futures = [executor.submit(process_item, i) for i in range(n_workers)]
            
                # Gather results (new BFS items from each thread) 
                return [f.result() for f in as_completed(futures)]

start=time()
b.sort()
print("b.sort.time =", time()-start, "ms for", len(b), "entries")

start=time()
#res = run_threads()
print("c.sort.time =", time()-start, "ms for", len(b), "entries")

#i = 0
#while i<100:
#    print(len(a), a[int(i*len(a)/100)])
#    i = i + 1
#    time.sleep(1)

print("done")
