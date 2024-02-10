"""
This file contains different versions of the difFUBAR_grid algorithm.
Including: the default difFUBAR_grid function as well as different speedup tricks related to it, i.e.,
combinations of implementations using parallelization and memoization. Also, it contains helper functions for these.
"""

function add_to_each_element(vec_of_vec, elems)
    return [vcat(v,[e]) for v in vec_of_vec for e in elems]
end

function generate_alpha_and_single_omega_grids(alphagrid, omegagrid, background_omega_grid, is_background)
    alpha_and_single_omega_grids = Dict()
    alphagrid_vectorized = [[a] for a in alphagrid]
    alpha_and_single_omega_grids["Omega"] = add_to_each_element(alphagrid_vectorized,omegagrid)
    if is_background
        alpha_and_single_omega_grids["OmegaBackground"] = add_to_each_element(alphagrid_vectorized,background_omega_grid)
    end
    return alpha_and_single_omega_grids
end

#This is the function that assigns models to branches
#Sometimes there will be the same number of tags as omegas, but sometimes there will be one more omega.
#Depending on whether there are any background branches (UNTESTED WITH NO BACKGROUND BRANCHES)
function N_Omegas_model_func(cached_model, tags,omega_vec,alpha,nuc_mat,F3x4, code)
    models = [cached_model(alpha,alpha*o,nuc_mat,F3x4, genetic_code = code) for o in omega_vec];
    return n::FelNode -> [models[model_ind(n.name,tags)]]
end

function Omega_model_func(cached_model,omega,alpha,nuc_mat,F3x4, code)
    model = cached_model(alpha,alpha*omega,nuc_mat,F3x4, genetic_code = code);
    return n::FelNode -> [model]
end

"""
    getpuresubclades(node::FelNode, tags::Vector{String}, pure_subclades=FelNode[])

- Should usually be called on the root of the tree. Traverses the tree recursively with a depth-first search to find roots of pure subclades, presuming that nodenames have been trailed with tags.
- To just get the pure subclades, one can run `pure_subclades, _, _ = getpuresubclades(tree, tags)`.

# Arguments
- `node`: The root of the search.
- `tags`: A vector of tags.
- `pure_subclades`: A vector of pure subclades. Defaults to an empty vector.

# Returns
- A tuple containing the vector of pure subclades, a boolean indicating whether the node is pure, and the index of the node's tag.
"""
function getpuresubclades(node::FelNode, tags::Vector{String}, pure_subclades=FelNode[])
    # Get the index of the node's tag
    tag_ind_of_node = model_ind(node.name, tags)

    # If the node is a leaf, it's pure
    if isleafnode(node)
        return pure_subclades, true, tag_ind_of_node
    end

    children_are_pure = Vector{Bool}()
    children_tag_inds = Vector{Int64}()

    for child in node.children
        pure_subclades, child_is_pure, tag_ind = getpuresubclades(child, tags, pure_subclades)
        push!(children_are_pure, child_is_pure)
        push!(children_tag_inds, tag_ind)
    end

    # Get the index of the node's first child's tag
    tag_ind_of_first_child = first(children_tag_inds)

    # This is the case where the subclade starting at node is pure
    if all(children_are_pure) && all(x == tag_ind_of_first_child for x in children_tag_inds)
        if tag_ind_of_node != tag_ind_of_first_child
            # The purity is broken at this node
            push!(pure_subclades, node)
            return pure_subclades, false, tag_ind_of_node
        end
        # The purity is not broken at this node
        return pure_subclades, true, tag_ind_of_node
    end

    # This is the case where some child has mixed tags or the children are pure with regards to different tags
    for (child_is_pure, child) in zip(children_are_pure, node.children)
        if !child_is_pure || isleafnode(child)
            # We don't want to push leaves into pure_subclades
            continue
        end
        push!(pure_subclades, child)
    end
    return pure_subclades, false, tag_ind_of_node
end

#Defines the grid used for inference.
function gridsetup(lb, ub, num_below_one, trin, tr)
    step = (trin(1.0) - trin(lb))/num_below_one
    return tr.(trin(lb):step:trin(ub))
end

