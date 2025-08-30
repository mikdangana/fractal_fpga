import math
import random
import matplotlib.pyplot as plt
from collections import deque
from time import time


visited = {}
debug = True
batch_mem = 0
GLOBAL_NODES = []


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
    print(f"timed {label} = {(time()-start)*1000} ms")
    return res


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
    batch_size = 2**2
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


    call_log = {"read.sum": 0, "read.len": 0, "write.sum": 0, "write.len": 0}

    def compute_node_size(node):
        # node_size = counter_width + len(identifier) + (#children * log2(n))
        cwidth = 0.5*math.log2(n)
        #iwidth = math.log2(p) + len(node.identifier)
        cf = sum([math.log2(p) + len(k) + (math.log2(n)-1 if p else 0) for k,p in node.children.items()])
        return cwidth + cf


    def new_global_node(identifier, parent):
        # If root => cap bits (though we won't exceed p below)
        depth = 0 if parent is None else parent.depth+1
        identifier = "" if identifier is None else identifier
        path = "" if parent is None or parent.path is None else parent.path+identifier
        if depth == 0 and len(identifier) > root_max_bits:
            identifier = identifier[:root_max_bits]
        idx = len(GLOBAL_NODES)
        GLOBAL_NODES.append(MergeNode(idx, identifier, depth, path))
        #call_log_append({"type": "write","size": compute_node_size(GLOBAL_NODES[idx])})
        return idx

    def get_global_node(idx):
        return GLOBAL_NODES[idx]


    def common_prefix_len(a,b):
        limit=min(len(a), len(b))
        i=0
        while i<limit and a[i] == b[i]:
            i+=1
        return i
       
   
    def call_log_append(ctype, node_id, field, val=""):
        def size():
            if field == "count":
                return math.log2(n)*0.1
            elif field == "id":
                return len(val) + math.log2(p)
            else:
                return math.log2(n)
        if ctype not in call_log:
            call_log[ctype] = {}
        c = call_log[ctype]
        if node_id not in c:
            c[node_id] = {}
        nd = c[node_id]
        nd[field] = nd[field] if field in nd else size()


    ################################################################
    # Simplified write_op for the global partial-match tree
    ################################################################
    def write_op(node_idx, bitstr, count=0, identifier="", parent=None, first_batch=False):
        node = get_global_node(node_idx)
        siblings, keys = {}, node.children.keys()
        for k1,k2 in zip(sorted(keys), sorted(keys,reverse=True)):
            siblings[k1] = k2
        # Here we read this node and two child identifiers (& compute the mean identifier size)

        first_visit = node_idx not in visited
        # Step 1: increment node.counter
        print("write_op.bitstr,id,cnt,n.cnt,n.cs,idx,n.d,first_visit = ", (bitstr, identifier, count, node.counter, node.children, f"idx={node_idx}", node.depth, first_visit)) if debug else None
        if first_visit:
            visited[node_idx] = node.counter
            node.counter += 1 if count == 0 else max(count,0)
            call_log_append("read", node_idx, "count") # counter
            call_log_append("write", node_idx, "count") # counter

        # If depth >= max_depth or node.identifier == "" => unify leftover as child
        if False and node.depth >= max_depth: # or identifier=="":
            px = common_prefix_len(identifier, bitstr)
            leftover = bitstr[px:]
            if leftover:
                best_px=0
                best_cid=None
                best_idx=-1
                for cid, cdx in node.children.items():
                    call_log_append("read",node_idx, "id", cid) #id
                    px2 = common_prefix_len(cid, leftover)
                    if px2> best_px:
                        best_px=px2
                        best_cid=cid
                        best_idx=cdx
                if best_px==0:
                    new_idx = new_global_node(leftover, node)
                    get_global_node(new_idx).counter = max(1,count)
                    node.children[leftover] = None # new_idx
                    #visited[new_idx] = True
                    call_log_append("write",node_idx, "identifier") # counter
                    print("write_op.best_idx, px, leftover.size, leftover, cids = ", best_idx, best_px, len(leftover), leftover, node.children) if debug else None
                    return node_idx, True
                else:
                    print("write_op.best_idx, px, leftover.size, leftover, cid, cnt, best.cnt = ", best_idx, best_px, len(leftover), leftover, best_cid, max(1,count), get_global_node(best_idx).counter if best_idx is not None else get_null_child_count(node, best_cid, GLOBAL_NODES)) if debug else None
                    if best_idx is None and best_px < len(leftover):
                        new_idx = new_global_node(best_cid, node)
                        visited[new_idx] = get_null_child_count(node,best_cid,GLOBAL_NODES)
                        get_global_node(new_idx).counter = max(1,count)
                        node.children[best_cid] = new_idx
                        call_log_append("write", new_idx, "count")
                        call_log_append("write", node_idx, "id", best_cid)
                        best_idx = new_idx
                        return new_idx, True

                    if best_idx is not None:
                        return write_op(best_idx, leftover, count,best_cid,node,first_batch)
            return node_idx, False

        # partial match with node.identifier
        px = common_prefix_len(identifier, bitstr)
        leftover_node = identifier[px:]
        leftover_str  = bitstr[px:]
        new_idx = None
        update = 0 if first_batch else node.counter-visited[node_idx] 

        # Step 2) if leftover_node != "" => create new child node
        if leftover_node != "" and px > 0: #identifier[:px] != "":
            pre_idx = new_global_node(identifier[:px], parent)
            pre_node = get_global_node(pre_idx)
            pre_node.children[leftover_node] = None if max(1,count)==node.counter/2 and len(node.children.items())==0 else node_idx
            pre_node.counter = node.counter+(0 if first_visit else max(1,count))
            visited[pre_idx]=visited[node_idx] if first_visit else node.counter 
            call_log_append("write", pre_idx, "count") # counter
            node.counter -= update if node.counter>update else 0 #TODO: hack 
            visited[node_idx] = node.counter
            ncount = 0
            if leftover_str != "":
                pre_node.children[leftover_str] = None
                ncount =get_null_child_count(pre_node,leftover_str,GLOBAL_NODES)
                if max(1,count) != ncount:
                    new_idx = new_global_node(leftover_str, node)
                    get_global_node(new_idx).counter = max(1,count)
                    print("node.update,cnt = ", update,pre_node.counter,node.counter)
                    pre_node.children[leftover_str] = new_idx
                    if node_idx in visited:
                        visited[new_idx] = ncount
                call_log_append("write", pre_idx, "id", leftover_str) # id
            #del visited[node_idx]
            new_idx = pre_idx
            node.identifier = leftover_node
            if not parent is None:
                if identifier in parent.children:
                    del parent.children[identifier]
                parent.children[identifier[:px]] = pre_idx # if v is None else v
                call_log_append("write", parent.node_id, "id", identifier[:px])
            print("write_op.nd.children, idx, cnt,pre.cnt,node.cnt,ncnt, nchild, leftover_node, parent, pre, id, update = ", (node.children, node_idx, max(1,count),pre_node.counter,node.counter,ncount, len(node.children.items()), leftover_node, None if parent is None else (parent.children,parent.node_id,parent.counter), (pre_node.children,pre_node.node_id,pre_node.counter), identifier, update)) if debug else None
            return new_idx, True

        # Step 3) if leftover_str != "", see if partial child => else new child => call write_op
        if leftover_str=="" and leftover_node=="": # and first_visit:
            all_null, ncid = True, ""
            # Case of node has null child where node & child counts diverge
            for cid,cdx in node.children.copy().items():
               all_null = all_null and cdx is None
               #ncid = cid if cdx is None else ncid
            cs = {}
            if all_null and len(node.children.items())>1:
                for cid,c_idx in node.children.copy().items():
                  if c_idx is None:
                    c_idx = new_global_node(cid, node)
                    node.counter -= update
                    get_global_node(c_idx).counter = get_null_child_count(node, cid, GLOBAL_NODES)
                    node.counter += update
                    cs[cid] = c_idx
                    call_log_append("write", c_idx, "count")
                    call_log_append("write", node_idx, "id", cid)
                node.children.update(cs)
                print("write_op.cid,ncs,nid,count = ", (cid, node.children,node.node_id,node.counter )) if debug else None
            return node_idx, False
        elif leftover_str!="":
            best_px2=0
            best_cid2=None
            best_idx2=-1
            for cid, cdx in node.children.items():
                px2 = common_prefix_len(cid, leftover_str)
                call_log_append("read", node_idx, "id", cid)
                if px2>best_px2:
                    best_px2= px2
                    best_cid2= cid
                    best_idx2= cdx
            if best_px2==0:
                node.children[leftover_str] = None
                ncount = get_null_child_count(node, leftover_str, GLOBAL_NODES)
                print("write_op.ncount,cnt=", (ncount, max(1,count)))
                if max(1,count) != ncount: # and max(1,count) != node.counter/len(node.children.items()): # and ncount != max(1,count): #len(node.children.items()) > 1 and max(1,count) != ncount:
                    new_idx = new_global_node(leftover_str, node)
                    get_global_node(new_idx).counter = max(1,count)
                    node.children[leftover_str] = new_idx
                    #if node_idx in visited:
                    visited[new_idx] = ncount
                    call_log_append("write", new_idx, "count")
                    call_log_append("write", node_idx, "id", leftover_str)
                    node_idx = new_idx
                print("write_op.nd.children, nchild, new_idx, leftover_str, cnt, n.cnt,ncnt = ", (node.children, len(node.children.items()), node_idx, leftover_str, count, node.counter,ncount)) if debug else None
                return node_idx, True
            else:
                ncount = 0
                if best_idx2 is None:
                    node.counter -= update
                    ncount = get_null_child_count(node,best_cid2,GLOBAL_NODES)
                    node.counter += update
                if best_idx2 is None and best_px2>0 and (leftover_str!=best_cid2 or ncount!=node.counter/2 and ncount != node.counter):
                    best_idx2 = new_global_node(best_cid2, node)
                    get_global_node(best_idx2).counter = ncount+ (max(1,count) if not first_batch else 0) #ncount #+ (0 if best_idx2 in visited else max(1,count))
                    node.children[best_cid2] = best_idx2
                    visited[best_idx2] = ncount
                    #if node_idx in visited:
                    #    visited[best_idx2] = ncount
                    print("write_op.best_idx2,best_px2,best_cid2,leftover_str,node.cnt,ncnt,cnt,update,vst = ", (best_idx2,best_px2,best_cid2,leftover_str,node.counter,ncount,get_global_node(best_idx2).counter,update,visited[node_idx])) if debug else None
                if best_idx2 is not None:
                    return write_op(best_idx2,leftover_str,count,best_cid2,node,first_batch)

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
            bs= format(val,'b').zfill(p)
            local_write(r, bs)
        return r

    def print_local_tree(node, prefix=""):
        # DFS on local partial-match nodes
        child_keys= sorted(node.children.keys())
        print(f"{prefix}[local] id='{node.identifier}' c={node.counter}, children={child_keys}")
        for cid in child_keys:
            cnd= node.children[cid]
            print_local_tree(cnd, prefix+"  ")

    def bfs_merge_local_into_global(local_root, global_root_idx, first_batch):
        global visited
        visited = {}
        queue= deque([[global_root_idx, "", local_root, False, 0]])
        while queue:
            size = len(queue)
            for _ in range(size):
                    [curr_idx, identifier, ln, copy, pcnt]= queue.popleft()
                    #if ln.identifier!="":
                    curr = get_global_node(curr_idx)
                    bitstr = identifier+ln.identifier
                    px = len(curr.path) - len(curr.identifier)
                    args = (identifier,curr.identifier,curr.node_id,curr.children,ln.identifier,px,len(identifier),curr.path,bitstr,bitstr[px:],copy,curr_idx in visited)
                    print("bfs_merge.id,curr.id,curr.nodeid,curr.cs,ln.id,px,id.len,path,bitstr,bitstr.px,cp,is_visited = ", args) if debug else None
                    #curr_idx, copy = write_op(curr_idx, bitstr[px:], ln.counter, curr.identifier)
                    count, cs = curr.counter, curr.children.copy()
                    if copy:
                        nxt_idx, copy = write_op(curr_idx, bitstr[px:], ln.counter, curr.identifier,pcnt, first_batch)
                    else:
                        nxt_idx, copy = write_op(curr_idx, bitstr[px:], ln.counter, curr.identifier,pcnt, first_batch)
                    nxt = get_global_node(nxt_idx)
                    #if len(ln.children.items()) and nxt_idx==curr_idx and nxt.children == cs:
                    #    print(f"decrementing {nxt_idx} by {ln.counter}")
                    #    nxt.counter -= ln.counter
                    #if nxt_idx not in visited:
                    #    visited[nxt_idx] = curr.counter - count if curr_idx==nxt_idx else nxt.counter
                    for cid,cnd in ln.children.items():
                        queue.append([nxt_idx,identifier+ln.identifier,cnd,copy,ln.counter])
        visited = {}

    # Build global tree
    GLOBAL_NODES.clear()
    call_log.clear()
    call_log = {"read.sum": 0, "read.len": 0, "write.sum": 0, "write.len": 0}
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


    # For each sorted batch => build local partial-match tree => BFS merge
    for batch_i, batch in enumerate(sorted_batches):
        print(f"\n--- BATCH {batch_i} of {len(sorted_batches)} => {batch[:20]}:{len(batch)} ---") if debug else None
        local_root= timed(lambda: build_local_tree(batch), "build_local_tree")
        # print the local tree
        print("Local Tree (DFS):") if debug else None
        print_local_tree(local_root) if debug else None
        timed(lambda: bfs_merge_local_into_global(local_root, root_idx, batch_i==0), "bfs_merge")
        print(f"\n==== Global Merge Tree(DFS order) {len(GLOBAL_NODES)} nodes ====") if debug else None
        ncnt = print_merge_tree_dfs(root_idx, GLOBAL_NODES) if debug else None
        print(f"==== Global Merge Tree(DFS order) {ncnt} actual nodes ====\n") if debug else None
        batch_mem += len(batch) * math.log2(n)*(0.2+1) * (math.log2(p)+(p/math.log2(n)))
        collect = lambda k,fn: sum([fn(log.values()) for _,log in list(filter(lambda e: not is_simple(e[0]), call_log[k].items()))])
        call_log["read.sum"] += collect("read", sum)
        call_log["write.sum"] += collect("write", sum)
        call_log["read.len"] += collect("read", len)
        call_log["write.len"] += collect("write", len)
        call_log["read"], call_log["write"] = {}, {}

    final_data= gather_data(root_idx)
    final_data_sorted= sorted(final_data)
    is_sorted= (final_data== final_data_sorted)
    return final_data, is_sorted, call_log, GLOBAL_NODES, root_idx, sorted(data)

