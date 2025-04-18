# This file is a part of Julia. License is MIT: https://julialang.org/license

# This file implements the Semi-NCA (SNCA) dominator tree construction
# described in Georgiadis' PhD thesis [LG05], which itself is a simplification
# of the Simple Lenguare-Tarjan (SLT) algorithm [LG79]. This algorithm matches
# the algorithm choice in LLVM and seems to be a sweet spot in implementation
# simplicity and efficiency.
#
# This file also implements an extension of SNCA that supports updating the
# dominator tree with insertion and deletion of edges in the control flow
# graph, described in [GI16] as Dynamic SNCA. DSNCA was chosen over DBS, a
# different algorithm which achieves the best overall performance in [GI16],
# because it is simpler to understand and implement, performs well with edge
# deletions, and is of similar performance overall.
#
# SNCA works by first computing semidominators, then computing immediate
# dominators from them. The semidominator of a node is the node with minimum
# preorder number such that there is a semidominator path from it to the node.
# A semidominator path is a path in which the preorder numbers of all nodes not
# at the endpoints are greater than the preorder number of the last node.
# Intuitively, the semidominator approximates the immediate dominator of a node
# by taking the path (in the CFG) that gets as close to the root as possible
# while avoiding ancestors of the node in the DFS tree.
#
# In computing the semidominators, SNCA performs "path compression" whenever a
# node has a nontrivial semidominator (i.e. a semidominator that is not just
# its parent in the DFS tree). Path compression propagates the "label" of a
# node, which represents a possible semidominator with associated semidominator
# path passing through that node.
#
# For example, path compression will be performed for the following CFG, where
# the edge not in the DFS tree is marked with asterisks. Note that nodes are
# labeled with their preorder numbers, and all edges point downward.
#
#     1
#     |\
#     | \
#     |  4
#     |  |
#     2  5
#     |  |
#     |  6
#     | *
#     |*
#     3
#
# There is a nontrivial semidominator path from 1 to 3, passing through 4, 5,
# and 6. Stepping through the whole algorithm on paper with an example like
# this is very helpful for understanding how it works.
#
# DSNCA runs the whole algorithm from scratch if the DFS tree is invalidated by
# the insertion or deletion, but otherwise recomputes a subset of the
# semidominators (all immediate dominators then need to be recomputed).
#
# [LG05]  Linear-Time Algorithms for Dominators and Related Problems
#         Loukas Georgiadis, Princeton University, November 2005, pp. 21-23:
#         ftp://ftp.cs.princeton.edu/reports/2005/737.pdf
#
# [LT79]  A fast algorithm for finding dominators in a flowgraph
#         Thomas Lengauer, Robert Endre Tarjan, July 1979, ACM TOPLAS 1-1
#         http://www.dtic.mil/dtic/tr/fulltext/u2/a054144.pdf
#
# [GI16]  An Experimental Study of Dynamic Dominators
#         Loukas Georgiadis, Giuseppe F. Italiano, Luigi Laura, Federico
#         Santaroni, April 2016
#         https://arxiv.org/abs/1604.02711

# We could make these real structs, but probably not worth the extra
# overhead. Still, give them names for documentary purposes.
const BBNumber = Int
const PreNumber = Int
const PostNumber = Int

struct DFSTree
    # These map between BB number and pre- or postorder numbers
    to_pre::Vector{PreNumber}
    from_pre::Vector{BBNumber}
    to_post::Vector{PostNumber}
    from_post::Vector{BBNumber}

    # Records parent relationships in the DFS tree
    # (preorder number -> preorder number)
    # Storing it this way saves a few lookups in the snca_compress! algorithm
    to_parent_pre::Vector{PreNumber}

    _worklist::Vector{Tuple{BBNumber, PreNumber, Bool}}
end

