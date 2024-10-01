mutable struct cpop_data
    n # number of variables
    nb # number of binary variables
    m # number of constraints
    numeq # number of equality constraints
    x # set of variables
    pop # polynomial optimization problem
    gb # Grobner basis
    leadsupp # leader terms of the Grobner basis
    supp # support data
    coe # coefficient data
    basis # monomial bases
    hbasis # monomial bases for equality constraints
    ksupp # extended support at the k-th step
    sb # sizes of different blocks
    numb # numbers of different blocks
    cl # numbers of blocks
    blocksize # sizes of blocks
    blocks # block structure for inequality constraints
    eblocks # block structrue for equality constraints
    GramMat # Gram matrix
    moment # Moment matrix
    solver # SDP solver
    SDP_status
    tol # tolerance to certify global optimality
    flag # 0 if global optimality is certified; 1 otherwise
end

"""
    opt,sol,data = tssos_first(pop, x, d; nb=0, numeq=0, quotient=true, basis=[],
    reducebasis=false, TS="block", merge=false, md=3, solver="Mosek", QUIET=false, solve=true,
    MomentOne=false, Gram=false, solution=false, tol=1e-4)

Compute the first TS step of the TSSOS hierarchy for constrained polynomial optimization.
If `quotient=true`, then exploit the quotient ring structure defined by the equality constraints.
If `merge=true`, perform the PSD block merging. 
If `solve=false`, then do not solve the SDP.
If `Gram=true`, then output the Gram matrix.
If `MomentOne=true`, add an extra first order moment matrix to the moment relaxation.

# Input arguments
- `pop`: vector of the objective, inequality constraints, and equality constraints
- `x`: POP variables
- `d`: relaxation order
- `nb`: number of binary variables in `x`
- `numeq`: number of equality constraints
- `TS`: type of term sparsity (`"block"`, `"signsymmetry"`, `"MD"`, `"MF"`, `false`)
- `md`: tunable parameter for merging blocks
- `normality`: impose the normality condtions (`true`, `false`)
- `QUIET`: run in the quiet mode (`true`, `false`)
- `tol`: relative tolerance to certify global optimality

# Output arguments
- `opt`: optimum
- `sol`: (near) optimal solution (if `solution=true`)
- `data`: other auxiliary data 
"""
function tssos_first(pop::Vector{Polynomial{true, T}}, x, d; nb=0, numeq=0, quotient=true, basis=[], reducebasis=false, TS="block", merge=false, md=3, solver="Mosek", 
    QUIET=false, solve=true, dualize=false, MomentOne=false, Gram=false, solution=false, tol=1e-4, cosmo_setting=cosmo_para(), mosek_setting=mosek_para(), normality=0, 
    NormalSparse=false) where {T<:Number}
    println("*********************************** TSSOS ***********************************")
    println("TSSOS is launching...")
    n = length(x)
    if nb > 0
        gb = x[1:nb].^2 .- 1
        for i in eachindex(pop)
            pop[i] = rem(pop[i], gb)
        end
    end
    if numeq > 0 && quotient == true
        cpop = copy(pop)
        gb = convert.(Polynomial{true,Float64}, cpop[end-numeq+1:end])
        cpop = cpop[1:end-numeq]
        if QUIET == false
            println("Starting to compute the Gröbner basis...")
            println("This might take much time. You can set quotient=false to close it.")
        end
        SemialgebraicSets.gröbnerbasis!(gb)
        cpop[1] = rem(cpop[1], gb)
        lead = leadingmonomial.(gb)
        llead = length(lead)
        leadsupp = zeros(UInt8, n, llead)
        for i = 1:llead, j = 1:n
            @inbounds leadsupp[j,i] = MultivariatePolynomials.degree(lead[i], x[j])
        end
    else
        cpop = pop
        gb = []
        leadsupp = []
    end
    ss = nothing
    if NormalSparse == true || TS == "signsymmetry"
        ss = get_signsymmetry(pop, x)
    end
    m = length(cpop) - 1
    coe = Vector{Vector{Float64}}(undef, m+1)
    supp = Vector{Array{UInt8,2}}(undef, m+1)
    for k = 1:m+1
        mons = MultivariatePolynomials.monomials(cpop[k])
        coe[k] = MultivariatePolynomials.coefficients(cpop[k])
        supp[k] = zeros(UInt8, n, length(mons))
        for i in eachindex(mons), j = 1:n
            @inbounds supp[k][j,i] = MultivariatePolynomials.degree(mons[i], x[j])
        end
    end
    isupp = reduce(hcat, supp)
    neq = isempty(gb) ? numeq : 0
    if basis == []
        basis = Vector{Array{UInt8,2}}(undef, m-neq+1)
        basis[1] = get_basis(n, d, nb=nb, lead=leadsupp)
        for k = 1:m-neq
            basis[k+1] = get_basis(n, d-Int(ceil(maxdegree(pop[k+1])/2)), nb=nb, lead=leadsupp)
        end
        hbasis = nothing
        if isempty(gb) && numeq > 0
            hbasis = Vector{Array{UInt8,2}}(undef, numeq)
            for k = 1:numeq
                hbasis[k] = get_basis(n, 2*d-maxdegree(pop[k+1+m-numeq]), nb=nb, lead=leadsupp)
            end
        end
    end
    tsupp = [isupp bin_add(basis[1], basis[1], nb)]
    tsupp = sortslices(tsupp, dims=2)
    tsupp = unique(tsupp, dims=2)
    if TS != false && QUIET == false
        println("Starting to compute the block structure...")
    end
    time = @elapsed begin
    blocks,eblocks,cl,blocksize,sb,numb,_ = get_cblocks(m-neq, neq, tsupp, supp[2:end], basis, hbasis, nb=nb, TS=TS, QUIET=QUIET, merge=merge, md=md, nv=n, signsymmetry=ss)
    if reducebasis == true && quotient == false
        gsupp = get_gsupp(n, m, numeq, supp, basis[2:end], hbasis, blocks[2:end], eblocks, cl[2:end], blocksize[2:end], nb=nb)
        psupp = [supp[1] zeros(UInt8,n)]
        psupp = [psupp gsupp]
        basis[1],flag = reducebasis!(psupp, basis[1], blocks[1], cl[1], blocksize[1], nb=nb)
        if flag == 1
            tsupp = [isupp bin_add(basis[1], basis[1], nb)]
            tsupp = sortslices(tsupp, dims=2)
            tsupp = unique(tsupp, dims=2)
            blocks,eblocks,cl,blocksize,sb,numb,_ = get_cblocks(m-numeq, numeq, tsupp, supp[2:end], basis, hbasis, nb=nb, TS=TS, QUIET=QUIET, merge=merge, md=md, nv=n, signsymmetry=ss)
        end
    end
    end
    if TS != false && QUIET == false
        mb = maximum(maximum.(sb))
        println("Obtained the block structure in $time seconds.\nThe maximal size of blocks is $mb.")
    end
    opt,ksupp,moment,momone,GramMat,SDP_status = blockcpop(n, m, supp, coe, basis, hbasis, blocks, eblocks, cl, blocksize, nb=nb, numeq=numeq, gb=gb, x=x, dualize=dualize, TS=TS,
    lead=leadsupp, solver=solver, QUIET=QUIET, solve=solve, solution=solution, MomentOne=MomentOne, Gram=Gram, cosmo_setting=cosmo_setting, mosek_setting=mosek_setting, 
    signsymmetry=ss, normality=normality, NormalSparse=NormalSparse)
    data = cpop_data(n, nb, m, numeq, x, pop, gb, leadsupp, supp, coe, basis, hbasis, ksupp, sb, numb, cl, blocksize, blocks, eblocks, GramMat, moment, solver, SDP_status, tol, 1)
    sol = nothing
    if solution == true
        sol,gap,data.flag = extract_solution(momone, opt, pop, x, numeq=numeq, tol=tol)
        if data.flag == 1
            sol = gap > 0.5 ? randn(n) : sol
            sol,data.flag = refine_sol(opt, sol, data, QUIET=true, tol=tol)
        end
    end
    return opt,sol,data