def print_merge_tree_dfs(idx, global_nodes, identifier="", prefix="",parent="0"):
    node= global_nodes[idx]
    cnt = 1
    child_keys= sorted(node.children.items(), reverse=False)
    print(f"{prefix}[{idx}] id='{identifier}' c={node.counter} d={node.depth} children={child_keys} val={int(parent+identifier,2)}")
    for cid, c_idx in child_keys:
        if c_idx is None:
            c0 = get_null_child_count(node, cid, global_nodes)
            print(f"  {prefix}[{c_idx}] id='{cid}' c={c0} d={node.depth+1} children=None val={int(parent+identifier+cid,2)}")
        else:
            cnt += print_merge_tree_dfs(c_idx, global_nodes, cid, prefix+"  ", parent+identifier)
    return cnt


def plot_from_tuples(data_tuples, title="Graph", xlabel="X-axis", ylabel="Y-axis"):
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


def main(n_init=2**17):
    n=n_init
    p=2**5 # For illustration, short bits
    final_data, is_sorted, call_log, global_nodes, root_idx, sorted_data = run_bfs_merge(n, p)

    print(f"\nFinal data size: {len(final_data)} = 2**{math.log2(len(final_data))}")
    print(f"Is sorted? {is_sorted}")
    print(f"Is Equal? {sorted_data == final_data}")
    print(f"Final data: {final_data[:2**5]}:{len(final_data)}")

    sum_read = call_log["read.sum"] #sum([sum(n.values()) for n in call_log["read"].value()]) #sum(e["size"] for e in call_log if e["type"]=="read")
    sum_write = call_log["write.sum"] # sum([sum(n.values()) for n in call_log["write"].value()]) # sum(e["size"] for e in call_log if e["type"]=="write")
    read_count = call_log["read.len"] # sum([len(n.values()) for n in call_log["read"].value()]) #sum(1 for e in call_log if e["type"]=="read")
    write_count = call_log["write.len"] # sum([len(n.values()) for n in call_log["write"].value()]) #sum(1 for e in call_log if e["type"]=="write")
    total_calls = read_count + write_count

    print("\nOperation Summary:")
    print(f"  read calls total size:  {sum_read}")
    print(f"  write calls total size: {sum_write}")
    print(f"  combined total size:    {sum_read + sum_write}")
    print(f"  #read calls: {read_count}, #write calls: {write_count}, total calls: {total_calls}")
    print(f"  batch read/write memory size: {batch_mem}")

    b_eff = (n*p)/(sum_read+sum_write) if (sum_read+sum_write)>0 else 0
    print(f"\nb_eff = (n*p)/(sum_read + sum_write) = {b_eff:.4f}")
    print(f"\nb_eff_batch = (n*p)/(batch_mem) = {n*p}/{batch_mem} = {(n*p)/batch_mem:.4f}")

    print(f"\n==== Global Merge Tree(DFS order) {len(global_nodes)} nodes ====")
    ncnt = print_merge_tree_dfs(root_idx, global_nodes) if debug else None
    print(f"==== Global Merge Tree(DFS order) {ncnt} actual nodes ====\n") if debug else None
    return b_eff

if __name__=="__main__":
    timing_data = []
    for i in [4]: #7, 18, 19]: #, 20]:
        start=time()
        beff = main(n_init=2**i)
        print(f"i = {i}, b_eff = {beff}, Experiment n=2**{i}")
        timing_data.append((i, beff)) #(time()-start)*1000))
    plot_from_tuples(timing_data)
    print(timing_data)