#Initializes variables common to all grid versions of difFUBAR
function gridprep(tree, tags; verbosity = 1, foreground_grid = 6, background_grid = 4)
    tr(x) = 10^x-0.05
    trinv(x) =  log10(x+0.05)
    alphagrid = gridsetup(0.01, 13.0, foreground_grid, trinv, tr); 
    omegagrid = gridsetup(0.01, 13.0, foreground_grid, trinv, tr)
    background_omega_grid = gridsetup(0.05, 6.0, background_grid, trinv, tr) #Much coarser, because this isn't a target of inference
    length(background_omega_grid) * length(alphagrid) * length(omegagrid)^2

    num_groups = length(tags)
    is_background = maximum([model_ind(n.name, tags) for n in getnodelist(tree) if !isroot(n)]) > num_groups
    tensor_dims = 1+num_groups+is_background;
    
    codon_param_vec = [[a] for a in alphagrid]
    param_kinds = ["Alpha"]
    for g in 1:num_groups
        push!(param_kinds, "OmegaG$(g)")
        codon_param_vec = add_to_each_element(codon_param_vec,omegagrid)
    end
    if is_background
        push!(param_kinds, "OmegaBackground")
        codon_param_vec = add_to_each_element(codon_param_vec,background_omega_grid)
    end
    codon_param_vec;
    
    num_sites = tree.message[1].sites
    l = length(codon_param_vec)
    log_con_lik_matrix = zeros(l,num_sites);
    return log_con_lik_matrix, codon_param_vec, alphagrid, omegagrid, background_omega_grid, param_kinds, is_background, num_groups, num_sites
end

#Runs felsenstein! on a subgrid (an enumerated codon_param_vec chunk) and puts the results in log_con_lik_matrix. 
#Used in the parallel version.
function do_subgrid!(tree::FelNode, cached_model, cpv_chunk::Vector{Tuple{Int64, Vector{Float64}}}, tags::Vector{String}, GTRmat, F3x4_freqs, code, log_con_lik_matrix)
    # Note that cpv_chunk is already enumerated
    for (row_ind,cp) in cpv_chunk
        alpha = cp[1]
        omegas = cp[2:end]
        tagged_models = N_Omegas_model_func(cached_model, tags,omegas,alpha,GTRmat,F3x4_freqs, code)

        felsenstein!(tree,tagged_models)
        #This combine!() is needed because the current site_LLs function applies to a partition
        #And after a felsenstein pass, you don't have the eq freqs factored in.
        #We could make a version of log_likelihood() that returns the partitions instead of just the sum
        combine!.(tree.message,tree.parent_message)
        log_con_lik_matrix[row_ind,:] .= MolecularEvolution.site_LLs(tree.message[1]) #Check that these grab the scaling constants as well!
        #verbosity > 0 && if mod(row_ind,500)==1
        #    print(round(100*row_ind/length(codon_param_vec)),"% ")
        #    flush(stdout)
        #end
    end
end

#Same as above but adapted for the version that does both the tree-surgery memoization and parallelization.
function do_subgrid!(tree::FelNode, cached_model, cpv_chunk::Vector{Tuple{Int64, Vector{Float64}}}, idx::Int64, pure_subclades::Vector{FelNode}, nodelists::Vector{Vector{FelNode}}, cached_messages, cached_tag_inds, tags::Vector{String}, GTRmat, F3x4_freqs, code, log_con_lik_matrix)
    # Note that cpv_chunk is already enumerated
    for (row_ind,cp) in cpv_chunk
        alpha = cp[1]
        omegas = cp[2:end]
        tagged_models = N_Omegas_model_func(cached_model, tags,omegas,alpha,GTRmat,F3x4_freqs, code)

        for x in pure_subclades
            nodeindex = x.nodeindex
            # Get the local equivalent node to x
            y = nodelists[idx][nodeindex]
            y.message = cached_messages[nodeindex][(alpha, omegas[cached_tag_inds[nodeindex]])]
        end

        felsenstein!(tree,tagged_models)
        #This combine!() is needed because the current site_LLs function applies to a partition
        #And after a felsenstein pass, you don't have the eq freqs factored in.
        #We could make a version of log_likelihood() that returns the partitions instead of just the sum
        combine!.(tree.message,tree.parent_message)
        log_con_lik_matrix[row_ind,:] .= MolecularEvolution.site_LLs(tree.message[1]) #Check that these grab the scaling constants as well!
        #verbosity > 0 && if mod(row_ind,500)==1
        #    print(round(100*row_ind/length(codon_param_vec)),"% ")
        #    flush(stdout)
        #end
    end
end

#Precalculates and returns messages for a pure subclade for different alpha and omega pairs. Aso is short for "alpha and single omega". 
#Used in the version that does both the tree-surgery memoization and parallelization.
function get_messages_for_aso_pairs(pure_subclade::FelNode, cached_model, aso_chunk::SubArray{Vector{Float64}}, GTRmat, F3x4_freqs, code)
    cached_messages_x = Dict()
    for (alpha, omega) in aso_chunk
        model = Omega_model_func(cached_model,omega,alpha,GTRmat,F3x4_freqs,code)
        felsenstein!(pure_subclade, model)
        cached_messages_x[(alpha, omega)] = deepcopy(pure_subclade.message)
    end
    return cached_messages_x
