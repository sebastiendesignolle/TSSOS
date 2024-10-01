mutable struct ccpop_data
    cpop # complex polynomial optimiztion problem
    z # complex variables
    n # number of all variables
    nb # number of binary variables
    m # number of all constraints
    numeq # number of equality constraints
    supp # support data
    coe # coefficient data
    basis # monomial bases
    hbasis # monomial bases for equality constraints
    rlorder # relaxation order
    ksupp # extended support at the k-th step
    cql # number of cliques
    cliquesize # numbers of cliques
    cliques # cliques of variables
    I # index sets of inequality constraints
    J # index sets of equality constraints
    ncc # constraints associated to no clique
    sb # sizes of different blocks
    numb # numbers of different blocks
    cl # numbers of blocks
    blocksize # sizes of blocks
    blocks # block structure
    eblocks # block structrue for equality constraints
    GramMat # Gram matrix
    moment # Moment matrix
    solver # SDP solver
    SDP_status
    tol # tolerance to certify global optimality
    flag # 0 if global optimality is certified; 1 otherwise
end

"""
    opt,sol,data = cs_tssos_first(pop, z, n, d; nb=0, numeq=0, CS="MF", cliques=[], TS="block", ipart=true, merge=false, md=3, 
    solver="Mosek", QUIET=false, solve=true, Gram=false, Mommat=false, MomentOne=false)

Compute the first TS step of the CS-TSSOS hierarchy for constrained complex polynomial optimization. 
If `merge=true`, perform the PSD block merging. 
If `ipart=false`, then use the real moment-HSOS hierarchy.
If `solve=false`, then do not solve the SDP.
If `Gram=true`, then output the Gram matrix.
If `Mommat=true`, then output the moment matrix.
If `MomentOne=true`, add an extra first order moment matrix to the moment relaxation.

# Input arguments
- `pop`: vector of the objective, inequality constraints, and equality constraints
- `z`: CPOP variables and their conjugate
- `n`: number of CPOP variables
- `d`: relaxation order
- `nb`: number of unit-norm variables in `x`
- `numeq`: number of equality constraints
- `CS`: method of chordal extension for correlative sparsity (`"MF"`, `"MD"`, `false`)
- `cliques`: the set of cliques used in correlative sparsity
- `TS`: type of term sparsity (`"block"`, `"signsymmetry"`, `"MD"`, `"MF"`, `false`)
- `md`: tunable parameter for merging blocks
- `normality`: normal order
- `QUIET`: run in the quiet mode (`true`, `false`)

# Output arguments
- `opt`: optimum
- `sol`: (near) optimal solution (if `solution=true`)
- `data`: other auxiliary data 
"""
function cs_tssos_first(pop::Vector{Polynomial{true, T}}, z, n, d; numeq=0, RemSig=false, nb=0, CS="MF", cliques=[], minimize=false, 
    TS="block", merge=false, md=3, solver="Mosek", reducebasis=false, QUIET=false, solve=true, tune=false, solution=false, ipart=true, 
    dualize=false, balanced=false, MomentOne=false, Gram=false, Mommat=false, cosmo_setting=cosmo_para(), mosek_setting=mosek_para(), 
    writetofile=false, normality=0, NormalSparse=false) where {T<:Number}
    ctype = ipart==true ? ComplexF64 : Float64
    supp,coe = polys_info(pop, z, n, ctype=ctype)
    if NormalSparse == true
        ss = get_signsymmetry([subs(poly, z[n+1:2n]=>z[1:n]) for poly in pop], z[1:n])
    else
        ss = false
    end
    opt,sol,data = cs_tssos_first(supp, coe, n, d, numeq=numeq, RemSig=RemSig, nb=nb, CS=CS, cliques=cliques, minimize=minimize,
    TS=TS, merge=merge, md=md, solver=solver, reducebasis=reducebasis, QUIET=QUIET, solve=solve, tune=tune, signsymmetry=ss, 
    solution=solution, ipart=ipart, dualize=dualize, balanced=balanced, MomentOne=MomentOne, Gram=Gram, Mommat=Mommat, 
    cosmo_setting=cosmo_setting, mosek_setting=mosek_setting, writetofile=writetofile, normality=normality, NormalSparse=NormalSparse, cpop=pop, z=z)
    return opt,sol,data
end