function DFSTree(n_blocks::Int)
    return DFSTree(zeros(PreNumber, n_blocks),
                   Vector{BBNumber}(undef, n_blocks),
                   zeros(PostNumber, n_blocks),
                   Vector{BBNumber}(undef, n_blocks),
                   zeros(PreNumber, n_blocks),
                   Vector{Tuple{BBNumber, PreNumber, Bool}}())
end

copy(D::DFSTree) = DFSTree(copy(D.to_pre),
                           copy(D.from_pre),
                           copy(D.to_post),
                           copy(D.from_post),
                           copy(D.to_parent_pre),
                           copy(D._worklist))

function copy!(dst::DFSTree, src::DFSTree)
    copy!(dst.to_pre, src.to_pre)
    copy!(dst.from_pre, src.from_pre)
    copy!(dst.to_post, src.to_post)
    copy!(dst.from_post, src.from_post)
    copy!(dst.to_parent_pre, src.to_parent_pre)
    return dst
end
function resize!(D::DFSTree, n::Integer)
    resize!(D.to_pre, n)
    resize!(D.from_pre, n)
    resize!(D.to_post, n)
    resize!(D.from_post, n)
    resize!(D.to_parent_pre, n)
end

length(D::DFSTree) = length(D.from_pre)

function DFS!(D::DFSTree, blocks::Vector{BasicBlock}, is_post_dominator::Bool)
    resize!(D, length(blocks))
    fill!(D.to_pre, 0)
    to_visit = D._worklist # always starts empty
    if is_post_dominator
        # TODO: We're using -1 as the virtual exit node here. Would it make
        #       sense to actually have a real BB for the exit always?
        push!(to_visit, (-1, 0, false))
    else
        push!(to_visit, (1, 0, false))
    end
    pre_num = is_post_dominator ? 0 : 1
    post_num = 1
    while !isempty(to_visit)
        # Because we want the postorder number as well as the preorder number,
        # we don't pop the current node from the stack until we're moving up
        # the tree
        (current_node_bb, parent_pre, pushed_children) = to_visit[end]

        if pushed_children
            # Going up the DFS tree, so all we need to do is record the
            # postorder number, then move on
            if current_node_bb != -1
                D.to_post[current_node_bb] = post_num
                D.from_post[post_num] = current_node_bb
            end
            post_num += 1
            pop!(to_visit)

        elseif current_node_bb != -1 && D.to_pre[current_node_bb] != 0
            # Node has already been visited, move on
            pop!(to_visit)
            continue
        else
            # Going down the DFS tree

            # Record preorder number
            if current_node_bb != -1
                D.to_pre[current_node_bb] = pre_num
                D.from_pre[pre_num] = current_node_bb
                D.to_parent_pre[pre_num] = parent_pre
            end

            # Record that children (will) have been pushed
            to_visit[end] = (current_node_bb, parent_pre, true)

            if is_post_dominator && current_node_bb == -1
                edges = Int[bb for bb in 1:length(blocks) if isempty(blocks[bb].succs)]
            else
                edges = is_post_dominator ? blocks[current_node_bb].preds :
                                            blocks[current_node_bb].succs
            end

            # Push children to the stack
            for succ_bb in edges
                if succ_bb == 0
                    # Edge 0 indicates an error entry, but shouldn't affect
                    # the post-dominator tree.
                    @assert is_post_dominator
                    continue
                end
                push!(to_visit, (succ_bb, pre_num, false))
            end

            pre_num += 1
        end
    end

    # If all blocks are reachable, this is a no-op, otherwise, we shrink these
    # arrays.
    resize!(D.from_pre, pre_num - 1)
    resize!(D.from_post, post_num - 1) # should be same size as pre_num - 1
    resize!(D.to_parent_pre, pre_num - 1)

    return D
end

DFS(blocks::Vector{BasicBlock}, is_post_dominator::Bool=false) = DFS!(DFSTree(0), blocks, is_post_dominator)