end

function difFUBAR_grid_parallel(tree, tags, GTRmat, F3x4_freqs, code, log_con_lik_matrix, codon_param_vec, alphagrid, omegagrid, background_omega_grid, param_kinds, is_background, num_groups, num_sites; verbosity = 1, foreground_grid = 6, background_grid = 4)

    cached_models = [MG94_cacher(code) for _ = 1:Threads.nthreads()]
    trees = [tree, [deepcopy(tree) for _ = 1:(Threads.nthreads() - 1)]...]

    verbosity > 0 && println("Step 3: Calculating grid of $(length(codon_param_vec))-by-$(tree.message[1].sites) conditional likelihood values (the slowest step). Currently on:")

    cpv_chunks = Iterators.partition(enumerate(codon_param_vec), max(1, ceil(Int, length(codon_param_vec) / Threads.nthreads())))
    tasks = []
    for (i, cpv_chunk) in enumerate(cpv_chunks)
        # Spawn the task and add it to the array
        task = Threads.@spawn do_subgrid!(trees[i], cached_models[i], cpv_chunk, tags, GTRmat, F3x4_freqs, code, log_con_lik_matrix)
        push!(tasks, task)
    end

    # Wait for all tasks to finish
    foreach(wait, tasks)

    verbosity > 0 && println()

    con_lik_matrix = zeros(size(log_con_lik_matrix));
    site_scalers = maximum(log_con_lik_matrix, dims = 1);
    for i in 1:num_sites
        con_lik_matrix[:,i] .= exp.(log_con_lik_matrix[:,i] .- site_scalers[i])
    end

    return con_lik_matrix, log_con_lik_matrix, codon_param_vec, alphagrid, omegagrid, param_kinds
end

function difFUBAR_grid_treesurgery(tree, tags, GTRmat, F3x4_freqs, code, log_con_lik_matrix, codon_param_vec, alphagrid, omegagrid, background_omega_grid, param_kinds, is_background, num_groups, num_sites; verbosity = 1, foreground_grid = 6, background_grid = 4)
    MolecularEvolution.set_node_indices!(tree)
    cached_model = MG94_cacher(code)

    pure_subclades, _, _ = getpuresubclades(tree, tags)

    if length(pure_subclades) > 0
        alpha_and_single_omega_grids = generate_alpha_and_single_omega_grids(alphagrid, omegagrid, background_omega_grid, is_background)
    end

    cached_messages = Dict()
    cached_tag_inds = Dict()
    model_time = 0
    copy_time = 0
    
    for x in pure_subclades
        @time begin
            tag_ind_below = model_ind(x.children[1].name, tags)
            nodeindex = x.nodeindex
            cached_tag_inds[nodeindex] = tag_ind_below
            if tag_ind_below <= num_groups
                alpha_and_single_omega_grid = alpha_and_single_omega_grids["Omega"]
            else
                alpha_and_single_omega_grid = alpha_and_single_omega_grids["OmegaBackground"]
            end
            cached_messages[nodeindex] = Dict()
            parent = x.parent
            x.parent = nothing
            for (alpha, omega) in alpha_and_single_omega_grid
                model_time += @elapsed model = Omega_model_func(cached_model,omega,alpha,GTRmat,F3x4_freqs,code)
                felsenstein!(x, model)
                copy_time += @elapsed cached_messages[nodeindex][(alpha, omega)] = deepcopy(x.message)
            end
            x.parent = parent
            x.children = FelNode[]
        end
    end

    @time @show model_time copy_time Base.summarysize(cached_messages) / (1024^2) "mb" length(pure_subclades) Base.summarysize(cached_model) / (1024^2) "mb"
    #return pure_subclades, cached_messages, cached_tag_inds
    for (row_ind,cp) in enumerate(codon_param_vec)
        alpha = cp[1]
        omegas = cp[2:end]
        tagged_models = N_Omegas_model_func(cached_model,tags,omegas,alpha,GTRmat,F3x4_freqs, code)

        for x in pure_subclades
            nodeindex = x.nodeindex
            x.message = cached_messages[nodeindex][(alpha, omegas[cached_tag_inds[nodeindex]])]
        end

        felsenstein!(tree,tagged_models)
        #This combine!() is needed because the current site_LLs function applies to a partition
        #And after a felsenstein pass, you don't have the eq freqs factored in.
        #We could make a version of log_likelihood() that returns the partitions instead of just the sum
        combine!.(tree.message,tree.parent_message)

        log_con_lik_matrix[row_ind,:] .= MolecularEvolution.site_LLs(tree.message[1]) #Check that these grab the scaling constants as well!
        verbosity > 0 && if mod(row_ind,500)==1
            print(round(100*row_ind/length(codon_param_vec)),"% ")
            flush(stdout)
        end
    end

    verbosity > 0 && println()

    con_lik_matrix = zeros(size(log_con_lik_matrix));
    site_scalers = maximum(log_con_lik_matrix, dims = 1);
    for i in 1:num_sites
        con_lik_matrix[:,i] .= exp.(log_con_lik_matrix[:,i] .- site_scalers[i])
    end

    return con_lik_matrix, log_con_lik_matrix, codon_param_vec, alphagrid, omegagrid, param_kinds