"""
    opt,sol,data = cs_tssos_first(supp::Vector{Vector{Vector{Vector{UInt16}}}}, coe::Vector{Vector{ComplexF64}},
    n, d; nb=0, numeq=0, CS="MF", cliques=[], TS="block", ipart=true, merge=false, md=3, solver="Mosek",
    QUIET=false, solve=true, Gram=false, Mommat=false, MomentOne=false)

Compute the first TS step of the CS-TSSOS hierarchy for constrained complex polynomial optimization. 
Here the complex polynomial optimization problem is defined by `supp` and `coe`, corresponding to the supports and coeffients of `pop` respectively.
"""
function cs_tssos_first(supp::Vector{Vector{Vector{Vector{UInt16}}}}, coe, n, d; numeq=0, RemSig=false, nb=0, CS="MF", cliques=[], 
    minimize=false, TS="block", merge=false, md=3, solver="Mosek", reducebasis=false, QUIET=false, solve=true, tune=false, solution=false, 
    ipart=true, dualize=false, balanced=false, MomentOne=false, Gram=false, Mommat=false, cosmo_setting=cosmo_para(), mosek_setting=mosek_para(), 
    writetofile=false, signsymmetry=false, normality=0, NormalSparse=false, cpop=nothing, z=nothing)
    println("*********************************** TSSOS ***********************************")
    println("TSSOS is launching...")
    if nb > 0
        supp[1],coe[1] = resort(supp[1], coe[1], nb=nb)
    end
    supp = copy(supp)
    coe = copy(coe)
    m = length(supp) - 1
    ind = [supp[1][i][1]<=supp[1][i][2] for i=1:length(supp[1])]
    supp[1] = supp[1][ind]
    coe[1] = coe[1][ind]
    dc = zeros(Int, m)
    for i = 1:m
        dc[i] = maximum([max(length(supp[i+1][j][1]), length(supp[i+1][j][2])) for j=1:length(supp[i+1])])
    end
    if cliques != []
        cql = length(cliques)
        cliquesize = length.(cliques)
    else
        time = @elapsed begin
        cliques,cql,cliquesize = clique_decomp(n, m, dc, supp, order=d, alg=CS, minimize=minimize)
        end
        if CS != false && QUIET == false
            mc = maximum(cliquesize)
            println("Obtained the variable cliques in $time seconds.\nThe maximal size of cliques is $mc.")
        end
    end
    I,J,ncc = assign_constraint(m, numeq, supp, cliques, cql)
    if d == "min"
        rlorder = [isempty(I[i]) && isempty(J[i]) ? 1 : maximum(dc[[I[i]; J[i]]]) for i = 1:cql]
    else
        rlorder = d*ones(Int, cql)
    end
    basis = Vector{Vector{Vector{Vector{UInt16}}}}(undef, cql)
    hbasis = Vector{Vector{Vector{Vector{Vector{UInt16}}}}}(undef, cql)
    for i = 1:cql
        basis[i] = Vector{Vector{Vector{UInt16}}}(undef, length(I[i])+1)
        hbasis[i] = Vector{Vector{Vector{Vector{UInt16}}}}(undef, length(J[i]))
        basis[i][1] = get_basis(cliques[i], rlorder[i])
        for s = 1:length(I[i])
            basis[i][s+1] = get_basis(cliques[i], rlorder[i]-dc[I[i][s]])
        end
        for s = 1:length(J[i])
            temp = get_basis(cliques[i], rlorder[i]-dc[J[i][s]])
            hbasis[i][s] = vec([[item1, item2] for item1 in temp, item2 in temp])
            if nb > 0
                hbasis[i][s] = reduce_unitnorm.(hbasis[i][s], nb=nb)
                unique!(hbasis[i][s])
            end
            sort!(hbasis[i][s])
        end
    end
    tsupp = copy(supp[1])
    for i = 2:m+1, j = 1:length(supp[i])
        if supp[i][j][1] <= supp[i][j][2]
            push!(tsupp, supp[i][j])
        end
    end
    sort!(tsupp)
    unique!(tsupp)
    if TS != false && QUIET == false
        println("Starting to compute the block structure...")
    end
    time = @elapsed begin
    blocks,eblocks,cl,blocksize,sb,numb,status = get_cblocks_mix(I, J, supp, cliques, cql, tsupp, basis, hbasis, TS=TS, balanced=balanced, merge=merge, md=md, nb=nb)
    if RemSig == true
        for i = 1:cql
            basis[i][1] = basis[i][1][union(blocks[i][1][blocksize[i][1] .> 1]...)]
        end
        tsupp = copy(supp[1])
        for i = 2:m+1, j = 1:length(supp[i])
            if supp[i][j][1] <= supp[i][j][2]
                push!(tsupp, supp[i][j])
            end
        end
        sort!(tsupp)
        unique!(tsupp)
        ind = [UInt16[] for i=1:cql]
        blocks,eblocks,cl,blocksize,sb,numb,status = get_cblocks_mix(I, J, supp, cliques, cql, tsupp, basis, hbasis, sb=ind, numb=ind, blocks=blocks, 
        eblocks=eblocks, cl=cl, blocksize=blocksize, TS=TS, balanced=balanced, merge=merge, md=md, nb=nb)
    end
    if reducebasis == true
        tsupp = get_gsupp(basis, hbasis, supp, cql, I, J, ncc, blocks, eblocks, cl, blocksize, norm=true)
        for i = 1:length(supp[1])
            if supp[1][i][1] == supp[1][i][2]
                push!(tsupp, supp[1][i][1])
            end
        end
        sort!(tsupp)
        unique!(tsupp)
        ltsupp = length(tsupp)
        flag = 0
        for i = 1:cql
            ind = [bfind(tsupp, ltsupp, basis[1][i][j]) !== nothing for j=1:length(basis[1][i])]
            if !all(ind)
                basis[1][i] = basis[1][i][ind]
                flag = 1
            end
        end
        if flag == 1
            tsupp = copy(supp[1])
            for i = 2:m+1, j = 1:length(supp[i])
                if supp[i][j][1] <= supp[i][j][2]
                    push!(tsupp, supp[i][j])
                end
            end
            sort!(tsupp)
            unique!(tsupp)
            blocks,eblocks,cl,blocksize,sb,numb,status = get_cblocks_mix(I, J, supp, cliques, cql, tsupp, basis, hbasis, blocks=blocks, 
            eblocks=eblocks, cl=cl, blocksize=blocksize, sb=sb, numb=numb, TS=TS, balanced=balanced, nb=nb, merge=merge, md=md)
        end
    end
    end
    if TS != false && QUIET == false
        mb = maximum(maximum.(sb))
        println("Obtained the block structure in $time seconds.\nThe maximal size of blocks is $mb.")
    end
    opt,ksupp,moment,GramMat,SDP_status = blockcpop_mix(n, m, rlorder, supp, coe, basis, hbasis, cliques, cql, cliquesize, I, J, ncc, blocks, eblocks, cl, blocksize,
    numeq=numeq, QUIET=QUIET, TS=TS, solver=solver, solve=solve, tune=tune, solution=solution, ipart=ipart, MomentOne=MomentOne, signsymmetry=signsymmetry, balanced=balanced,
    Gram=Gram, Mommat=Mommat, nb=nb, cosmo_setting=cosmo_setting, mosek_setting=mosek_setting, dualize=dualize, writetofile=writetofile, normality=normality, NormalSparse=NormalSparse)
    sol = nothing
    flag = 1
    if solution == true
        pop,x = complex_to_real(cpop, z)
        _,rsupp,rcoe = polys_info(pop, x)
        ub,sol,status = local_solution(2n, m, rsupp, rcoe, numeq=numeq, startpoint=rand(2n), QUIET=true)
        if status == MOI.LOCALLY_SOLVED
            gap = abs(opt-ub)/max(1, abs(ub))
            if gap < 1e-4
                flag = 0
                @printf "Global optimality certified with relative optimality gap %.6f%%!\n" 100*gap
            else
                @printf "Found a locally optimal solution by Ipopt, giving an upper bound: %.8f.\nThe relative optimality gap is: %.6f%%.\n" ub 100*gap
            end
        end
    end
    data = ccpop_data(cpop, z, n, nb, m, numeq, supp, coe, basis, hbasis, rlorder, ksupp, cql, cliquesize, cliques, I, J, ncc, sb, numb, cl, blocksize, blocks, eblocks, 
    GramMat, moment, solver, SDP_status, 1e-4, flag)
    return opt,sol,data
end

"""
    opt,sol,data = cs_tssos_higher!(data; TS="block", merge=false, md=3, QUIET=false, solve=true,
    solution=false, Gram=false, Mommat=false, MomentOne=false)

Compute higher TS steps of the CS-TSSOS hierarchy.
"""
function cs_tssos_higher!(data::ccpop_data; TS="block", merge=false, md=3, QUIET=false, solve=true, tune=false, solution=false, Gram=false, ipart=true, dualize=false, 
    balanced=false, MomentOne=false, Mommat=false, cosmo_setting=cosmo_para(), mosek_setting=mosek_para(), normality=0, NormalSparse=false)
    n = data.n
    nb = data.nb
    m = data.m
    numeq = data.numeq
    supp = data.supp
    coe = data.coe
    basis = data.basis
    hbasis = data.hbasis
    rlorder = data.rlorder
    ksupp = data.ksupp
    cql = data.cql
    cliques = data.cliques
    cliquesize = data.cliquesize
    I = data.I
    J = data.J
    ncc = data.ncc
    cl = data.cl
    blocksize = data.blocksize
    blocks = data.blocks
    eblocks = data.eblocks   
    sb = data.sb
    numb = data.numb
    solver = data.solver
    tol = data.tol
    if TS != false && QUIET == false
        println("Starting to compute the block structure...")
    end
    time = @elapsed begin
    blocks,eblocks,cl,blocksize,sb,numb,status = get_cblocks_mix(I, J, supp, cliques, cql, ksupp, basis, hbasis, blocks=blocks, eblocks=eblocks, cl=cl, 
    blocksize=blocksize, sb=sb, numb=numb, nb=nb, balanced=balanced, TS=TS, merge=merge, md=md)
    end
    opt = sol = nothing
    if status == 1
        if TS != false && QUIET == false
            mb = maximum(maximum.(sb))
            println("Obtained the block structure in $time seconds.\nThe maximal size of blocks is $mb.")
        end
        opt,ksupp,moment,GramMat,SDP_status = blockcpop_mix(n, m, rlorder, supp, coe, basis, hbasis, cliques, cql, cliquesize, I, J, ncc, blocks, eblocks, cl,
        blocksize, numeq=numeq, nb=nb, QUIET=QUIET, solver=solver, solve=solve, tune=tune, solution=solution, dualize=dualize, ipart=ipart, MomentOne=MomentOne, 
        Gram=Gram, Mommat=Mommat, cosmo_setting=cosmo_setting, mosek_setting=mosek_setting, balanced=balanced, normality=normality, NormalSparse=NormalSparse)
        if solution == true
            pop,x = complex_to_real(data.cpop, data.z)
            _,rsupp,rcoe = polys_info(pop, x)
            ub,sol,status = local_solution(2n, m, rsupp, rcoe, numeq=numeq, startpoint=rand(2n), QUIET=true)
            if status == MOI.LOCALLY_SOLVED
                gap = abs(opt-ub)/max(1, abs(ub))
                if gap < tol
                    data.flag = 0
                    @printf "Global optimality certified with relative optimality gap %.6f%%!\n" 100*gap
                else
                    @printf "Found a locally optimal solution by Ipopt, giving an upper bound: %.8f.\nThe relative optimality gap is: %.6f%%.\n" ub 100*gap
                end
            end
        end
        data.ksupp = ksupp
        data.blocks = blocks
        data.eblocks = eblocks
        data.cl = cl
        data.blocksize = blocksize
        data.GramMat = GramMat
        data.moment = moment
        data.sb = sb
        data.numb = numb
        data.SDP_status = SDP_status
    else
        println("No higher TS step of the CS-TSSOS hierarchy!")
    end
    return opt,sol,data