"""
Keeps the per-BB state of the Semi NCA algorithm. In the original formulation,
there are three separate length `n` arrays, `label`, `semi` and `ancestor`.
Instead, for efficiency, we use one array in an array-of-structs style setup.
"""
struct SNCAData
    semi::PreNumber
    label::PreNumber
end

"Represents a Basic Block, in the DomTree"
struct DomTreeNode
    # How deep we are in the DomTree
    level::Int
    # The BB indices in the CFG for all Basic Blocks we immediately dominate
    children::Vector{BBNumber}
end

DomTreeNode() = DomTreeNode(1, Vector{BBNumber}())

"Data structure that encodes which basic block dominates which."
struct GenericDomTree{IsPostDom}
    # These can be reused when updating domtree dynamically
    dfs_tree::DFSTree
    snca_state::Vector{SNCAData}

    # Which basic block immediately dominates each basic block, using BB indices
    idoms_bb::Vector{BBNumber}

    # The nodes in the tree (ordered by BB indices)
    nodes::Vector{DomTreeNode}
end
const DomTree = GenericDomTree{false}
const PostDomTree = GenericDomTree{true}

function (T::Type{<:GenericDomTree})()
    return T(DFSTree(0), SNCAData[], BBNumber[], DomTreeNode[])
end

function construct_domtree(blocks::Vector{BasicBlock})
    return update_domtree!(blocks, DomTree(), true, 0)
end

function construct_postdomtree(blocks::Vector{BasicBlock})
    return update_domtree!(blocks, PostDomTree(), true, 0)
end

function update_domtree!(blocks::Vector{BasicBlock}, domtree::GenericDomTree{IsPostDom},
                         recompute_dfs::Bool, max_pre::PreNumber) where {IsPostDom}
    if recompute_dfs
        DFS!(domtree.dfs_tree, blocks, IsPostDom)
    end

    if max_pre == 0
        max_pre = length(domtree.dfs_tree)
    end

    SNCA!(domtree, blocks, max_pre)
    compute_domtree_nodes!(domtree)
    return domtree
end

function compute_domtree_nodes!(domtree::GenericDomTree{IsPostDom}) where {IsPostDom}
    # Compute children
    copy!(domtree.nodes,
          DomTreeNode[DomTreeNode() for _ in 1:length(domtree.idoms_bb)])
    for (idx, idom) in Iterators.enumerate(domtree.idoms_bb)
        ((!IsPostDom && idx == 1) || idom == 0) && continue
        push!(domtree.nodes[idom].children, idx)
    end
    # n.b. now issorted(domtree.nodes[*].children) since idx is sorted above
    # Recursively set level
    if IsPostDom
        for (node, idom) in enumerate(domtree.idoms_bb)
            idom == 0 || continue
            update_level!(domtree.nodes, node, 1)
        end
    else
        update_level!(domtree.nodes, 1, 1)
    end
    return domtree.nodes
end

function update_level!(nodes::Vector{DomTreeNode}, node::BBNumber, level::Int)
    worklist = Tuple{BBNumber, Int}[(node, level)]
    while !isempty(worklist)
        (node, level) = pop!(worklist)
        nodes[node] = DomTreeNode(level, nodes[node].children)
        foreach(nodes[node].children) do child
            push!(worklist, (child, level+1))
        end
    end
end

dom_edges(domtree::DomTree, blocks::Vector{BasicBlock}, idx::BBNumber) =
    blocks[idx].preds
dom_edges(domtree::PostDomTree, blocks::Vector{BasicBlock}, idx::BBNumber) =
    blocks[idx].succs