end

function difFUBAR_grid_treesurgery_and_parallel(tree, tags, GTRmat, F3x4_freqs, code, log_con_lik_matrix, codon_param_vec, alphagrid, omegagrid, background_omega_grid, param_kinds, is_background, num_groups, num_sites; verbosity = 1, foreground_grid = 6, background_grid = 4)
    MolecularEvolution.set_node_indices!(tree)
    @time trees = [tree, [deepcopy(tree) for _ = 1:(Threads.nthreads() - 1)]...]
    cached_models = [MG94_cacher(code) for _ = 1:Threads.nthreads()]
    @time nodelists = [getnodelist(tree) for tree in trees]
    
    pure_subclades, _, _ = getpuresubclades(tree, tags)

    if length(pure_subclades) > 0
        alpha_and_single_omega_grids = generate_alpha_and_single_omega_grids(alphagrid, omegagrid, background_omega_grid, is_background)
    end

    cached_messages = Dict()
    cached_tag_inds = Dict()
    for x in pure_subclades
        tag_ind_below = model_ind(x.children[1].name, tags)
        nodeindex = x.nodeindex
        cached_tag_inds[nodeindex] = tag_ind_below
        if tag_ind_below <= num_groups
            alpha_and_single_omega_grid = alpha_and_single_omega_grids["Omega"]
        else
            alpha_and_single_omega_grid = alpha_and_single_omega_grids["OmegaBackground"]
        end

        parents = FelNode[]
        for nodelist in nodelists
            push!(parents, nodelist[nodeindex].parent)
            nodelist[nodeindex].parent = nothing
        end

        aso_chunks = Iterators.partition(alpha_and_single_omega_grid, max(1, ceil(Int, length(alpha_and_single_omega_grid) / Threads.nthreads())))
        tasks = []
        for (i, aso_chunk) in enumerate(aso_chunks)
            # Spawn the task and add it to the array
            task = Threads.@spawn get_messages_for_aso_pairs(nodelists[i][nodeindex], cached_models[i], aso_chunk, GTRmat, F3x4_freqs, code)
            push!(tasks, task)
        end

        # Wait for all tasks to finish and collect their return values
        @time chunks_of_cached_messages = [fetch(task) for task in tasks];

        # Merge all the returned Dicts, and put it in the big Dict of messages
        cached_messages[nodeindex] = merge(chunks_of_cached_messages...)

        for (nodelist, parent) in zip(nodelists, parents)
            nodelist[nodeindex].parent = parent
            nodelist[nodeindex].children = FelNode[]
        end
    end

    GC.gc()

    num_sites = tree.message[1].sites
    l = length(codon_param_vec)
    log_con_lik_matrix = zeros(l,num_sites);

    verbosity > 0 && println("Step 3: Calculating grid of $(length(codon_param_vec))-by-$(tree.message[1].sites) conditional likelihood values (the slowest step). Currently on:")

    cpv_chunks = Iterators.partition(enumerate(codon_param_vec), max(1, ceil(Int, length(codon_param_vec) / Threads.nthreads())))
    tasks = []
    for (i, cpv_chunk) in enumerate(cpv_chunks)
        # Spawn the task and add it to the array
        task = Threads.@spawn do_subgrid!(trees[i], cached_models[i], cpv_chunk, i, pure_subclades, nodelists, cached_messages, cached_tag_inds, tags, GTRmat, F3x4_freqs, code, log_con_lik_matrix)
        push!(tasks, task)
    end

    # Wait for all tasks to finish
    foreach(wait, tasks)

    verbosity > 0 && println()

    con_lik_matrix = zeros(size(log_con_lik_matrix));
    site_scalers = maximum(log_con_lik_matrix, dims = 1);
    for i in 1:num_sites
        con_lik_matrix[:,i] .= exp.(log_con_lik_matrix[:,i] .- site_scalers[i])
    end

    return con_lik_matrix, log_con_lik_matrix, codon_param_vec, alphagrid, omegagrid, param_kinds
end