end

function polys_info(pop, z, n; ctype=ComplexF64)
    coe = Vector{Vector{ctype}}(undef, length(pop))
    supp = Vector{Vector{Vector{Vector{UInt16}}}}(undef, length(pop))
    for k in eachindex(pop)
        mon = MultivariatePolynomials.monomials(pop[k])
        coe[k] = MultivariatePolynomials.coefficients(pop[k])
        lm = length(mon)
        supp[k] = [[[], []] for i=1:lm]
        for i = 1:lm
            ind = mon[i].z .> 0
            vars = mon[i].vars[ind]
            exp = mon[i].z[ind]
            for j in eachindex(vars)
                l = ncbfind(z, 2n, vars[j])
                if l <= n
                    append!(supp[k][i][1], l*ones(UInt16, exp[j]))
                else
                    append!(supp[k][i][2], (l-n)*ones(UInt16, exp[j]))
                end
            end
        end
    end
    return supp,coe
end

function reduce_unitnorm(a; nb=0)
    a = [copy(a[1]), copy(a[2])]
    i = 1
    while i <= length(a[1])
        if length(a[2]) == 0
            return a
        end
        if a[1][i] <= nb
            loc = bfind(a[2], length(a[2]), a[1][i])
            if loc !== nothing
                deleteat!(a[1], i)
                deleteat!(a[2], loc)
            else
                i += 1
            end
        else
            return a
        end
    end
    return a
end

function get_gsupp(basis, hbasis, supp, cql, I, J, ncc, blocks, eblocks, cl, blocksize; norm=false, nb=0)
    if norm == true
        gsupp = Vector{UInt16}[]
    else
        gsupp = Vector{Vector{UInt16}}[]
    end
    for i = 1:cql
        for (j, w) in enumerate(I[i]), l = 1:cl[i][j+1], t = 1:blocksize[i][j+1][l], r = t:blocksize[i][j+1][l], s = 1:length(supp[w+1])
            ind1 = blocks[i][j+1][l][t]
            ind2 = blocks[i][j+1][l][r]
            @inbounds bi = [sadd(basis[i][j+1][ind1], supp[w+1][s][1]), sadd(basis[i][j+1][ind2], supp[w+1][s][2])]
            if nb > 0
                bi = reduce_unitnorm(bi, nb=nb)
            end
            if norm == true
                if bi[1] == bi[2]
                    push!(gsupp, bi[1])
                end
            else
                if bi[1] <= bi[2]
                    push!(gsupp, bi)
                else
                    push!(gsupp, bi[2:-1:1])
                end
            end
        end
        for (j, w) in enumerate(J[i]), k in eblocks[i][j], item in supp[w+1]
            @inbounds bi = [sadd(hbasis[i][j][k][1], item[1]), sadd(hbasis[i][j][k][2], item[2])]
            if nb > 0
                bi = reduce_unitnorm(bi, nb=nb)
            end
            if norm == true
                if bi[1] == bi[2]
                    push!(gsupp, bi[1])
                end
            else
                if bi[1] <= bi[2]
                    push!(gsupp, bi)
                else
                    push!(gsupp, bi[2:-1:1])
                end
            end
        end
    end
    for i ∈ ncc, j = 1:length(supp[i+1])
        if norm == true
            if supp[i+1][j][1] == supp[i+1][j][2]
                push!(gsupp, supp[i+1][j][1])
            end
        else
            if supp[i+1][j][1] <= supp[i+1][j][2]
                push!(gsupp, supp[i+1][j])
            end
        end
    end
    return gsupp
end