"""
The main Semi-NCA algorithm. Matches Figure 2.8 in [LG05]. Note that the
pseudocode in [LG05] is not entirely accurate. The best way to understand
what's happening is to read [LT79], then the description of SLT in [LG05]
(warning: inconsistent notation), then the description of Semi-NCA.
"""
function SNCA!(domtree::GenericDomTree{IsPostDom}, blocks::Vector{BasicBlock}, max_pre::PreNumber) where {IsPostDom}
    D = domtree.dfs_tree
    state = domtree.snca_state
    # There may be more blocks than are reachable in the DFS / dominator tree
    n_blocks = length(blocks)
    n_nodes = length(D)

    # `label` is initialized to the identity mapping (though the paper doesn't
    # make that clear). The rationale for this is Lemma 2.4 in [LG05] (i.e.
    # Theorem 4 in [LT79]). Note however, that we don't ever look at `semi`
    # until it is fully initialized, so we could leave it uninitialized here if
    # we wanted to.
    resize!(state, n_nodes)
    for w in 1:max_pre
        # Only reset semidominators for nodes we want to recompute
        state[w] = SNCAData(typemax(PreNumber), w)
    end

    # If we are only recomputing some of the semidominators, the remaining
    # labels should be reset, because they may have become inapplicable to the
    # node/semidominator we are currently processing/recomputing. They can
    # become inapplicable because of path compressions that were triggered by
    # nodes that should only be processed after the current one (but were
    # processed the last time `SNCA!` was run).
    #
    # So, for every node that is not being reprocessed, we reset its label to
    # its semidominator, which is the value that its label assumes once its
    # semidominator is computed. If this was too conservative, i.e. if the
    # label would have been updated before we process the current node in a
    # situation where all semidominators were recomputed, then path compression
    # will produce the correct label.
    for w in max_pre+1:n_nodes
        semi = state[w].semi
        state[w] = SNCAData(semi, semi)
    end

    # Calculate semidominators, but only for blocks with preorder number up to
    # max_pre
    ancestors = copy(D.to_parent_pre)
    relevant_blocks = IsPostDom ? (1:max_pre) : (2:max_pre)
    for w::PreNumber in reverse(relevant_blocks)
        semi_w = ancestors[w]
        last_linked = PreNumber(w + 1)
        for v ∈ dom_edges(domtree, blocks, D.from_pre[w])
            # For the purpose of the domtree, ignore virtual predecessors into
            # catch blocks.
            v == 0 && continue

            v_pre = D.to_pre[v]

            # Ignore unreachable predecessors
            v_pre == 0 && continue

            # N.B.: This conditional is missing from the pseudocode in figure
            # 2.8 of [LG05]. It corresponds to the `ancestor[v] != 0` check in
            # the `eval` implementation in figure 2.6
            if v_pre >= last_linked
                # `v` has already been processed, so perform path compression

                # For performance, if the number of ancestors is small avoid
                # the extra allocation of the worklist.
                if length(ancestors) <= 32
                    snca_compress!(state, ancestors, v_pre, last_linked)
                else
                    snca_compress_worklist!(state, ancestors, v_pre, last_linked)
                end
            end

            # The (preorder number of the) semidominator of a block is the
            # minimum over the labels of its predecessors
            semi_w = min(semi_w, state[v_pre].label)
        end
        state[w] = SNCAData(semi_w, semi_w)
    end

    # Compute immediate dominators, which for a node must be the nearest common
    # ancestor in the (immediate) dominator tree between its semidominator and
    # its parent (see Lemma 2.6 in [LG05]).
    idoms_pre = copy(D.to_parent_pre)
    for v in (IsPostDom ? (1:n_nodes) : (2:n_nodes))
        idom = idoms_pre[v]
        vsemi = state[v].semi
        while idom > vsemi
            idom = idoms_pre[idom]
        end
        idoms_pre[v] = idom
    end

    # Express idoms in BB indexing
    resize!(domtree.idoms_bb, n_blocks)
    for i::BBNumber in 1:n_blocks
        if (!IsPostDom && i == 1) || D.to_pre[i] == 0
            domtree.idoms_bb[i] = 0
        else
            ip = idoms_pre[D.to_pre[i]]
            domtree.idoms_bb[i] = ip == 0 ? 0 : D.from_pre[ip]
        end
    end
end

