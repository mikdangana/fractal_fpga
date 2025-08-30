import math
import numpy as np
import os
import random
import matplotlib.pyplot as plt
import pickle
from collections import deque
from concurrent.futures import ThreadPoolExecutor, as_completed
from functools import lru_cache
from time import time


visited = {}
debug = False
batch_mem = 0
GLOBAL_NODES = []
CACHE_DEPTH = 0


def get_visited(idx):
    global visited
    ncount = GLOBAL_NODES[idx].counter
    return visited[idx] if idx in visited and ncount>=visited[idx] else 0


def get_update(idx):
    visit = get_visited(idx)
    return GLOBAL_NODES[idx].counter - visit


def get_null_child_count(nd, cid, global_nodes):
    ks = list(filter(lambda k: k!=cid, nd.children.keys()))
    if len(ks) == 0:
        return nd.counter
    v0 = nd.children[ks[0]]
    cnt = lambda: global_nodes[v0].counter
    c0 = int(nd.counter/len(nd.children.items())) if v0 is None else cnt()
    print("get_null_.nd,cid,v0,c0,n.cnt,cnt = ", ((nd.children,nd.node_id,nd.counter), cid, v0, c0, nd.counter, max(0, nd.counter-c0))) if debug else None
    return max(0, nd.counter - c0)


def timed(fn, label):
    start = time()
    res = fn()
    print(f"timed {label} = {(time()-start)*1000} ms", flush=True)
    return res


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

        def clone(self):
            cp = MergeNode(self.node_id, self.identifier, self.depth, self.path)
            cp.counter = self.counter
            cp.children = self.children.copy()
            return cp


