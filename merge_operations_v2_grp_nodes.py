import math
import random
from collections import deque


def get_null_child_count(nd, cid, global_nodes):
    ks = list(filter(lambda k: k!=cid, nd.children.keys()))
    v0 = nd.children[ks[0]] if len(ks)>0 else 0
    c0 = int(nd.counter/len(nd.children.items())) if v0 is None else global_nodes[v0].counter
    print("get_null_child_count.cs, cid, v0, c0, n.cnt, cnt, depth = ", (nd.children, cid, v0, c0, nd.counter, nd.counter-c0, nd.depth))
    return nd.counter - c0


visited = {}


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

    max_depth = p
    root_max_bits = p

    random.seed(42)
    data = [random.randint(0, 2**6) for _ in range(n)]
    print("data:", data[:2**5], ":", len(data))

    # Partition into sorted batches
    batch_size = 2**1
    sorted_batches = []
    i = 0
    while i < n:
        end = min(i + batch_size, n)
        chunk = data[i:end]
        chunk.sort()
        sorted_batches.append(chunk)
        i = end


    # Global partial-match node structure
    class MergeNode:
        __slots__ = ['identifier','counter','children','depth']
        def __init__(self, identifier="", depth=0):
            self.identifier = identifier
            self.counter = 0
            self.children = {}
            self.depth = depth

    GLOBAL_NODES = []
    call_log = []

    def compute_node_size(node):
        # node_size = counter_width + len(identifier) + (#children * log2(n))
        cwidth = 0.5*math.log2(n)
        #iwidth = math.log2(p) + len(node.identifier)
        cf = sum([math.log2(p) + len(k) + (math.log2(n)-1 if p else 0) for k,p in node.children.items()])
        return cwidth + cf


    def new_global_node(identifier, depth):
        # If root => cap bits (though we won't exceed p below)
        if depth == 0 and len(identifier) > root_max_bits:
            identifier = identifier[:root_max_bits]
        idx = len(GLOBAL_NODES)
        GLOBAL_NODES.append(MergeNode(identifier, depth))
        call_log.append({"type": "write","size": compute_node_size(GLOBAL_NODES[idx])})
        return idx

    def get_global_node(idx):
        return GLOBAL_NODES[idx]


    def common_prefix_len(a,b):
        limit=min(len(a), len(b))
        i=0
        while i<limit and a[i] == b[i]:
            i+=1
        return i

    ################################################################
    # Simplified write_op for the global partial-match tree
    ################################################################
    def write_op(node_idx, bitstr, count=0, identifier="", parent=None):
        node = get_global_node(node_idx)
        # Here we read this node and two child identifiers (& compute the mean identifier size)
        if count == 0:
            call_log.append({"type":"read","size":math.log(n,2)*0.5}) # counter
            call_log.append({"type":"write","size":math.log(n,2)*0.5}) # counter


        first_visit = node_idx not in visited
        # Step 1: increment node.counter
        print("write_op.bitstr,id,cnt,n.cnt,n.cs,idx,n.d,1st = ", (bitstr, identifier, count, node.counter, node.children, node_idx, node.depth, first_visit))
        if first_visit:
            node.counter += 1 if count == 0 else max(count,0)
            visited[node_idx] = True

        # If depth >= max_depth or node.identifier == "" => unify leftover as child
        if node.depth >= max_depth or identifier=="":
            px = common_prefix_len(identifier, bitstr)
            leftover = bitstr[px:]
            if leftover:
                best_px=0
                best_cid=None
                best_idx=-1
                call_log.append({"type": "read","size": len(node.children)*(len(bitstr)+math.log2(p))})
                for cid, cdx in node.children.items():
                    px2= common_prefix_len(cid, leftover)
                    if px2> best_px:
                        best_px=px2
                        best_cid=cid
                        best_idx=cdx
                if best_px==0:
                    new_idx = new_global_node(leftover,node.depth+1)
                    get_global_node(new_idx).counter = max(1,count)
                    node.children[leftover] = new_idx
                    visited[new_idx] = True
                    call_log.append({"type": "write","size": math.log2(n)-1})
                    return new_idx
                else:
                    print("write_op.best_idx, px, leftover.size, leftover, cid, cnt, best.cnt = ", best_idx, best_px, len(leftover), leftover, best_cid, max(1,count), get_global_node(best_idx).counter)
                    if best_idx is None and best_px < len(leftover):
                        new_idx = new_global_node(best_cid, node.depth+1)
                        get_global_node(new_idx).counter = max(1,count)
                        node.children[best_cid] = new_idx
                        visited[new_idx] = True
                        call_log.append({"type": "write","size":math.log2(n)-1})
                        #best_idx = new_idx
                        #return new_idx
                    if best_idx is not None:
                        return write_op(best_idx, leftover, count,best_cid,node)
            return node_idx

        # partial match with node.identifier
        px = common_prefix_len(identifier, bitstr)
        leftover_node = identifier[px:]
        leftover_str  = bitstr[px:]
        new_idx = None
        #("leftover_node, _str", (leftover_node, leftover_str))

        # Step 2) if leftover_node != "" => create new child node
        if leftover_node != "":
            pre_idx = new_global_node(identifier[:px], node.depth)
            pre_node = get_global_node(pre_idx)
            pre_node.children[leftover_node] = node_idx
            if leftover_str != "":
                pre_node.children[leftover_str] = None
                leftover_str = ""
            pre_node.counter = node.counter
            node.counter -= max(1,count) if first_visit else 0
            del visited[node_idx]
            visited[pre_idx] = True
            new_idx = pre_idx
            node.identifier = leftover_node
            if not parent is None:
                del parent.children[identifier]
                parent.children[identifier[:px]] = pre_idx # if v is None else v
            call_log.append({"type": "write","size": math.log2(p)})
            #new_idx = write_op(node_idx,identifier,count,identifier[:px],parent)
            print("write_op.nd.children, idx, cnt, nchild, leftover_node, parent, pre, id = ", node.children, node_idx, node.counter, len(node.children.items()), leftover_node, None if parent is None else parent.children, pre_node.children, identifier)

        # Step 3) if leftover_str != "", see if partial child => else new child => call write_op
        if leftover_str=="" and leftover_node=="" and first_visit:
            # TODO: handle case of node.count>1 && node has null child
            for cid,cdx in node.children.copy().items():
                if cdx is None:
                    c_idx=new_global_node(cid, node.depth+1)
                    get_global_node(c_idx).counter = node.counter-max(1,count) 
                    node.children[cid] = c_idx
                    print("write_op.cid,c_idx,count = ", (cid, c_idx,node.counter-max(1,count) ))
        elif leftover_str!="":
            best_px2=0
            best_cid2=None
            best_idx2=-1
            call_log.append({"type": "read","size": len(node.children)*(len(bitstr)+math.log(p,2))})
            for cid, cdx in node.children.items():
                px2 = common_prefix_len(cid, leftover_str)
                if px2>best_px2:
                    best_px2= px2
                    best_cid2= cid
                    best_idx2= cdx
            if best_px2==0:
                node.children[leftover_str] = None
                #node.counter -= max(1,count) if first_visit else 0
                #del visited[node_idx]
                print("write_op.nd.children, nchild, leftover_str, cnt, n.cnt = ", node.children, len(node.children.items()), leftover_str, count, node.counter)
                call_log.append({"type": "write","size": math.log2(p)+len(leftover_str)})
            else:
                if best_idx2 is None and len(leftover_str[:best_px2])>0:
                    c = node.children[best_cid2]
                    del node.children[best_cid2]
                    new_idx = new_global_node(leftover_str[:best_px2],node.depth+1)
                    nd = get_global_node(new_idx)
                    nd.counter = get_null_child_count(node, leftover_str[:best_px2], GLOBAL_NODES) - (max(1,count) if first_visit else 0) 
                    nd.children[best_cid2[best_px2:]] = c
                    node.children[leftover_str[:best_px2]] = new_idx
                    print("write_op.children, leftover_str, id,cid,cnt,n.cnt = ", (node.children, leftover_str[:best_px2], best_px2,best_cid2, count, node.counter))
                    return write_op(new_idx,leftover_str,count,leftover_str[:best_px2],node)
                if best_idx2 is not None:
                    return write_op(best_idx2,leftover_str,count,best_cid2,node)

        return node_idx if new_idx is None else new_idx

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

    def bfs_merge_local_into_global(local_root, global_root_idx):
        global visited
        visited = {}
        queue= deque([[global_root_idx, "", local_root]])
        while queue:
            size = len(queue)
            for _ in range(size):
                [curr_idx, identifier, ln]= queue.popleft()
                if ln.identifier!="":
                    #curr = get_global_node(curr_idx)
                    identifier = GLOBAL_NODES[curr_idx].identifier
                    cid = identifier
                    for k,v in GLOBAL_NODES[curr_idx].children.items():
                        if ln.identifier == k[:len(ln.identifier)]:
                            cid = k
                    print("merge.cid = ", cid)
                    nxt_idx = write_op(curr_idx, identifier+ln.identifier, ln.counter, identifier)
                    curr_id = GLOBAL_NODES[curr_idx].identifier
                    nxt_id = GLOBAL_NODES[nxt_idx].identifier
                    print("merge.curr,nxt,id,cnt,ln.id,nxtid,curr_id,cid = ", (curr_idx, nxt_idx, identifier, ln.counter, nxt_id, curr_id, cid))
                    for k,v in GLOBAL_NODES[nxt_idx].children.items():
                        print("merge.k,v = ", (k,v))
                        if nxt_id + k == cid:
                            print("merge.k,v,cid = ", (k,v,cid,GLOBAL_NODES[v].counter,ln.counter))
                            break
                    curr_idx = nxt_idx
                for cid,cnd in ln.children.items():
                    queue.append([curr_idx, cid, cnd])

    # Build global tree
    GLOBAL_NODES.clear()
    call_log.clear()
    root_idx= len(GLOBAL_NODES)
    GLOBAL_NODES.append(MergeNode("",0))

    # For each sorted batch => build local partial-match tree => BFS merge
    for batch_i, batch in enumerate(sorted_batches):
        print(f"\n--- BATCH {batch_i} of {len(sorted_batches)} => {batch[:20]}:{len(batch)} ---")
        local_root= build_local_tree(batch)
        # print the local tree
        print("Local Tree (DFS):")
        print_local_tree(local_root)
        bfs_merge_local_into_global(local_root, root_idx)
        print(f"\n==== Global Merge Tree(DFS order) {len(GLOBAL_NODES)} nodes ====")
        print_merge_tree_dfs(root_idx, GLOBAL_NODES)

    final_data= gather_data(root_idx)
    final_data_sorted= sorted(final_data)
    is_sorted= (final_data== final_data_sorted)
    return final_data, is_sorted, call_log, GLOBAL_NODES, root_idx, sorted(data)

