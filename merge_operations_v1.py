
import math
import random
from collections import deque

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
    data = [random.randint(0, 2**30) for _ in range(n)]
    print("data:", data[:2**5], ":", len(data))

    # Partition into sorted batches
    batch_size = 2**14
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
            self.children = []
            self.depth = depth

    GLOBAL_NODES = []
    call_log = []

    def compute_node_size(node):
        # node_size = counter_width + len(identifier) + (#children * log2(n))
        cwidth = 0.5*math.log2(n)
        iwidth = math.log2(p) + len(node.identifier)
        cf = int(len(node.children) * math.log2(n))
        return cwidth + iwidth + cf


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
    def write_op(node_idx, bitstr, count=0):
        node = get_global_node(node_idx)
        # Here we read this node and two child identifiers (& compute the mean identifier size)
        if count == 0:
            call_log.append({"type":"read","size":math.log(n,2)*0.5}) # counter
            call_log.append({"type":"write","size":math.log(n,2)*0.5}) # counter


        # Step 1: increment node.counter
        node.counter += 1 if count == 0 else max(count,0)
        #print("write_op.bitstr = ", (bitstr, node.identifier, node.counter))

        # If depth >= max_depth or node.identifier == "" => unify leftover as child
        if node.depth >= max_depth or node.identifier=="":
            px = common_prefix_len(node.identifier, bitstr)
            leftover = bitstr[px:]
            if leftover:
                best_px=0
                best_cid=None
                best_idx=-1
                #call_log.append({"type": "read","size": len(node.children)*(len(bitstr)+math.log2(p)+math.log2(n)-1)})
                call_log.append({"type": "read","size": len(node.children)*(len(bitstr)+math.log2(p))})
                for cdx in node.children:
                    cid = get_global_node(cdx).identifier
                    px2= common_prefix_len(cid, leftover)
                    if px2> best_px:
                        best_px=px2
                        best_cid=cid
                        best_idx=cdx
                if best_px==0:
                    new_idx= new_global_node(leftover,node.depth+1)
                    get_global_node(new_idx).counter = max(1,count)
                    node.children.append(new_idx)
                    call_log.append({"type": "write","size": math.log2(n)-1})
                    return new_idx
                else:
                    #leftover= leftover[best_px:]
                    return write_op(best_idx, leftover, count)
            return node_idx

        # partial match with node.identifier
        px = common_prefix_len(node.identifier, bitstr)
        leftover_node = node.identifier[px:]
        leftover_str  = bitstr[px:]
        #("leftover_node, _str", (leftover_node, leftover_str))

        # Step 2) if leftover_node != "" => create new child node
        if leftover_node!="":
            child_idx = new_global_node(leftover_node, node.depth+1)
            child_node= get_global_node(child_idx)
            # transfer old children + old counter
            child_node.children= node.children
            child_node.counter= max(0,node.counter - (1 if count == 0 else max(count,0)))
            node.children=[child_idx]
            #node.counter=max(1,count)
            child_node.identifier= leftover_node

            node.identifier= node.identifier[:px]
            call_log.append({"type": "write","size": math.log2(n)-1})
            #print("write_op.leftover_node = ", leftover_node)

        # Step 3) if leftover_str != "", see if partial child => else new child => call write_op
        if leftover_str!="":
            best_px2=0
            best_cid2=None
            best_idx2=-1
            #call_log.append({"type": "read","size": len(node.children)*(len(bitstr)+math.log(p,2)+math.log2(n)-1)})
            call_log.append({"type": "read","size": len(node.children)*(len(bitstr)+math.log(p,2))})
            for cdx in node.children:
                cid = get_global_node(cdx).identifier
                px2 = common_prefix_len(cid, leftover_str)
                if px2>best_px2:
                    best_px2= px2
                    best_cid2= cid
                    best_idx2= cdx
            if best_px2==0:
                new_idx= new_global_node(leftover_str,node.depth+1)
                get_global_node(new_idx).counter= max(1,count)
                node.children.append(new_idx)
                call_log.append({"type": "write","size": math.log2(n)-1})
                return new_idx
            else:
                #leftover_str= leftover_str[best_px2:]
                return write_op(best_idx2, leftover_str, count)

        return node_idx

    ################################################################
    # BFS merges from local partial-match trees
    ################################################################
    def gather_data(root_idx):
        results=[]
        def dfs(i, pre=""):
            nd= GLOBAL_NODES[i]
            if nd.identifier and len(nd.children)==0:
                #print("gather id = ", (pre,nd.identifier))
                val=int(pre+nd.identifier,2)
                results.extend([val]*nd.counter)
            else:
                pre += nd.identifier
            for cid,cx in sorted([(GLOBAL_NODES[cx].identifier,cx) for cx in nd.children]):
                dfs(cx, pre)
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
        queue= deque([[global_root_idx, local_root]])
        while queue:
            size= len(queue)
            for _ in range(size):
                [curr_idx, ln]= queue.popleft()
                if ln.identifier!="":
                    curr = get_global_node(curr_idx)
                    count = ln.counter #if curr.identifier=="" else -1
                    #print("local to write_op.id,curr.id,curr,children,count,lncount = ", ln.identifier, curr.identifier, curr_idx,[(c,get_global_node(c).counter) for c in curr.children], curr.counter,ln.counter)
                    curr_idx=write_op(curr_idx, curr.identifier+ln.identifier, count)
                for cid,cnd in ln.children.items():
                    queue.append([curr_idx, cnd])

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
        #print("Local Tree (DFS):")
        #print_local_tree(local_root)
        bfs_merge_local_into_global(local_root, root_idx)

    final_data= gather_data(root_idx)
    final_data_sorted= sorted(final_data)
    is_sorted= (final_data== final_data_sorted)
    return final_data, is_sorted, call_log, GLOBAL_NODES, root_idx, sorted(data)

def print_merge_tree_dfs(idx, global_nodes, prefix=""):
    node= global_nodes[idx]
    child_keys= sorted([(global_nodes[c].identifier,c) for c in node.children], reverse=True)
    print(f"{prefix}[{idx}] id='{node.identifier}' c={node.counter} d={node.depth} children={child_keys}")
    for cid, c_idx in child_keys:
        print_merge_tree_dfs(c_idx, global_nodes, prefix+"  ")

def main():
    n=2**20
    p=64  # For illustration, short bits
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

    #print("\n==== Global Merge Tree (DFS order) ====")
    #print_merge_tree_dfs(root_idx, global_nodes)

if __name__=="__main__":
    main()