"""
Matches the snca_compress algorithm in Figure 2.8 of [LG05], with the
modification suggested in the paper to use `last_linked` to determine whether
an ancestor has been processed rather than storing `0` in the ancestor array.
"""
function snca_compress!(state::Vector{SNCAData}, ancestors::Vector{PreNumber},
                        v::PreNumber, last_linked::PreNumber)
    u = ancestors[v]
    @assert u < v
    if u >= last_linked
        snca_compress!(state, ancestors, u, last_linked)
        if state[u].label < state[v].label
            state[v] = SNCAData(state[v].semi, state[u].label)
        end
        ancestors[v] = ancestors[u]
    end
    nothing
end

function snca_compress_worklist!(
        state::Vector{SNCAData}, ancestors::Vector{PreNumber},
        v::PreNumber, last_linked::PreNumber)
    # TODO: There is a smarter way to do this
    u = ancestors[v]
    worklist = Tuple{PreNumber, PreNumber}[(u,v)]
    @assert u < v
    while !isempty(worklist)
        u, v = last(worklist)
        if u >= last_linked
            if ancestors[u] >= last_linked
                push!(worklist, (ancestors[u], u))
                continue
            end
            if state[u].label < state[v].label
                state[v] = SNCAData(state[v].semi, state[u].label)
            end
            ancestors[v] = ancestors[u]
        end
        pop!(worklist)
    end
end

"Given updated blocks, update the given dominator tree with an inserted edge."
function domtree_insert_edge!(domtree::DomTree, blocks::Vector{BasicBlock},
                              from::BBNumber, to::BBNumber)
    # `from` is unreachable, so `from` and `to` aren't in domtree
    if bb_unreachable(domtree, from)
        return domtree
    end

    # Implements Section 3.1 of [GI16]
    dt        = domtree.dfs_tree
    from_pre  = dt.to_pre[from]
    to_pre    = dt.to_pre[to]
    from_post = dt.to_post[from]
    to_post   = dt.to_post[to]
    if to_pre == 0 || (from_pre < to_pre && from_post < to_post)
        # The DFS tree is invalidated by the edge insertion, so run from
        # scratch
        update_domtree!(blocks, domtree, true, 0)
    else
        # DFS tree is still valid, so update only affected nodes
        update_domtree!(blocks, domtree, false, to_pre)
    end

    return domtree
end

"Given updated blocks, update the given dominator tree with a deleted edge."
function domtree_delete_edge!(domtree::DomTree, blocks::Vector{BasicBlock},
                              from::BBNumber, to::BBNumber)
    # `from` is unreachable, so `from` and `to` aren't in domtree
    if bb_unreachable(domtree, from)
        return domtree
    end

    # Implements Section 3.1 of [GI16]
    if is_parent(domtree.dfs_tree, from, to)
        # The `from` block is the parent of the `to` block in the DFS tree, so
        # deleting the edge invalidates the DFS tree, so start from scratch
        update_domtree!(blocks, domtree, true, 0)
    elseif on_semidominator_path(domtree, from, to)
        # Recompute semidominators for blocks with preorder number up to that
        # of `to` block. Semidominators for blocks with preorder number greater
        # than that of `to` aren't affected because no semidominator path to
        # the block can pass through the `to` block (the preorder number of
        # `to` would be lower than those of these blocks, and `to` is not their
        # parent in the DFS tree).
        to_pre = domtree.dfs_tree.to_pre[to]
        update_domtree!(blocks, domtree, false, to_pre)
    end
    # Otherwise, dominator tree is not affected

    return domtree
end

"Check if x is the parent of y in the given DFS tree."
function is_parent(dfs_tree::DFSTree, x::BBNumber, y::BBNumber)
    x_pre = dfs_tree.to_pre[x]
    y_pre = dfs_tree.to_pre[y]
    return x_pre == dfs_tree.to_parent_pre[y_pre]
end