def print_merge_tree_dfs(idx, global_nodes, identifier="", prefix="",parent="0",
                         nodes=None):
    node= global_nodes[idx]
    nodes.append(idx) if nodes is not None else None
    cnt = 1
    child_keys= sorted(node.children.items(), reverse=False)
    print(f"{prefix}[{idx}] id='{identifier}' c={node.counter} d={node.depth} children={child_keys} val={int(parent+identifier,2)}") if debug else None
    for cid, c_idx in child_keys:
        if c_idx is None:
            c0 = get_null_child_count(node, cid, global_nodes)
            print(f"  {prefix}[{c_idx}] id='{cid}' c={c0} d={node.depth+1} children=None val={int(parent+identifier+cid,2)}") if debug else None
        elif len(global_nodes[c_idx].children.items()) == 0:
            c0 = global_nodes[c_idx].counter
            print(f"  {prefix}[{c_idx}] id='{cid}' c={c0} d={node.depth+1} children=None val={int(parent+identifier+cid,2)}") if debug else None
        else:
            cnt += print_merge_tree_dfs(c_idx, global_nodes, cid, prefix+"  ", parent+identifier, nodes=nodes)
    return cnt


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
    batch_size = min(int(n/4), 2**20)
    sorted_batches = []
    data = []
    i = 0
    while i < n:
        def generate():
            end = min(i + batch_size, n)
            data = [random.randint(0, 2**p) for _ in range(min(n, batch_size))]
            print("data:", data[:2**5], ":", len(data)) if debug else None
            chunk = data #[i:end]
            chunk.sort()
            sorted_batches.append(chunk)
            return end
        i = timed(lambda: generate(), "generate random keys")


    call_log = {"read.sum": 0, "read.len": 0, "write.sum": 0, "write.len": 0, "counter.sum": 0, "pointer.sum": 0, "id.sum": 0}

    @lru_cache(None)
    def compute_node_size(node):
        # node_size = counter_width + len(identifier) + (#children * log2(n))
        cwidth = math.log2(node.counter)
        #iwidth = math.log2(p) + len(node.identifier)
        childsize = sum([math.log2(p) + len(k) + (math.log2(n)-1 if idx else 0) for k,idx in node.children.items()])
        return cwidth + childsize


    def new_global_node(identifier, parent):
        # If root => cap bits (though we won't exceed p below)
        depth = 0 if parent is None else parent.depth+1
        identifier = "" if identifier is None else identifier
        path = "" if parent is None or parent.path is None else parent.path+identifier
        if depth == 0 and len(identifier) > root_max_bits:
            identifier = identifier[:root_max_bits]
        idx = len(GLOBAL_NODES)
        GLOBAL_NODES.append(MergeNode(idx, identifier, depth, path))
        return idx


    def get_global_node(idx):
        return GLOBAL_NODES[idx]


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
        global CACHE_DEPTH
        def size():
            if field == "count":
                return math.log2(val if val else n)
            elif field == "id":
                return len(val) + math.log2(p)
            else:
                return val if val else math.log2(n) 
        node = GLOBAL_NODES[node_id]
        #print("call_log.node.depth, CACHE_DEPTH = ", node.depth, CACHE_DEPTH)
        if node.depth < CACHE_DEPTH:
            return 
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
    def write_op(node_idx, bitstr, count=0, identifier="", parent=None, is_leaf=False):
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
            nd= GLOBAL_NODES[i]
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
    root_idx= len(GLOBAL_NODES)
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


    gnodes = []
    # For each sorted batch => build local partial-match tree => BFS merge
    for batch_i, batch in enumerate(sorted_batches):
        global_len = len(GLOBAL_NODES)
        print(f"\n--- BATCH {batch_i} of {len(sorted_batches)} => {batch[:20]}:{len(batch)} ---") if debug else None
        local_root= timed(lambda: build_local_tree(batch), "build_local_tree")
        # print the local tree
        print("Local Tree (DFS):") if debug else None
        print_local_tree(local_root) if debug else None
        timed(lambda: bfs_merge_local_into_global(local_root, root_idx, batch_i==0), "bfs_merge")
        print(f"\n==== Global Merge Tree(DFS order) {len(GLOBAL_NODES)} nodes ====") if debug else None
        pnodes, gnodes = gnodes, []
        ncnt = print_merge_tree_dfs(root_idx, GLOBAL_NODES, nodes=gnodes) 
        print(f"==== Global Merge Tree(DFS order) {ncnt} actual nodes ====\n") if debug else None
        batch_mem += len(batch) * math.log2(n)*(0.2+1) * (math.log2(p)+(p/math.log2(n)))
        collect = lambda k,fn: sum([fn(log.values()) for _,log in call_log[k].items()]) 
        collect_fld = lambda k,fld,fn: sum([fn(log.values()) if f==fld else 0 for f,log in call_log[k].items()]) 
        print("read.keys = ", call_log["read"].keys())
        pnode_ids = list(set(pnodes) & set(call_log["read"].keys()))
        node_ids = list(set(gnodes) - set(pnodes))
        nodes = [GLOBAL_NODES[i] for i in set(pnode_ids + node_ids)]
        call_log["read.sum"] += collect("read", sum)
        call_log["write.sum"] += sum([compute_node_size(g) for g in nodes]) 
        call_log["counter.sum"] += sum([0.5*math.ceil(math.log2(g.counter)) for g in nodes]) 
        call_log["pointer.sum"] += sum([0.5*math.ceil(math.log2(n)) for g in list(filter(lambda nd: len(list(filter(lambda v:v, nd.children.values())))==0, nodes))]) #lambda nd: not is_leaf_adjacent(nd), nodes))]) 
        #print("id.p, log2 = ", p, math.log2(p), "batch.len=", len(batch), "pnodes=", len(pnode_ids), "gnodes=", len(node_ids), "call.keys=", len(call_log["read"].keys()), list(call_log["read"].keys()), "nodes=", len(nodes), "ids=", sum([len(g.identifier) for g in nodes])/max(1,len(nodes)))
        call_log["id.sum"]+=sum([2*len(g.identifier) for g in nodes])
        call_log["read.len"] += collect("read", len)
        call_log["write.len"] += len(nodes)
        call_log["read"], call_log["write"] = {}, {}
        global CACHE_DEPTH
        CACHE_DEPTH = 15

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
        node = GLOBAL_NODES[node_idx]
        counters.append(math.log2(node.counter))
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