def print_merge_tree_dfs(idx, global_nodes, identifier="", prefix="",parent="0"):
    node= global_nodes[idx]
    child_keys= sorted(node.children.items(), reverse=False)
    print(f"{prefix}[{idx}] id='{identifier}' c={node.counter} d={node.depth} children={child_keys} val={int(parent+identifier,2)}")
    for cid, c_idx in child_keys:
        if c_idx is None:
            c0 = get_null_child_count(node, cid, global_nodes)
            print(f"  {prefix}[{c_idx}] id='{cid}' c={c0} d={node.depth+1} children=None val={int(parent+identifier+cid,2)}")
        else:
            print_merge_tree_dfs(c_idx, global_nodes, cid, prefix+"  ", parent+identifier)

def main():
    n=2**2+2
    p=8  # For illustration, short bits
    final_data, is_sorted, call_log, global_nodes, root_idx, sorted_data = run_bfs_merge(n, p)

    print(f"\nFinal data size: {len(final_data)} = 2**{math.log2(len(final_data))}")
    print(f"Is sorted? {is_sorted}")
    print(f"Is Equal? {sorted_data == final_data}")
    print(f"Final data: {final_data[:2**5]}")

    sum_read  = sum(e["size"] for e in call_log if e["type"]=="read")
    sum_write = sum(e["size"] for e in call_log if e["type"]=="write")
    read_count  = sum(1 for e in call_log if e["type"]=="read")
    write_count = sum(1 for e in call_log if e["type"]=="write")
    total_calls = read_count + write_count

    print("\nOperation Summary:")
    print(f"  read calls total size:  {sum_read}")
    print(f"  write calls total size: {sum_write}")
    print(f"  combined total size:    {sum_read + sum_write}")
    print(f"  #read calls: {read_count}, #write calls: {write_count}, total calls: {total_calls}")

    b_eff = (n*p)/(sum_read+sum_write) if (sum_read+sum_write)>0 else 0
    print(f"\nb_eff = (n*p)/(sum_read + sum_write) = {b_eff:.4f}")

    print(f"\n==== Global Merge Tree(DFS order) {len(global_nodes)} nodes ====")
    print_merge_tree_dfs(root_idx, global_nodes)

if __name__=="__main__":
    main()