"""
Check if x is on some semidominator path from the semidominator of y to y,
assuming there is an edge from x to y.
"""
function on_semidominator_path(domtree::DomTree, x::BBNumber, y::BBNumber)
    x_pre = domtree.dfs_tree.to_pre[x]
    y_pre = domtree.dfs_tree.to_pre[y]

    semi_y = domtree.snca_state[y_pre].semi
    current_block = x_pre

    # Follow the semidominators of `x` up the DFS tree to see if we ever reach
    # the semidominator of `y`. If so, `x` is on a semidominator path between
    # `y` and its semidominator. We can stop if the preorder number of the
    # semidominators becomes less than that of the semidominator of `y`,
    # because it can only decrease further.
    while current_block >= semi_y
        if semi_y == current_block
            return true
        end
        current_block = domtree.snca_state[current_block].semi
    end
    return false
end

"""
Rename basic block numbers in a dominator tree, removing the block if it is
renamed to -1.
"""
function rename_nodes!(domtree::DomTree, rename_bb::Vector{BBNumber})
    # Rename DFS tree
    rename_nodes!(domtree.dfs_tree, rename_bb)

    # `snca_state` is indexed by preorder number, so should be unchanged

    # Rename `idoms_bb` and `nodes`
    old_idoms_bb = copy(domtree.idoms_bb)
    old_nodes = copy(domtree.nodes)
    for (old_bb, new_bb) in enumerate(rename_bb)
        if new_bb != -1
            domtree.idoms_bb[new_bb] = (new_bb == 1) ?
                0 : rename_bb[old_idoms_bb[old_bb]]
            domtree.nodes[new_bb] = old_nodes[old_bb]
            map!(i -> rename_bb[i],
                 domtree.nodes[new_bb].children,
                 domtree.nodes[new_bb].children)
        end
    end

    # length of `to_pre` after renaming DFS tree is new number of basic blocks
    resize!(domtree.idoms_bb, length(domtree.dfs_tree.to_pre))
    resize!(domtree.nodes, length(domtree.dfs_tree.to_pre))
    return domtree
end

"""
Rename basic block numbers in a DFS tree, removing the block if it is renamed
to -1.
"""
function rename_nodes!(D::DFSTree, rename_bb::Vector{BBNumber})
    n_blocks = length(D.to_pre)
    n_reachable_blocks = length(D.from_pre)

    old_to_pre = copy(D.to_pre)
    old_from_pre = copy(D.from_pre)
    old_to_post = copy(D.to_post)
    old_from_post = copy(D.from_post)
    max_new_bb = 0
    for (old_bb, new_bb) in enumerate(rename_bb)
        if new_bb != -1
            D.to_pre[new_bb] = old_to_pre[old_bb]
            D.from_pre[old_to_pre[old_bb]] = new_bb
            D.to_post[new_bb] = old_to_post[old_bb]
            D.from_post[old_to_post[old_bb]] = new_bb

            # Keep track of highest BB number to resize arrays with
            if new_bb > max_new_bb
                max_new_bb = new_bb
            end
        end
    end
    resize!(D.to_pre, max_new_bb)
    resize!(D.to_post, max_new_bb)
    # `to_parent_pre` should be unchanged
    return D
end

"""
    dominates(domtree::DomTree, bb1::Int, bb2::Int)::Bool

Checks if `bb1` dominates `bb2`.
`bb1` and `bb2` are indexes into the `CFG` blocks.
`bb1` dominates `bb2` if the only way to enter `bb2` is via `bb1`.
(Other blocks may be in between, e.g `bb1->bbx->bb2`).
"""
dominates(domtree::DomTree, bb1::BBNumber, bb2::BBNumber) =
    _dominates(domtree, bb1, bb2)

"""
    postdominates(domtree::PostDomTree, bb1::Int, bb2::Int)::Bool

Checks if `bb1` post-dominates `bb2`.
`bb1` and `bb2` are indexes into the `CFG` blocks.
`bb1` post-dominates `bb2` if every pass from `bb2` to the exit is via `bb1`.
(Other blocks may be in between, e.g `bb2->bbx->bb1->exit`).
"""
postdominates(domtree::PostDomTree, bb1::BBNumber, bb2::BBNumber) =
    _dominates(domtree, bb1, bb2)