end

function tssos_higher!(data::cpop_data; TS="block", merge=false, md=3, QUIET=false, solve=true, dualize=false, MomentOne=false, Gram=false,
    solution=false, cosmo_setting=cosmo_para(), mosek_setting=mosek_para(), normality=false, NormalSparse=false)
    n = data.n
    nb = data.nb
    m = data.m
    numeq = data.numeq
    x = data.x
    pop = data.pop
    gb = data.gb
    leadsupp = data.leadsupp
    supp = data.supp
    coe = data.coe
    basis = data.basis
    hbasis = data.hbasis
    ksupp = data.ksupp
    sb = data.sb
    numb = data.numb
    blocks = data.blocks
    eblocks = data.eblocks
    cl = data.cl
    blocksize = data.blocksize
    solver = data.solver
    tol = data.tol
    ksupp = sortslices(ksupp, dims=2)
    ksupp = unique(ksupp, dims=2)
    if QUIET == false
        println("Starting to compute the block structure...")
    end
    time = @elapsed begin
    neq = isempty(gb) ? numeq : 0
    blocks,eblocks,cl,blocksize,sb,numb,status = get_cblocks(m-neq, neq, ksupp, supp[2:end], basis, hbasis, blocks=blocks, eblocks=eblocks, cl=cl, 
    blocksize=blocksize, sb=sb, numb=numb, nb=nb, TS=TS, QUIET=QUIET, merge=merge, md=md)
    end
    opt = nothing
    sol = nothing
    if status == 1
        if QUIET == false
            mb = maximum(maximum.(sb))
            println("Obtained the block structure in $time seconds.\nThe maximal size of blocks is $mb.")
        end
        opt,ksupp,moment,momone,GramMat,SDP_status = blockcpop(n, m, supp, coe, basis, hbasis, blocks, eblocks, cl, blocksize, nb=nb, numeq=numeq, gb=gb, x=x, lead=leadsupp, TS=TS,
        solver=solver, QUIET=QUIET, solve=solve, dualize=dualize, solution=solution, MomentOne=MomentOne, Gram=Gram, cosmo_setting=cosmo_setting, mosek_setting=mosek_setting, 
        normality=normality, NormalSparse=NormalSparse)
        if solution == true
            sol,gap,data.flag = extract_solution(momone, opt, pop, x, numeq=numeq, tol=tol)
            if data.flag == 1
                sol = gap > 0.5 ? randn(n) : sol
                sol,data.flag = refine_sol(opt, sol, data, QUIET=true, tol=tol)
            end
        end
        data.ksupp = ksupp
        data.sb = sb
        data.numb = numb
        data.blocks = blocks
        data.eblocks = eblocks
        data.cl = cl
        data.blocksize = blocksize
        data.GramMat = GramMat
        data.moment = moment
        data.SDP_status = SDP_status
    end
    return opt,sol,data