def main(n_init=2**17):
    global GLOBAL_NODES
    GLOBAL_NODES = []
    n=n_init
    p=2**5 # For illustration
    (final_data, is_sorted, call_log, global_nodes, root_idx, sorted_data) = load_tuple(lambda: (run_bfs_merge(n, p)), f"experiment_n{n}_p{p}.pk1")
    if not len(GLOBAL_NODES):
        GLOBAL_NODES = global_nodes
    #final_data, is_sorted, call_log, global_nodes, root_idx, sorted_data = run_bfs_merge(n, p)

    print(f"\nFinal data size: {len(final_data)} = 2**{math.log2(len(final_data))}")
    print(f"Is sorted? {is_sorted}")
    print(f"Is Equal? {sorted_data == final_data}")
    print(f"Final data: {final_data[:2**5]}:{len(final_data)}")

    sum_read = 0 #call_log["read.sum"]
    sum_write = call_log["counter.sum"]+call_log["id.sum"]+(0 if n <= 2**32 else call_log["pointer.sum"]) #call_log["write.sum"]
    read_count = 0 #call_log["read.len"]
    write_count = call_log["write.len"] #call_log["write.len"] 
    total_calls = read_count + write_count
    glen = max(1,call_log["write.len"])
    [cnts,ptrs,ids]=[call_log[k+'.sum']/glen for k in ['counter','pointer','id']]

    print("\nOperation Summary:")
    print(f"  counter calls total size:  {call_log['counter.sum']/glen}")
    print(f"  pointer calls total size:  {call_log['pointer.sum']/glen}")
    print(f"  id calls total size:  {call_log['id.sum']/glen}")
    print(f"  read calls total size:  {sum_read}")
    print(f"  write calls total size: {sum_write}")
    print(f"  combined total size:    {sum_read + sum_write}")
    print(f"  #read calls: {read_count}, #write calls: {write_count}, total calls: {total_calls}")
    print(f"  batch read/write memory size: {batch_mem}")

    b_eff = (n*p)/(n*p+sum_read+sum_write)
    print(f"\nb_eff,n,p = (n*p)/(n*p+sum_read+sum_write) = {b_eff:.4f},{(math.log2(n),p)}")
    #print(f"\nb_eff_batch = (n*p)/(batch_mem) = {n*p}/{batch_mem} = {(n*p)/batch_mem:.4f}")

    print(f"\n==== Global Merge Tree(DFS order) {len(global_nodes)} nodes ====")
    ncnt = print_merge_tree_dfs(root_idx, global_nodes)
    print(f"==== Global Merge Tree(DFS order) {ncnt} actual nodes ====\n") 
    #plot_counters(root_idx)
    return b_eff, gather_counters(root_idx), p, cnts, ptrs, ids


if __name__=="__main__":
    timing_data, all_counters, ps, cnts, ptrs, ids, exps = [], [], [], [], [], [], [8, 16, 18, 20] #[12, 16, 18, 20] #, 24] #[4, 6, 8, 10] #, 12, 16, 20, 24] #[7, 11, 15] #[30] #[7, 11, 15] #, 18, 20]
    for i in exps: 
        start=time()
        beff, counters, p, icts, ipts, iids = main(n_init=2**i)
        ps.append(p)
        all_counters.append(counters)
        print(f"i = {i}, b_eff = {beff}, Experiment n=2**{i}")
        timing_data.append((i, beff, icts, ipts, iids)) 
    plot_experiments(list(zip(exps, ps, all_counters)))
    plot_from_tuples(timing_data)
    print(timing_data)