function _dominates(domtree::GenericDomTree, bb1::BBNumber, bb2::BBNumber)
    bb1 == bb2 && return true
    target_level = domtree.nodes[bb1].level
    source_level = domtree.nodes[bb2].level
    source_level < target_level && return false
    for _ in (source_level - 1):-1:target_level
        bb2 = domtree.idoms_bb[bb2]
    end
    return bb1 == bb2
end

bb_unreachable(domtree::DomTree, bb::BBNumber) = bb != 1 && domtree.dfs_tree.to_pre[bb] == 0

"Iterable data structure that walks though all dominated blocks"
struct DominatedBlocks
    domtree::DomTree
    worklist::Vector{BBNumber}
end

"Returns an iterator that walks through all blocks dominated by the basic block at index `root`"
function dominated(domtree::DomTree, root::BBNumber)
    doms = DominatedBlocks(domtree, Vector{BBNumber}())
    push!(doms.worklist, root)
    doms
end

function iterate(doms::DominatedBlocks, state::Nothing=nothing)
    isempty(doms.worklist) && return nothing
    bb = pop!(doms.worklist)
    for dominated in doms.domtree.nodes[bb].children
        push!(doms.worklist, dominated)
    end
    return (bb, nothing)
end

"""
    nearest_common_dominator(domtree::GenericDomTree, a::BBNumber, b::BBNumber)

Compute the nearest common (post-)dominator of `a` and `b`.
"""
function nearest_common_dominator(domtree::GenericDomTree, a::BBNumber, b::BBNumber)
    a == 0 && return a
    b == 0 && return b
    alevel = domtree.nodes[a].level
    blevel = domtree.nodes[b].level
    # W.l.g. assume blevel <= alevel
    if alevel < blevel
        a, b = b, a
        alevel, blevel = blevel, alevel
    end
    while alevel > blevel
        a = domtree.idoms_bb[a]
        alevel -= 1
    end
    while a != b && a != 0
        a = domtree.idoms_bb[a]
        b = domtree.idoms_bb[b]
    end
    @assert a == b
    return a
end

function naive_idoms(blocks::Vector{BasicBlock}, is_post_dominator::Bool=false)
    nblocks = length(blocks)
    # The extra +1 helps us detect unreachable blocks below
    dom_all = BitSet(1:nblocks+1)
    dominators = is_post_dominator ?
        BitSet[isempty(blocks[n].succs) ? BitSet(n) : copy(dom_all) for n = 1:nblocks] :
        BitSet[n == 1 ? BitSet(1) : copy(dom_all) for n = 1:nblocks]
    changed = true
    relevant_blocks = (is_post_dominator ? (1:nblocks) : (2:nblocks))
    while changed
        changed = false
        for n in relevant_blocks
            edges = is_post_dominator ? blocks[n].succs : blocks[n].preds
            if isempty(edges)
                continue
            end
            firstp, rest = Iterators.peel(Iterators.filter(p->p != 0, edges))::NTuple{2,Any}
            new_doms = copy(dominators[firstp])
            for p in rest
                intersect!(new_doms, dominators[p])
            end
            push!(new_doms, n)
            changed = changed || (new_doms != dominators[n])
            dominators[n] = new_doms
        end
    end
    # Compute idoms
    idoms = fill(0, nblocks)
    for i in relevant_blocks
        if dominators[i] == dom_all
            idoms[i] = 0
            continue
        end
        doms = collect(dominators[i])
        for dom in doms
            i == dom && continue
            hasany = false
            for p in doms
                if p !== i && p !== dom && dom in dominators[p]
                    hasany = true; break
                end
            end
            hasany && continue
            idoms[i] = dom
        end
    end
    idoms
end