end

function get_gsupp(n, m, numeq, supp, gbasis, hbasis, blocks, eblocks, cl, blocksize; nb=0)
    s = 0
    if m > numeq
        s += sum(size(supp[k+1],2)*Int(sum(Int.(blocksize[k]).^2+blocksize[k])/2) for k=1:m-numeq)
    end
    if numeq > 0
        s += sum(size(supp[k+m-numeq+1],2)*length(eblocks[k]) for k=1:numeq)
    end
    gsupp = zeros(UInt8, n, s)
    l = 1
    for k = 1:m-numeq, i = 1:cl[k], j = 1:blocksize[k][i], r = j:blocksize[k][i], s = 1:size(supp[k+1],2)
        @inbounds bi = bin_add(gbasis[k][:,blocks[k][i][j]], gbasis[k][:,blocks[k][i][r]], nb)
        @inbounds bi = bin_add(bi, supp[k+1][:,s], nb)
        @inbounds gsupp[:,l] = bi
        l += 1
    end
    for k = 1:numeq, i in eblocks[k], s = 1:size(supp[k+1],2)
        @inbounds bi = bin_add(hbasis[k][:,i], supp[k+m-numeq+1][:,s], nb)
        @inbounds gsupp[:,l] = bi
        l += 1
    end
    return gsupp
end

function reducebasis!(supp, basis, blocks, cl, blocksize; nb=0)
    esupp = supp[:, all.(iseven, eachcol(supp))]
    init,flag,check = 0,0,0
    while init==0 || check>0
        init,check = 1,0
        tsupp = esupp
        for i = 1:cl
            if blocksize[i] > 1
                for j = 1:blocksize[i], r = j+1:blocksize[i]
                    @inbounds bi = bin_add(basis[:,blocks[i][j]], basis[:,blocks[i][r]], nb)
                    tsupp = [tsupp bi]
                end
            end
        end
        tsupp = unique(tsupp, dims=2)
        tsupp = sortslices(tsupp, dims=2)
        ltsupp = size(tsupp, 2)
        for i = 1:cl
            lo = blocksize[i]
            indexb = [k for k=1:lo]
            j = 1
            while lo >= j
                bi = bin_add(basis[:,blocks[i][indexb[j]]], basis[:,blocks[i][indexb[j]]], nb)
                Locb = bfind(tsupp, ltsupp, bi)
                if Locb === nothing
                   check,flag = 1,1
                   deleteat!(indexb, j)
                   lo -= 1
                else
                   j += 1
                end
            end
            blocks[i] = blocks[i][indexb]
            blocksize[i] = lo
        end
    end
    if flag == 1
       indexb = blocks[1]
       for i = 2:cl
           indexb = append!(indexb, blocks[i])
       end
       sort!(indexb)
       unique!(indexb)
       return basis[:,indexb],flag
    else
       return basis,flag
    end
end