function blockcpop_mix(n, m, rlorder, supp::Vector{Vector{Vector{Vector{UInt16}}}}, coe, basis, hbasis, cliques, cql, cliquesize, I, J, ncc, blocks, eblocks, cl, blocksize; 
    numeq=0, nb=0, QUIET=false, TS="block", solver="Mosek", tune=false, solve=true, dualize=false, solution=false, Gram=false, MomentOne=false, ipart=true, Mommat=false, 
    cosmo_setting=cosmo_para(), mosek_setting=mosek_para(), writetofile=false, signsymmetry=false, balanced=false, normality=0, NormalSparse=false)
    tsupp = Vector{Vector{UInt16}}[]
    for i = 1:cql, j = 1:cl[i][1], k = 1:blocksize[i][1][j], r = k:blocksize[i][1][j]
        @inbounds bi = [basis[i][1][blocks[i][1][j][k]], basis[i][1][blocks[i][1][j][r]]]
        if nb > 0
            bi = reduce_unitnorm(bi, nb=nb)
        end
        if bi[1] <= bi[2]
            push!(tsupp, bi)
        else
            push!(tsupp, bi[2:-1:1])
        end
    end
    if TS != false
        gsupp = get_gsupp(basis, hbasis, supp, cql, I, J, ncc, blocks, eblocks, cl, blocksize, nb=nb)
        append!(tsupp, gsupp)
    end
    ksupp = copy(tsupp)
    if normality > 0
        if NormalSparse == true
            hyblocks = Vector{Vector{Vector{Vector{UInt16}}}}(undef, cql)
        end
        wbasis = Vector{Vector{Vector{UInt16}}}(undef, cql)
        for s = 1:cql
            wbasis[s] = get_basis(cliques[s], normality)
            bs = length(wbasis[s])
            if NormalSparse == true
                hyblocks[s] = Vector{Vector{Vector{UInt16}}}(undef, cliquesize[s])
            end
            for i = 1:cliquesize[s]
                if NormalSparse == true
                    G = SimpleGraph(2*bs)
                    for j = 1:bs, k = j:bs
                        bi = [wbasis[s][j], wbasis[s][k]]
                        if nb > 0
                            bi = reduce_unitnorm(bi, nb=nb)
                        end
                        sp = zeros(Int, n)
                        st = sign_type(sadd(bi[1], bi[2]))
                        sp[st] = ones(Int, length(st))
                        if (balanced == false || length(bi[1]) == length(bi[2])) && all(transpose(signsymmetry)*sp .== 0)
                            add_edge!(G, j, k)
                        end
                        bi = [sadd(wbasis[s][j], [cliques[s][i]]), sadd(wbasis[s][k], [cliques[s][i]])]
                        if nb > 0
                            bi = reduce_unitnorm(bi, nb=nb)
                        end
                        sp = zeros(Int, n)
                        st = sign_type(sadd(bi[1], bi[2]))
                        sp[st] = ones(Int, length(st))
                        if (balanced == false || length(bi[1]) == length(bi[2])) && all(transpose(signsymmetry)*sp .== 0)
                            add_edge!(G, j+bs, k+bs)
                        end
                    end
                    for j = 1:bs, k = 1:bs
                        bi = [sadd(wbasis[s][j], [cliques[s][i]]), wbasis[s][k]]
                        if nb > 0
                            bi = reduce_unitnorm(bi, nb=nb)
                        end
                        sp = zeros(Int, n)
                        st = sign_type(sadd(bi[1], bi[2]))
                        sp[st] = ones(Int, length(st))
                        if (balanced == false || length(bi[1]) == length(bi[2])) && all(transpose(signsymmetry)*sp .== 0)
                            add_edge!(G, j, k+bs)
                        end
                    end
                    hyblocks[s][i] = connected_components(G)
                    if normality >= rlorder[s] || TS == "block"
                        for t = 1:length(hyblocks[s][i]), j = 1:length(hyblocks[s][i][t]), k = j:length(hyblocks[s][i][t])
                            if hyblocks[s][i][t][j] <= bs && hyblocks[s][i][t][k] <= bs
                                bi = [wbasis[s][hyblocks[s][i][t][j]], wbasis[s][hyblocks[s][i][t][k]]]
                            elseif hyblocks[s][i][t][j] <= bs && hyblocks[s][i][t][k] > bs
                                bi = [sadd(wbasis[s][hyblocks[s][i][t][j]], [cliques[s][i]]), wbasis[s][hyblocks[s][i][t][k]-bs]]
                            else
                                bi = [sadd(wbasis[s][hyblocks[s][i][t][j]-bs], [cliques[s][i]]), sadd(wbasis[s][hyblocks[s][i][t][k]-bs], [cliques[s][i]])]
                            end
                            if nb > 0
                                bi = reduce_unitnorm(bi, nb=nb)
                            end
                            if bi[1] <= bi[2]
                                push!(tsupp, bi)
                            else
                                push!(tsupp, bi[2:-1:1])
                            end
                        end
                    end
                elseif normality >= rlorder[s] || TS == "block"
                    for j = 1:bs, k = j:bs
                        bi = [sadd(wbasis[s][j], [cliques[s][i]]), sadd(wbasis[s][k], [cliques[s][i]])]
                        if nb > 0
                            bi = reduce_unitnorm(bi, nb=nb)
                        end
                        if bi[1] <= bi[2]
                            push!(tsupp, bi)
                        else
                            push!(tsupp, bi[2:-1:1])
                        end
                    end
                    for j = 1:bs, k = 1:bs
                        bi = [sadd(wbasis[s][j], [cliques[s][i]]), wbasis[s][k]]
                        if nb > 0
                            bi = reduce_unitnorm(bi, nb=nb)
                        end
                        if bi[1] <= bi[2]
                            push!(tsupp, bi)
                        else
                            push!(tsupp, bi[2:-1:1])
                        end
                    end
                end
            end
        end
    end
    if (MomentOne == true || solution == true) && TS != false 
        for i = 1:cql, j = 1:cliquesize[i]
            push!(tsupp, [UInt16[], UInt16[cliques[i][j]]])
            for k = j+1:cliquesize[i]
                bi = [UInt16[cliques[i][j]], UInt16[cliques[i][k]]]
                if nb > 0
                    bi = reduce_unitnorm(bi, nb=nb)
                end
                push!(tsupp, bi)
            end
        end
    end
    sort!(tsupp)
    unique!(tsupp)
    if normality == 0 && (MomentOne == true || solution == true) && TS != false
        sort!(ksupp)
        unique!(ksupp)
    else
        ksupp = tsupp
    end
    objv = moment = GramMat = SDP_status= nothing
    if solve == true
        ltsupp = length(tsupp)
        if QUIET == false
            println("Assembling the SDP...")
        end
        if solver == "Mosek"
            if dualize == false
                model = Model(optimizer_with_attributes(Mosek.Optimizer, "MSK_DPAR_INTPNT_CO_TOL_PFEAS" => mosek_setting.tol_pfeas, "MSK_DPAR_INTPNT_CO_TOL_DFEAS" => mosek_setting.tol_dfeas, 
                "MSK_DPAR_INTPNT_CO_TOL_REL_GAP" => mosek_setting.tol_relgap, "MSK_DPAR_OPTIMIZER_MAX_TIME" => mosek_setting.time_limit))
            else
                model = Model(dual_optimizer(Mosek.Optimizer))
            end
            if tune == true
                set_optimizer_attributes(model,
                "MSK_DPAR_INTPNT_CO_TOL_MU_RED" => 1e-7,
                "MSK_DPAR_INTPNT_CO_TOL_INFEAS" => 1e-7,
                "MSK_DPAR_INTPNT_CO_TOL_REL_GAP" => 1e-7,
                "MSK_DPAR_INTPNT_CO_TOL_DFEAS" => 1e-7,
                "MSK_DPAR_INTPNT_CO_TOL_PFEAS" => 1e-7,
                "MSK_DPAR_INTPNT_CO_TOL_NEAR_REL" => 1e6,
                "MSK_IPAR_BI_IGNORE_NUM_ERROR" => 1,
                "MSK_DPAR_BASIS_TOL_X" => 1e-3,
                "MSK_DPAR_BASIS_TOL_S" => 1e-3,
                "MSK_DPAR_BASIS_REL_TOL_S" => 1e-5)
            end
        elseif solver == "COSMO"
            model = Model(optimizer_with_attributes(COSMO.Optimizer, "eps_abs" => cosmo_setting.eps_abs, "eps_rel" => cosmo_setting.eps_rel, "max_iter" => cosmo_setting.max_iter, "time_limit" => cosmo_setting.time_limit))
        elseif solver == "SDPT3"
            model = Model(optimizer_with_attributes(SDPT3.Optimizer))
        elseif solver == "SDPNAL"
            model = Model(optimizer_with_attributes(SDPNAL.Optimizer))
        else
            @error "The solver is currently not supported!"
            return nothing,nothing,nothing,nothing,nothing
        end
        set_optimizer_attribute(model, MOI.Silent(), QUIET)
        time = @elapsed begin
        rcons = [AffExpr(0) for i=1:ltsupp]
        if ipart == true
            icons = [AffExpr(0) for i=1:ltsupp]
        end
        if normality > 0
            for s = 1:cql
                bs = length(wbasis[s])
                for i = 1:cliquesize[s]
                    if NormalSparse == false
                        if ipart == true
                            hnom = @variable(model, [1:4bs, 1:4bs], PSD)
                        else
                            hnom = @variable(model, [1:2bs, 1:2bs], PSD)
                        end
                        for j = 1:bs, k = j:bs
                            bi = [wbasis[s][j], wbasis[s][k]]
                            if nb > 0
                                bi = reduce_unitnorm(bi, nb=nb)
                            end
                            if bi[1] <= bi[2]
                                Locb = bfind(tsupp, ltsupp, bi)
                                if bi[1] != bi[2] && ipart == true
                                    @inbounds add_to_expression!(icons[Locb], hnom[j,k+2bs]-hnom[k,j+2bs])
                                end
                            else
                                Locb = bfind(tsupp, ltsupp, bi[2:-1:1])
                                if ipart == true
                                    @inbounds add_to_expression!(icons[Locb], -1, hnom[j,k+2bs]-hnom[k,j+2bs])
                                end
                            end
                            if ipart == true
                                @inbounds add_to_expression!(rcons[Locb], hnom[j,k]+hnom[j+2bs,k+2bs])
                            else
                                @inbounds add_to_expression!(rcons[Locb], hnom[j,k])
                            end
                            bi = [sadd(wbasis[s][j], [cliques[s][i]]), sadd(wbasis[s][k], [cliques[s][i]])]
                            if nb > 0
                                bi = reduce_unitnorm(bi, nb=nb)
                            end
                            if bi[1] <= bi[2]
                                Locb = bfind(tsupp, ltsupp, bi)
                                if bi[1] != bi[2] && ipart == true
                                    @inbounds add_to_expression!(icons[Locb], hnom[j+bs,k+3bs]-hnom[k+bs,j+3bs])
                                end
                            else
                                Locb = bfind(tsupp, ltsupp, bi[2:-1:1])
                                if ipart == true
                                    @inbounds add_to_expression!(icons[Locb], -1, hnom[j+bs,k+3bs]-hnom[k+bs,j+3bs])
                                end
                            end
                            if ipart == true
                                @inbounds add_to_expression!(rcons[Locb], hnom[j+bs,k+bs]+hnom[j+3bs,k+3bs])
                            else
                                @inbounds add_to_expression!(rcons[Locb], hnom[j+bs,k+bs])
                            end
                        end
                        for j = 1:bs, k = 1:bs
                            bi = [sadd(wbasis[s][j], [cliques[s][i]]), wbasis[s][k]]
                            if nb > 0
                                bi = reduce_unitnorm(bi, nb=nb)
                            end
                            if bi[1] <= bi[2]
                                Locb = bfind(tsupp, ltsupp, bi)
                                if bi[1] != bi[2]
                                    if ipart == true
                                        @inbounds add_to_expression!(icons[Locb], hnom[j,k+3bs]-hnom[k+bs,j+2bs])
                                        @inbounds add_to_expression!(rcons[Locb], hnom[j,k+bs]+hnom[j+2bs,k+3bs])
                                    else
                                        @inbounds add_to_expression!(rcons[Locb], hnom[j,k+bs])
                                    end
                                else
                                    if ipart == true
                                        @inbounds add_to_expression!(rcons[Locb], 2, hnom[j,k+bs]+hnom[j+2bs,k+3bs])
                                    else
                                        @inbounds add_to_expression!(rcons[Locb], 2, hnom[j,k+bs])
                                    end
                                end
                            else
                                Locb = bfind(tsupp, ltsupp, bi[2:-1:1])
                                if ipart == true
                                    @inbounds add_to_expression!(icons[Locb], -1, hnom[j,k+3bs]-hnom[k+bs,j+2bs])
                                    @inbounds add_to_expression!(rcons[Locb], hnom[j,k+bs]+hnom[j+2bs,k+3bs])
                                else
                                    @inbounds add_to_expression!(rcons[Locb], hnom[j,k+bs])
                                end
                            end
                        end
                    else
                        for t = 1:length(hyblocks[s][i])
                            hbs = length(hyblocks[s][i][t])
                            if ipart == true
                                hnom = @variable(model, [1:2*hbs, 1:2*hbs], PSD)
                            else
                                hnom = @variable(model, [1:hbs, 1:hbs], PSD)
                            end
                            for j = 1:hbs, k = j:hbs
                                if hyblocks[s][i][t][j] <= bs && hyblocks[s][i][t][k] <= bs
                                    bi = [wbasis[s][hyblocks[s][i][t][j]], wbasis[s][hyblocks[s][i][t][k]]]
                                elseif hyblocks[s][i][t][j] <= bs && hyblocks[s][i][t][k] > bs
                                    bi = [sadd(wbasis[s][hyblocks[s][i][t][j]], [cliques[s][i]]), wbasis[s][hyblocks[s][i][t][k]-bs]]
                                else
                                    bi = [sadd(wbasis[s][hyblocks[s][i][t][j]-bs], [cliques[s][i]]), sadd(wbasis[s][hyblocks[s][i][t][k]-bs], [cliques[s][i]])]
                                end
                                if nb > 0
                                    bi = reduce_unitnorm(bi, nb=nb)
                                end
                                if bi[1] <= bi[2]
                                    Locb = bfind(tsupp, ltsupp, bi)
                                    if hyblocks[s][i][t][j] == hyblocks[s][i][t][k] || bi[1] != bi[2]
                                        if ipart == true
                                            @inbounds add_to_expression!(icons[Locb], hnom[j,k+hbs]-hnom[k,j+hbs])
                                            @inbounds add_to_expression!(rcons[Locb], hnom[j,k]+hnom[j+hbs,k+hbs])
                                        else
                                            @inbounds add_to_expression!(rcons[Locb], hnom[j,k])
                                        end
                                    else
                                        if ipart == true
                                            @inbounds add_to_expression!(icons[Locb], 2, hnom[j,k+hbs]-hnom[k,j+hbs])
                                            @inbounds add_to_expression!(rcons[Locb], 2, hnom[j,k]+hnom[j+hbs,k+hbs])
                                        else
                                            @inbounds add_to_expression!(rcons[Locb], 2, hnom[j,k])
                                        end
                                    end
                                else
                                    Locb = bfind(tsupp, ltsupp, bi[2:-1:1])
                                    if ipart == true
                                        @inbounds add_to_expression!(icons[Locb], -1, hnom[j,k+hbs]-hnom[k,j+hbs])
                                        @inbounds add_to_expression!(rcons[Locb], hnom[j,k]+hnom[j+hbs,k+hbs])
                                    else
                                        @inbounds add_to_expression!(rcons[Locb], hnom[j,k])
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        pos = Vector{Vector{Vector{Union{VariableRef,Symmetric{VariableRef}}}}}(undef, cql)
        for i = 1:cql
            if (MomentOne == true || solution == true) && TS != false
                bs = cliquesize[i] + 1
                if ipart == true
                    pos0 = @variable(model, [1:2*bs, 1:2*bs], PSD)
                else
                    pos0 = @variable(model, [1:bs, 1:bs], PSD)
                end
                for t = 1:bs, r = t:bs
                    if t == 1 && r == 1
                        bi = [UInt16[], UInt16[]]
                    elseif t == 1 && r > 1
                        bi = [UInt16[], UInt16[cliques[i][r-1]]]
                    else
                        bi = [UInt16[cliques[i][t-1]], UInt16[cliques[i][r-1]]]
                        if nb > 0
                            bi = reduce_unitnorm(bi, nb=nb)
                        end
                    end
                    Locb = bfind(tsupp, ltsupp, bi)
                    if ipart == true
                        @inbounds add_to_expression!(rcons[Locb], pos0[t,r]+pos0[t+bs,r+bs])
                        @inbounds add_to_expression!(icons[Locb], pos0[t,r+bs]-pos0[r,t+bs])
                    else
                        @inbounds add_to_expression!(rcons[Locb], pos0[t,r])
                    end
                end
            end
            pos[i] = Vector{Vector{Union{VariableRef,Symmetric{VariableRef}}}}(undef, 1+length(I[i]))
            pos[i][1] = Vector{Union{VariableRef,Symmetric{VariableRef}}}(undef, cl[i][1])
            for l = 1:cl[i][1]
                @inbounds bs = blocksize[i][1][l]
                if bs == 1
                    pos[i][1][l] = @variable(model, lower_bound=0)
                    @inbounds bi = [basis[i][1][blocks[i][1][l][1]], basis[i][1][blocks[i][1][l][1]]]
                    if nb > 0
                        bi = reduce_unitnorm(bi, nb=nb)
                    end
                    Locb = bfind(tsupp, ltsupp, bi)
                    @inbounds add_to_expression!(rcons[Locb], pos[i][1][l])
                else
                    if ipart == true
                        pos[i][1][l] = @variable(model, [1:2bs, 1:2bs], PSD)
                    else
                        pos[i][1][l] = @variable(model, [1:bs, 1:bs], PSD)
                    end
                    for t = 1:bs, r = t:bs
                        @inbounds ind1 = blocks[i][1][l][t]
                        @inbounds ind2 = blocks[i][1][l][r]
                        @inbounds bi = [basis[i][1][ind1], basis[i][1][ind2]]
                        if nb > 0
                            bi = reduce_unitnorm(bi, nb=nb)
                        end
                        if bi[1] <= bi[2]
                            Locb = bfind(tsupp, ltsupp, bi)
                            if ipart == true && bi[1] != bi[2]
                                @inbounds add_to_expression!(icons[Locb], pos[i][1][l][t,r+bs]-pos[i][1][l][r,t+bs])
                            end
                        else
                            Locb = bfind(tsupp, ltsupp, bi[2:-1:1])
                            if ipart == true
                                @inbounds add_to_expression!(icons[Locb], -1, pos[i][1][l][t,r+bs]-pos[i][1][l][r,t+bs])
                            end
                        end
                        if ipart == true
                            @inbounds add_to_expression!(rcons[Locb], pos[i][1][l][t,r]+pos[i][1][l][t+bs,r+bs])
                        else
                            @inbounds add_to_expression!(rcons[Locb], pos[i][1][l][t,r])
                        end
                    end
                end
            end
        end
        for i = 1:cql, (j, w) in enumerate(I[i])
            pos[i][j+1] = Vector{Union{VariableRef,Symmetric{VariableRef}}}(undef, cl[i][j+1])
            for l = 1:cl[i][j+1]
                bs = blocksize[i][j+1][l]
                if bs == 1
                    pos[i][j+1][l] = @variable(model, lower_bound=0)
                    ind = blocks[i][j+1][l][1]
                    for s = 1:length(supp[w+1])
                        @inbounds bi = [sadd(basis[i][j+1][ind], supp[w+1][s][1]), sadd(basis[i][j+1][ind], supp[w+1][s][2])]
                        if nb > 0
                            bi = reduce_unitnorm(bi, nb=nb)
                        end
                        if bi[1] <= bi[2]
                            Locb = bfind(tsupp, ltsupp, bi)
                            if ipart == true
                                @inbounds add_to_expression!(icons[Locb], imag(coe[w+1][s]), pos[i][j+1][l])
                            end
                            @inbounds add_to_expression!(rcons[Locb], real(coe[w+1][s]), pos[i][j+1][l])
                        end
                    end
                else
                    if ipart == true
                        pos[i][j+1][l] = @variable(model, [1:2bs, 1:2bs], PSD)
                    else
                        pos[i][j+1][l] = @variable(model, [1:bs, 1:bs], PSD)
                    end
                    for t = 1:bs, r = 1:bs
                        ind1 = blocks[i][j+1][l][t]
                        ind2 = blocks[i][j+1][l][r]
                        for s = 1:length(supp[w+1])
                            @inbounds bi = [sadd(basis[i][j+1][ind1], supp[w+1][s][1]), sadd(basis[i][j+1][ind2], supp[w+1][s][2])]
                            if nb > 0
                                bi = reduce_unitnorm(bi, nb=nb)
                            end
                            if bi[1] <= bi[2]
                                Locb = bfind(tsupp, ltsupp, bi)
                                if ipart == true
                                    @inbounds add_to_expression!(rcons[Locb], real(coe[w+1][s]), pos[i][j+1][l][t,r]+pos[i][j+1][l][t+bs,r+bs])
                                    @inbounds add_to_expression!(rcons[Locb], -imag(coe[w+1][s]), pos[i][j+1][l][t,r+bs]-pos[i][j+1][l][r,t+bs])
                                    if bi[1] != bi[2]
                                        @inbounds add_to_expression!(icons[Locb], imag(coe[w+1][s]), pos[i][j+1][l][t,r]+pos[i][j+1][l][t+bs,r+bs])
                                        @inbounds add_to_expression!(icons[Locb], real(coe[w+1][s]), pos[i][j+1][l][t,r+bs]-pos[i][j+1][l][r,t+bs])
                                    end
                                else
                                    @inbounds add_to_expression!(rcons[Locb], real(coe[w+1][s]), pos[i][j+1][l][t,r])
                                end
                            end
                        end
                    end
                end
            end
        end
        if numeq > 0
            free = Vector{Vector{Vector{VariableRef}}}(undef, cql)
            for i = 1:cql
                if !isempty(J[i])
                    free[i] = Vector{Vector{VariableRef}}(undef, length(J[i]))
                    for (j, w) in enumerate(J[i])
                        mons = hbasis[i][j][eblocks[i][j]]
                        temp = mons[[item[1] <= item[2] for item in mons]]
                        lb = length(temp)
                        if ipart == true
                            free[i][j] = @variable(model, [1:2*lb])
                        else
                            free[i][j] = @variable(model, [1:lb])
                        end
                        for k in eblocks[i][j], s = 1:length(supp[w+1])
                            @inbounds bi = [sadd(hbasis[i][j][k][1], supp[w+1][s][1]), sadd(hbasis[i][j][k][2], supp[w+1][s][2])]
                            if nb > 0
                                bi = reduce_unitnorm(bi, nb=nb)
                            end
                            if bi[1] <= bi[2]
                                Locb = bfind(tsupp, ltsupp, bi)
                                if hbasis[i][j][k][1] <= hbasis[i][j][k][2]
                                    loc = bfind(temp, lb, hbasis[i][j][k])
                                    tag = 1
                                    if hbasis[i][j][k][1] == hbasis[i][j][k][2]
                                        tag = 0
                                    end
                                else
                                    loc = bfind(temp, lb, hbasis[i][j][k][2:-1:1])
                                    tag = -1
                                end
                                if ipart == true
                                    @inbounds add_to_expression!(rcons[Locb], real(coe[w+1][s])*free[i][j][loc]-tag*imag(coe[w+1][s])*free[i][j][loc+lb])
                                    if bi[1] != bi[2]
                                        @inbounds add_to_expression!(icons[Locb], tag*real(coe[w+1][s])*free[i][j][loc+lb]+imag(coe[w+1][s])*free[i][j][loc])
                                    end
                                else
                                    @inbounds add_to_expression!(rcons[Locb], real(coe[w+1][s]), free[i][j][loc])
                                end
                            end
                        end
                    end
                end
            end
        end
        for i in ncc
            if i <= m-numeq
                pos0 = @variable(model, lower_bound=0)
            else
                pos0 = @variable(model)
            end
            for j = 1:length(supp[i+1])
                if supp[i+1][j][1] <= supp[i+1][j][2]
                    Locb = bfind(tsupp, ltsupp, supp[i+1][j])
                    if ipart == true
                        @inbounds add_to_expression!(icons[Locb], imag(coe[i+1][j]), pos0)
                    end
                    @inbounds add_to_expression!(rcons[Locb], real(coe[i+1][j]), pos0)
                end
            end
        end
        rbc = zeros(ltsupp)
        ncons = ltsupp
        itsupp = nothing
        if ipart == true
            ind = [item[1] != item[2] for item in tsupp]
            itsupp = tsupp[ind]
            icons = icons[ind]
            ibc = zeros(length(itsupp))
            ncons += length(itsupp)
        end
        if QUIET == false
            println("There are $ncons affine constraints.")
        end
        for i = 1:length(supp[1])
            Locb = bfind(tsupp, ltsupp, supp[1][i])
            if Locb === nothing
               @error "The monomial basis is not enough!"
               return nothing,ksupp,nothing,nothing,nothing
            else
               rbc[Locb] = real(coe[1][i])
               if ipart == true && supp[1][i][1] != supp[1][i][2]
                   Locb = bfind(itsupp, length(itsupp), supp[1][i])
                   ibc[Locb] = imag(coe[1][i])
               end
            end
        end
        @variable(model, lower)
        rcons[1] += lower
        @constraint(model, rcon[i=1:ltsupp], rcons[i]==rbc[i])
        if ipart == true
            @constraint(model, icon[i=1:length(itsupp)], icons[i]==ibc[i])
        end
        @objective(model, Max, lower)
        end
        if QUIET == false
            println("SDP assembling time: $time seconds.")
            println("Solving the SDP...")
        end
        time = @elapsed begin
        optimize!(model)
        end
        if QUIET == false
            println("SDP solving time: $time seconds.")
        end
        if writetofile != false
            write_to_file(dualize(model), writetofile)
        end
        SDP_status = termination_status(model)
        objv = objective_value(model)
        if SDP_status != MOI.OPTIMAL
           println("termination status: $SDP_status")
           status = primal_status(model)
           println("solution status: $status")
        end
        println("optimum = $objv")
        ctype = ipart==true ? ComplexF64 : Float64
        if Gram == true
            GramMat = Vector{Vector{Vector{Union{ctype,Matrix{ctype}}}}}(undef, cql)
            for i = 1:cql
                GramMat[i] = Vector{Vector{Union{ctype,Matrix{ctype}}}}(undef, 1+length(I[i]))
                for j = 1:1+length(I[i])
                    GramMat[i][j] = Vector{Union{ctype,Matrix{ctype}}}(undef, cl[i][j])
                    for l = 1:cl[i][j]
                        if ipart == true
                            bs = blocksize[i][j][l]
                            temp = value.(pos[i][j][l][1:bs,bs+1:2bs])
                            GramMat[i][j][l] = value.(pos[i][j][l][1:bs,1:bs]+pos[i][j][l][bs+1:2bs,bs+1:2bs]) + im*(temp-temp')
                        else
                            GramMat[i][j][l] = value.(pos[i][j][l])
                        end
                    end
                end
            end
        end
        if Mommat == true
            rmeasure = -dual.(rcon)
            imeasure = nothing
            if ipart == true
                imeasure = -dual.(icon)
            end
            moment = get_cmoment(rmeasure, imeasure, tsupp, itsupp, cql, blocks, cl, blocksize, basis, ipart=ipart, nb=nb)
        end
    end
    return objv,ksupp,moment,GramMat,SDP_status
end

function get_eblock(tsupp::Vector{Vector{Vector{UInt16}}}, hsupp::Vector{Vector{Vector{UInt16}}}, basis::Vector{Vector{Vector{UInt16}}}; nb=nb)
    ltsupp = length(tsupp)
    eblock = UInt16[]
    for (i,item) in enumerate(basis)
        flag = 0
        for temp in hsupp
            bi = [sadd(item[1], temp[1]), sadd(item[2], temp[2])]
            if nb > 0
                bi = reduce_unitnorm(bi, nb=nb)
            end
            if (bi[1] <= bi[2] && bfind(tsupp, ltsupp, bi) !== nothing) || (bi[1] > bi[2] && bfind(tsupp, ltsupp, bi[2:-1:1]) !== nothing)
                flag = 1
                break
            end
        end
        if flag == 1
            push!(eblock, i)
        end
    end
    return eblock
end

function get_cblocks(m, l, tsupp, supp::Vector{Vector{Vector{Vector{UInt16}}}}, basis, hbasis; blocks=[], eblocks=[], cl=[], blocksize=[], 
    sb=[], numb=[], nb=0, TS="block", balanced=false, QUIET=true, merge=false, md=3)
    if isempty(blocks)
        blocks = Vector{Vector{Vector{UInt16}}}(undef, m+1)
        eblocks = Vector{Vector{UInt16}}(undef, l)
        blocksize = Vector{Vector{UInt16}}(undef, m+1)
        cl = Vector{UInt16}(undef, m+1)
    end
    if TS == false
        for k = 1:m+1
            lb = length(basis[k])
            blocks[k] = [Vector(1:lb)]
            blocksize[k] = [lb]
            cl[k] = 1
        end
        for k = 1:l
            eblocks[k] = Vector(1:length(hbasis[k]))
        end
        status = 1
        nsb = Int.(blocksize[1])
        nnumb = [1]
    else
        G = get_graph(tsupp, basis[1], nb=nb, balanced=balanced)
        if TS == "block"
            blocks[1] = connected_components(G)
            blocksize[1] = length.(blocks[1])
            cl[1] = length(blocksize[1])
        else
            blocks[1],cl[1],blocksize[1] = chordal_cliques!(G, method=TS, minimize=false)
            if merge == true
                blocks[1],cl[1],blocksize[1] = clique_merge!(blocks[1], d=md, QUIET=true)
            end
        end
        nsb = sort(Int.(unique(blocksize[1])), rev=true)
        nnumb = [sum(blocksize[1].== i) for i in nsb]
        if isempty(sb) || nsb!=sb || nnumb!=numb
            status = 1
            if QUIET == false
                println("-----------------------------------------------------------------------------")
                println("The sizes of PSD blocks:\n$nsb\n$nnumb")
                println("-----------------------------------------------------------------------------")
            end
            for k = 1:m
                G = get_cgraph(tsupp, supp[k], basis[k+1], nb=nb, balanced=balanced)
                if TS == "block"
                    blocks[k+1] = connected_components(G)
                    blocksize[k+1] = length.(blocks[k+1])
                    cl[k+1] = length(blocksize[k+1])
                else
                    blocks[k+1],cl[k+1],blocksize[k+1] = chordal_cliques!(G, method=TS, minimize=false)
                    if merge == true
                        blocks[k+1],cl[k+1],blocksize[k+1] = clique_merge!(blocks[k+1], d=md, QUIET=true)
                    end
                end
            end
            for k = 1:l
                eblocks[k] = get_eblock(tsupp, supp[k+m], hbasis[k], nb=nb)
            end
        else
            status = 0
            if QUIET == false
                println("No higher TS step of the TSSOS hierarchy!")
            end
        end
    end
    return blocks,eblocks,cl,blocksize,nsb,nnumb,status
end

function get_cblocks_mix(I, J, supp::Vector{Vector{Vector{Vector{UInt16}}}}, cliques, cql, tsupp, basis, hbasis; blocks=[], eblocks=[], cl=[], 
    blocksize=[], sb=[], numb=[], TS="block", balanced=false, nb=0, merge=false, md=3)
    status = ones(Int, cql)
    if isempty(blocks)
        blocks = Vector{Vector{Vector{Vector{UInt16}}}}(undef, cql)
        eblocks = Vector{Vector{Vector{UInt16}}}(undef, cql)
        cl = Vector{Vector{UInt16}}(undef, cql)
        blocksize = Vector{Vector{Vector{UInt16}}}(undef, cql)
        sb = Vector{Vector{UInt16}}(undef, cql)
        numb = Vector{Vector{UInt16}}(undef, cql)
        for i = 1:cql
            blocks[i] = Vector{Vector{Vector{UInt16}}}(undef, length(I[i])+1)
            eblocks[i] = Vector{Vector{UInt16}}(undef, length(J[i]))
            cl[i] = Vector{UInt16}(undef, length(I[i])+1)
            blocksize[i] = Vector{Vector{UInt16}}(undef, length(I[i])+1)
            sb[i] = Vector{UInt16}(undef, length(I[i])+1)
            numb[i] = Vector{UInt16}(undef, length(I[i])+1)
            ksupp = TS == false ? nothing : tsupp[[issubset(union(tsupp[j][1], tsupp[j][2]), cliques[i]) for j in eachindex(tsupp)]]
            blocks[i],eblocks[i],cl[i],blocksize[i],sb[i],numb[i],status[i] = get_cblocks(length(I[i]), length(J[i]), ksupp, supp[[I[i]; J[i]].+1], basis[i], 
            hbasis[i], TS=TS, balanced=balanced, QUIET=true, merge=merge, md=md, nb=nb)
        end
    else
        for i = 1:cql
            ind = [issubset(union(tsupp[j][1], tsupp[j][2]), cliques[i]) for j in eachindex(tsupp)]
            blocks[i],eblocks[i],cl[i],blocksize[i],sb[i],numb[i],status[i] = get_cblocks(length(I[i]), length(J[i]), tsupp[ind], supp[[I[i]; J[i]].+1], basis[i], 
            hbasis[i], blocks=blocks[i], eblocks=eblocks[i], cl=cl[i], blocksize=blocksize[i], sb=sb[i], numb=numb[i], TS=TS, balanced=balanced, QUIET=true, merge=merge, md=md, nb=nb)
        end
    end
    return blocks,eblocks,cl,blocksize,sb,numb,maximum(status)
end

function assign_constraint(m, numeq, supp::Vector{Vector{Vector{Vector{UInt16}}}}, cliques, cql)
    I = [UInt32[] for i=1:cql]
    J = [UInt32[] for i=1:cql]
    ncc = UInt32[]
    for i = 1:m
        ind = findall(k->issubset(unique(reduce(vcat, [item[1] for item in supp[i+1]])), cliques[k]), 1:cql)
        if isempty(ind)
            push!(ncc, i)
        elseif i <= m - numeq
            push!.(I[ind], i)
        else
            push!.(J[ind], i)
        end
    end
    return I,J,ncc
end

function get_graph(tsupp::Vector{Vector{Vector{UInt16}}}, basis; nb=0, balanced=false)
    lb = length(basis)
    G = SimpleGraph(lb)
    ltsupp = length(tsupp)
    for i = 1:lb, j = i+1:lb
        if balanced == false || length(basis[i]) == length(basis[j])
            bi = [basis[i], basis[j]]
            if nb > 0
                bi = reduce_unitnorm(bi, nb=nb)
            end
            if bi[1] > bi[2]
                bi = bi[2:-1:1]
            end
            if bfind(tsupp, ltsupp, bi) !== nothing
                add_edge!(G, i, j)
            end
        end
    end
    return G
end

function get_cgraph(tsupp::Vector{Vector{Vector{UInt16}}}, supp, basis; nb=0, balanced=false)
    lb = length(basis)
    ltsupp = length(tsupp)
    G = SimpleGraph(lb)
    for i = 1:lb, j = i+1:lb
        if balanced == false || length(basis[i]) == length(basis[j])
            r = 1
            while r <= length(supp)
                bi = [sadd(basis[i], supp[r][1]), sadd(basis[j], supp[r][2])]
                if nb > 0
                    bi = reduce_unitnorm(bi, nb=nb)
                end
                if bi[1] > bi[2]
                    bi = bi[2:-1:1]
                end
                if bfind(tsupp, ltsupp, bi) !== nothing
                   break
                else
                    r += 1
                end
            end
            if r <= length(supp)
                add_edge!(G, i, j)
            end
        end
    end
    return G
end

function clique_decomp(n, m, dc, supp::Vector{Vector{Vector{Vector{UInt16}}}}; order="min", alg="MF", minimize=false)
    if alg == false
        cliques = [UInt16[i for i=1:n]]
        cql = 1
        cliquesize = [n]
    else
        G = SimpleGraph(n)
        for i = 1:m+1
            if order == "min" || i == 1 || order == dc[i-1]
                for j = 1:length(supp[i])
                    add_clique!(G, unique([supp[i][j][1];supp[i][j][2]]))
                end
            else
                temp = copy(supp[i][1][1])
                for j = 2:length(supp[i])
                    append!(temp, supp[i][j][1])
                end
                add_clique!(G, unique(temp))
            end
        end
        if alg == "NC"
            cliques,cql,cliquesize = max_cliques(G)
        else
            cliques,cql,cliquesize = chordal_cliques!(G, method=alg, minimize=minimize)
        end
    end
    uc = unique(cliquesize)
    sizes = [sum(cliquesize.== i) for i in uc]
    println("-----------------------------------------------------------------------------")
    println("The clique sizes of varibles:\n$uc\n$sizes")
    println("-----------------------------------------------------------------------------")
    return cliques,cql,cliquesize
end

function get_cmoment(rmeasure, imeasure, tsupp, itsupp, cql, blocks, cl, blocksize, basis; ipart=true, nb=0)
    moment = Vector{Vector{Matrix{Union{Float64,ComplexF64}}}}(undef, cql)
    for i = 1:cql
        moment[i] = Vector{Matrix{Union{Float64,ComplexF64}}}(undef, cl[i][1])
        for l = 1:cl[i][1]
            bs = blocksize[i][1][l]
            rtemp = zeros(Float64, bs, bs)
            if ipart == true
                itemp = zeros(Float64, bs, bs)
            end
            for t = 1:bs, r = t:bs
                ind1 = blocks[i][1][l][t]
                ind2 = blocks[i][1][l][r]
                bi = [basis[i][1][ind1], basis[i][1][ind2]]
                if nb > 0
                    bi = reduce_unitnorm(bi, nb=nb)
                end
                if ipart == true
                    if bi[1] < bi[2]
                        Locb = bfind(itsupp, length(itsupp), bi)
                        itemp[t,r] = imeasure[Locb]
                    elseif bi[1] > bi[2]
                        Locb = bfind(itsupp, length(itsupp), bi[2:-1:1])
                        itemp[t,r] = -imeasure[Locb]
                    end
                end
                if bi[1] <= bi[2]
                    Locb = bfind(tsupp, length(tsupp), bi)
                else
                    Locb = bfind(tsupp, length(tsupp), bi[2:-1:1])
                end
                rtemp[t,r] = rmeasure[Locb]
            end
            rtemp = (rtemp + rtemp')/2
            if ipart == true
                itemp = (itemp - itemp')/2
                moment[i][l] = rtemp - itemp*im
            else
                moment[i][l] = rtemp
            end
        end
    end
    return moment
end