function get_cgraph(tsupp::Array{UInt8, 2}, supp::Array{UInt8, 2}, basis::Array{UInt8, 2}; nb=0, nv=0, signsymmetry=nothing)
    lb = size(basis, 2)
    G = SimpleGraph(lb)
    ltsupp = size(tsupp, 2)
    for i = 1:lb, j = i+1:lb
        if signsymmetry === nothing
            ind = findfirst(x -> bfind(tsupp, ltsupp, bin_add(bin_add(basis[:,i], basis[:,j], nb), supp[:,x], nb)) !== nothing, size(supp, 2))
            if ind !== nothing
                add_edge!(G, i, j)
            end
        else
            bi = bin_add(bin_add(basis[:,i], basis[:,j], nb), supp[:,1], nb)
            if all(transpose(signsymmetry)*bi .== 0)
                add_edge!(G, i, j)
            end
        end
    end
    return G
end

function get_eblock(tsupp::Array{UInt8, 2}, hsupp::Array{UInt8, 2}, basis::Array{UInt8, 2}; nb=nb, nv=0, signsymmetry=nothing)
    ltsupp = size(tsupp, 2)
    hlt = size(hsupp, 2)
    eblock = UInt16[]
    for i = 1:size(basis, 2)
        if signsymmetry === nothing
            if findfirst(x -> bfind(tsupp, ltsupp, bin_add(basis[:,i], hsupp[:,x], nb)) !== nothing, 1:hlt) !== nothing
                push!(eblock, i)
            end
        else
            bi = bin_add(basis[:,i], hsupp[:,1], nb)
            if all(transpose(signsymmetry)*bi .== 0)
                push!(eblock, i)
            end
        end
    end
    return eblock
end

function get_cblocks(m, l, tsupp, supp, basis, hbasis; blocks=[], eblocks=[], cl=[], blocksize=[], sb=[], numb=[], nb=0,
    TS="block", QUIET=true, merge=false, md=3, nv=0, signsymmetry=nothing)
    if isempty(blocks)
        blocks = Vector{Vector{Vector{UInt16}}}(undef, m+1)
        eblocks = Vector{Vector{UInt16}}(undef, l)
        blocksize = Vector{Vector{UInt16}}(undef, m+1)
        cl = Vector{UInt16}(undef, m+1)
    end
    if TS == false
        for k = 1:m+1
            lb = ndims(basis[k])==1 ? length(basis[k]) : size(basis[k], 2)
            blocks[k] = [Vector(1:lb)]
            blocksize[k] = [lb]
            cl[k] = 1
        end
        for k = 1:l
            lb = ndims(hbasis[k])==1 ? length(hbasis[k]) : size(hbasis[k], 2)
            eblocks[k] = Vector(1:lb)
        end
        status = 1
        nsb = Int.(blocksize[1])
        nnumb = [1]
    else
        G = get_graph(tsupp, basis[1], nb=nb, nv=nv, signsymmetry=signsymmetry)
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
                G = get_cgraph(tsupp, supp[k], basis[k+1], nb=nb, nv=nv, signsymmetry=signsymmetry)
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
                eblocks[k] = get_eblock(tsupp, supp[k+m], hbasis[k], nb=nb, nv=nv, signsymmetry=signsymmetry)
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

function blockcpop(n, m, supp, coe, basis, hbasis, blocks, eblocks, cl, blocksize; nb=0, numeq=0, gb=[], x=[], lead=[], solver="Mosek", TS="block",
    QUIET=true, solve=true, dualize=false, solution=false, MomentOne=false, Gram=false, cosmo_setting=cosmo_para(), mosek_setting=mosek_para(), 
    signsymmetry=false, normality=false, NormalSparse=false)
    ksupp = zeros(UInt8, n, Int(sum(Int.(blocksize[1]).^2+blocksize[1])/2))
    k = 1
    for i = 1:cl[1], j = 1:blocksize[1][i], r = j:blocksize[1][i]
        @inbounds bi = bin_add(basis[1][:,blocks[1][i][j]], basis[1][:,blocks[1][i][r]], nb)
        @inbounds ksupp[:,k] = bi
        k += 1
    end
    neq = isempty(gb) ? numeq : 0
    if TS != false && TS != "signsymmetry"
        gsupp = get_gsupp(n, m, neq, supp, basis[2:end], hbasis, blocks[2:end], eblocks, cl[2:end], blocksize[2:end], nb=nb)
        ksupp = [ksupp gsupp]
    end
    objv = moment = momone = GramMat = SDP_status = nothing
    if solve == true
        tsupp = ksupp
        if normality == true
            wbasis = basis[1]
            bs = size(wbasis, 2)
            if NormalSparse == true
                hyblocks = Vector{Vector{Vector{UInt16}}}(undef, n)
                for i = 1:n
                    G = SimpleGraph(2bs)
                    for j = 1:bs, k = j:bs
                        bi = bin_add(wbasis[:, j], wbasis[:, k], nb)
                        if all(transpose(signsymmetry)*bi .== 0)
                            add_edge!(G, j, k)
                        end
                        temp = zeros(UInt8, n)
                        temp[i] = 2
                        bi = bin_add(bin_add(wbasis[:, j], wbasis[:, k], nb), temp, nb)
                        if all(transpose(signsymmetry)*bi .== 0)
                            add_edge!(G, j+bs, k+bs)
                        end
                        temp[i] = 1
                        bi = bin_add(bin_add(wbasis[:, j], wbasis[:, k], nb), temp, nb)
                        if all(transpose(signsymmetry)*bi .== 0)
                            add_edge!(G, j, k+bs)
                        end
                    end
                    hyblocks[i] = connected_components(G)
                    for l = 1:length(hyblocks[i])
                        for j = 1:length(hyblocks[i][l]), k = j:length(hyblocks[i][l])
                            if hyblocks[i][l][j] <= bs && hyblocks[i][l][k] > bs
                                temp = zeros(UInt8, n)
                                temp[i] = 1
                                bi = bin_add(bin_add(wbasis[:, hyblocks[i][l][j]], wbasis[:, hyblocks[i][l][k]-bs], nb), temp, nb)
                                tsupp = [tsupp bi]
                            elseif hyblocks[i][l][j] > bs
                                temp = zeros(UInt8, n)
                                temp[i] = 2
                                bi = bin_add(bin_add(wbasis[:, hyblocks[i][l][j]-bs], wbasis[:, hyblocks[i][l][k]-bs], nb), temp, nb)
                                tsupp = [tsupp bi]
                            end
                        end
                    end
                end
            else
                for i = 1:n, j = 1:bs, k = j:bs
                    temp = zeros(UInt8, n)
                    temp[i] = 1
                    bi = bin_add(bin_add(wbasis[:, j], wbasis[:, k], nb), temp, nb)
                    tsupp = [tsupp bi]
                    temp[i] = 2
                    bi = bin_add(bin_add(wbasis[:, j], wbasis[:, k], nb), temp, nb)
                    tsupp = [tsupp bi]
                end
            end
        end
        if (MomentOne == true || solution == true) && TS != false
            tsupp = [tsupp get_basis(n, 2, nb=nb, lead=lead)]
        end
        if !isempty(gb)
            tsupp = unique(tsupp, dims=2)
            nsupp = zeros(UInt8, n)
            llead = size(lead, 2)
            for col in eachcol(tsupp)
                if divide(col, lead, n, llead)
                    temp = reminder(col, x, gb, n)[2]
                    nsupp = [nsupp temp]
                else
                    nsupp = [nsupp col]
                end
            end
            tsupp = nsupp
        end
        tsupp = sortslices(tsupp, dims=2)
        tsupp = unique(tsupp, dims=2)
        ltsupp = size(tsupp, 2)
        if QUIET == false
            println("Assembling the SDP...")
            println("There are $ltsupp affine constraints.")
        end
        if solver == "Mosek"
            if dualize == false
                model = Model(optimizer_with_attributes(Mosek.Optimizer, "MSK_DPAR_INTPNT_CO_TOL_PFEAS" => mosek_setting.tol_pfeas, "MSK_DPAR_INTPNT_CO_TOL_DFEAS" => mosek_setting.tol_dfeas, 
                "MSK_DPAR_INTPNT_CO_TOL_REL_GAP" => mosek_setting.tol_relgap, "MSK_DPAR_OPTIMIZER_MAX_TIME" => mosek_setting.time_limit))
            else
                model = Model(dual_optimizer(Mosek.Optimizer))
            end
        elseif solver == "COSMO"
            model = Model(optimizer_with_attributes(COSMO.Optimizer, "eps_abs" => cosmo_setting.eps_abs, "eps_rel" => cosmo_setting.eps_rel, "max_iter" => cosmo_setting.max_iter, "time_limit" => cosmo_setting.time_limit))
        elseif solver == "SDPT3"
            model = Model(optimizer_with_attributes(SDPT3.Optimizer))
        elseif solver == "SDPNAL"
            model = Model(optimizer_with_attributes(SDPNAL.Optimizer))
        else
            @error "The solver is currently not supported!"
            return nothing,nothing,nothing,nothing,nothing,nothing
        end
        set_optimizer_attribute(model, MOI.Silent(), QUIET)
        time = @elapsed begin
        cons = [AffExpr(0) for i=1:ltsupp]
        if normality == true
            for i = 1:n
                if NormalSparse == false
                    hnom = @variable(model, [1:2bs, 1:2bs], PSD)
                    for j = 1:bs, k = j:bs
                        bi = bin_add(wbasis[:, j], wbasis[:, k], nb)
                        if !isempty(gb) && divide(bi, lead, n, llead)
                            bi_lm,bi_supp,bi_coe = reminder(bi, x, gb, n)
                            for l = 1:bi_lm
                                Locb = bfind(tsupp, ltsupp, bi_supp[:,l])
                                if j == k
                                    @inbounds add_to_expression!(cons[Locb], bi_coe[l], hnom[j,k])
                                else
                                    @inbounds add_to_expression!(cons[Locb], 2*bi_coe[l], hnom[j,k])
                                end
                            end
                        else
                            Locb = bfind(tsupp, ltsupp, bi)
                            if j == k
                                @inbounds add_to_expression!(cons[Locb], hnom[j,k])
                            else
                                @inbounds add_to_expression!(cons[Locb], 2, hnom[j,k])
                            end
                        end
                        temp = zeros(UInt8, n)
                        temp[i] = 2
                        bi = bin_add(bin_add(wbasis[:, j], wbasis[:, k], nb), temp, nb)
                        bi = bin_add(wbasis[:, j], wbasis[:, k], nb)
                        if !isempty(gb) && divide(bi, lead, n, llead)
                            bi_lm,bi_supp,bi_coe = reminder(bi, x, gb, n)
                            for l = 1:bi_lm
                                Locb = bfind(tsupp, ltsupp, bi_supp[:,l])
                                if j == k
                                    @inbounds add_to_expression!(cons[Locb], bi_coe[l], hnom[j+bs,k+bs])
                                else
                                    @inbounds add_to_expression!(cons[Locb], 2*bi_coe[l], hnom[j+bs,k+bs])
                                end
                            end
                        else
                            Locb = bfind(tsupp, ltsupp, bi)
                            if j == k
                                @inbounds add_to_expression!(cons[Locb], hnom[j+bs,k+bs])
                            else
                                @inbounds add_to_expression!(cons[Locb], 2, hnom[j+bs,k+bs])
                            end
                        end
                        temp[i] = 1
                        bi = bin_add(bin_add(wbasis[:, j], wbasis[:, k], nb), temp, nb)
                        if !isempty(gb) && divide(bi, lead, n, llead)
                            bi_lm,bi_supp,bi_coe = reminder(bi, x, gb, n)
                            for l = 1:bi_lm
                                Locb = bfind(tsupp, ltsupp, bi_supp[:,l])
                                if j == k
                                    @inbounds add_to_expression!(cons[Locb], 2*bi_coe[l], hnom[j,k+bs])
                                else
                                    @inbounds add_to_expression!(cons[Locb], 2*bi_coe[l], hnom[j,k+bs]+hnom[k,j+bs])
                                end
                            end
                        else
                            Locb = bfind(tsupp, ltsupp, bi)
                            if j == k
                                @inbounds add_to_expression!(cons[Locb], 2, hnom[j,k+bs])
                            else
                                @inbounds add_to_expression!(cons[Locb], 2, hnom[j,k+bs]+hnom[k,j+bs])
                            end
                        end
                    end
                else
                    for l = 1:length(hyblocks[i])
                        hbs = length(hyblocks[i][l])
                        hnom = @variable(model, [1:hbs, 1:hbs], PSD)
                        for j = 1:hbs, k = j:hbs
                            temp = zeros(UInt8, n)
                            if hyblocks[i][l][k] <= bs
                                bi = bin_add(wbasis[:, hyblocks[i][l][j]], wbasis[:, hyblocks[i][l][k]], nb)
                            elseif hyblocks[i][l][j] <= bs && hyblocks[i][l][k] > bs
                                temp[i] = 1
                                bi = bin_add(bin_add(wbasis[:, hyblocks[i][l][j]], wbasis[:, hyblocks[i][l][k]-bs], nb), temp, nb)
                            else
                                temp[i] = 2
                                bi = bin_add(bin_add(wbasis[:, hyblocks[i][l][j]-bs], wbasis[:, hyblocks[i][l][k]-bs], nb), temp, nb)
                            end
                            if !isempty(gb) && divide(bi, lead, n, llead)
                                bi_lm,bi_supp,bi_coe = reminder(bi, x, gb, n)
                                for l = 1:bi_lm
                                    Locb = bfind(tsupp, ltsupp, bi_supp[:,l])
                                    if j == k
                                        @inbounds add_to_expression!(cons[Locb], bi_coe[l], hnom[j,k])
                                    else
                                        @inbounds add_to_expression!(cons[Locb], 2*bi_coe[l], hnom[j,k])
                                    end
                                end
                            else
                                Locb = bfind(tsupp, ltsupp, bi)
                                if j == k
                                    @inbounds add_to_expression!(cons[Locb], hnom[j,k])
                                else
                                    @inbounds add_to_expression!(cons[Locb], 2, hnom[j,k])
                                end
                            end
                        end
                    end
                end
            end
        end
        pos = Vector{Union{VariableRef,Symmetric{VariableRef}}}(undef, cl[1])
        for i = 1:cl[1]
            if MomentOne == true || solution == true
                pos0 = @variable(model, [1:n+1, 1:n+1], PSD)
                for j = 1:n+1, k = j:n+1
                    @inbounds bi = bin_add(basis[1][:,j], basis[1][:,k], nb)
                    if !isempty(gb) && divide(bi, lead, n, llead)
                        bi_lm,bi_supp,bi_coe = reminder(bi, x, gb, n)
                        for l = 1:bi_lm
                            Locb = bfind(tsupp, ltsupp, bi_supp[:,l])
                            if j == k
                               @inbounds add_to_expression!(cons[Locb], bi_coe[l], pos0[j,k])
                            else
                               @inbounds add_to_expression!(cons[Locb], 2*bi_coe[l], pos0[j,k])
                            end
                        end
                    else
                        Locb = bfind(tsupp,ltsupp,bi)
                        if j == k
                           @inbounds add_to_expression!(cons[Locb], pos0[j,k])
                        else
                           @inbounds add_to_expression!(cons[Locb], 2, pos0[j,k])
                        end
                    end
                end
            end
            bs = blocksize[1][i]
            if bs == 1
               @inbounds pos[i] = @variable(model, lower_bound=0)
               @inbounds bi = bin_add(basis[1][:,blocks[1][i][1]], basis[1][:,blocks[1][i][1]], nb)
               if !isempty(gb) && divide(bi, lead, n, llead)
                   bi_lm,bi_supp,bi_coe = reminder(bi, x, gb, n)
                   for l = 1:bi_lm
                       Locb = bfind(tsupp, ltsupp, bi_supp[:,l])
                       @inbounds add_to_expression!(cons[Locb], bi_coe[l], pos[i])
                   end
               else
                   Locb = bfind(tsupp, ltsupp, bi)
                   @inbounds add_to_expression!(cons[Locb], pos[i])
               end
            else
               @inbounds pos[i] = @variable(model, [1:bs, 1:bs], PSD)
               for j = 1:bs, r = j:bs
                   @inbounds bi = bin_add(basis[1][:,blocks[1][i][j]], basis[1][:,blocks[1][i][r]], nb)
                   if !isempty(gb) && divide(bi, lead, n, llead)
                       bi_lm,bi_supp,bi_coe = reminder(bi, x, gb, n)
                       for l = 1:bi_lm
                           Locb = bfind(tsupp, ltsupp, bi_supp[:,l])
                           if j == r
                              @inbounds add_to_expression!(cons[Locb], bi_coe[l], pos[i][j,r])
                           else
                              @inbounds add_to_expression!(cons[Locb], 2*bi_coe[l], pos[i][j,r])
                           end
                       end
                   else
                       Locb = bfind(tsupp, ltsupp, bi)
                       if j == r
                          @inbounds add_to_expression!(cons[Locb], pos[i][j,r])
                       else
                          @inbounds add_to_expression!(cons[Locb], 2, pos[i][j,r])
                       end
                   end
               end
            end
        end
        if m > neq
            gpos = Vector{Vector{Union{VariableRef,Symmetric{VariableRef}}}}(undef, m-neq)
        end
        for k = 1:m-neq
            gpos[k] = Vector{Union{VariableRef,Symmetric{VariableRef}}}(undef, cl[k+1])
            for i = 1:cl[k+1]
                bs = blocksize[k+1][i]
                if bs == 1
                    gpos[k][i] = @variable(model, lower_bound=0)
                    for s = 1:size(supp[k+1],2)
                        @inbounds bi = bin_add(basis[k+1][:,blocks[k+1][i][1]], basis[k+1][:,blocks[k+1][i][1]], nb)
                        @inbounds bi = bin_add(bi, supp[k+1][:,s], nb)
                        if !isempty(gb) && divide(bi, lead, n, llead)
                            bi_lm,bi_supp,bi_coe = reminder(bi, x, gb, n)
                            for l = 1:bi_lm
                                Locb = bfind(tsupp, ltsupp, bi_supp[:,l])
                                @inbounds add_to_expression!(cons[Locb], coe[k+1][s]*bi_coe[l], gpos[k][i])
                            end
                        else
                            Locb = bfind(tsupp, ltsupp, bi)
                            @inbounds add_to_expression!(cons[Locb], coe[k+1][s], gpos[k][i])
                        end
                    end
                else
                    gpos[k][i] = @variable(model, [1:bs, 1:bs], PSD)
                    for j = 1:bs, r = j:bs, s = 1:size(supp[k+1],2)
                        @inbounds bi = bin_add(basis[k+1][:,blocks[k+1][i][j]], basis[k+1][:,blocks[k+1][i][r]], nb)
                        @inbounds bi = bin_add(bi, supp[k+1][:,s], nb)
                        if !isempty(gb) && divide(bi, lead, n, llead)
                            bi_lm,bi_supp,bi_coe = reminder(bi, x, gb, n)
                            for l = 1:bi_lm
                                Locb = bfind(tsupp, ltsupp, bi_supp[:,l])
                                if j == r
                                   @inbounds add_to_expression!(cons[Locb], coe[k+1][s]*bi_coe[l], gpos[k][i][j,r])
                                else
                                   @inbounds add_to_expression!(cons[Locb], 2*coe[k+1][s]*bi_coe[l], gpos[k][i][j,r])
                                end
                            end
                        else
                            Locb = bfind(tsupp, ltsupp, bi)
                            if j == r
                               @inbounds add_to_expression!(cons[Locb], coe[k+1][s], gpos[k][i][j,r])
                            else
                               @inbounds add_to_expression!(cons[Locb], 2*coe[k+1][s], gpos[k][i][j,r])
                            end
                        end
                    end
                end
            end
        end
        if isempty(gb) && numeq > 0
            free = Vector{Vector{VariableRef}}(undef, numeq)
            for k = 1:numeq
                free[k] = @variable(model, [1:length(eblocks[k])])
                for (i,j) in enumerate(eblocks[k]), s = 1:size(supp[k+m-numeq+1], 2)
                    @inbounds bi = bin_add(hbasis[k][:,j], supp[k+m-numeq+1][:,s], nb)
                    Locb = bfind(tsupp, ltsupp, bi)
                    @inbounds add_to_expression!(cons[Locb], coe[k+m-numeq+1][s], free[k][i])
                end
            end
        end
        bc = zeros(ltsupp)
        for i = 1:size(supp[1], 2)
            Locb = bfind(tsupp, ltsupp, supp[1][:,i])
            if Locb === nothing
               @error "The monomial basis is not enough!"
               return nothing,nothing,nothing,nothing,nothing,nothing
            else
               bc[Locb] = coe[1][i]
           end
        end
        @variable(model, lower)
        cons[1] += lower
        @constraint(model, con[i=1:ltsupp], cons[i]==bc[i])
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
        SDP_status = termination_status(model)
        objv = objective_value(model)
        if SDP_status != MOI.OPTIMAL
           println("termination status: $SDP_status")
           status = primal_status(model)
           println("solution status: $status")
        end
        println("optimum = $objv")
        if Gram == true
            GramMat = Vector{Vector{Union{Float64,Matrix{Float64}}}}(undef, m+1)
            GramMat[1] = [value.(pos[i]) for i = 1:cl[1]]
            for k = 1:m
                GramMat[k+1] = [value.(gpos[k][i]) for i = 1:cl[k+1]]
            end
        end
        dual_var = -dual.(con)
        moment = Vector{Matrix{Float64}}(undef, cl[1])
        for i = 1:cl[1]
            moment[i] = zeros(blocksize[1][i],blocksize[1][i])
            for j = 1:blocksize[1][i], k = j:blocksize[1][i]
                bi = bin_add(basis[1][:,blocks[1][i][j]], basis[1][:,blocks[1][i][k]], nb)
                if !isempty(gb) && divide(bi, lead, n, llead)
                    bi_lm,bi_supp,bi_coe = reminder(bi, x, gb, n)
                    moment[i][j,k] = 0
                    for l = 1:bi_lm
                        Locb = bfind(tsupp, ltsupp, bi_supp[:,l])
                        moment[i][j,k] += bi_coe[l]*dual_var[Locb]
                    end
                else
                    Locb = bfind(tsupp, ltsupp, bi)
                    moment[i][j,k] = dual_var[Locb]
                end
            end
            moment[i] = Symmetric(moment[i],:U)
        end
        if solution == true
            momone = zeros(Float64, n+1, n+1)
            for j = 1:n+1, k = j:n+1
                bi = bin_add(basis[1][:,j], basis[1][:,k], nb)
                if !isempty(gb) && divide(bi, lead, n, llead)
                    bi_lm,bi_supp,bi_coe = reminder(bi, x, gb, n)
                    momone[j,k] = 0
                    for l = 1:bi_lm
                        Locb = bfind(tsupp, ltsupp, bi_supp[:,l])
                        momone[j,k] += bi_coe[l]*dual_var[Locb]
                    end
                else
                    Locb = bfind(tsupp, ltsupp, bi)
                    momone[j,k] = dual_var[Locb]
                end
            end
            momone = Symmetric(momone,:U)
        end
    end
    return objv,ksupp,moment,momone,GramMat,SDP_status
end
