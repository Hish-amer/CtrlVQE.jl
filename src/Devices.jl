using Memoization: @memoize
#= NOTE:

We are using `Memoization` to reconcile the following two considerations:
1. Simple-as-possible interface.
2. Don't re-calculate things you've already calculated.

The `Memoization` package is a bit beyond our control, generating two more problems:
1. Not every use-case will want every function call cached. Doing so is a waste of space.
2. If the state of any argument in a method changes, its cached value is no longer valid.

After toying with ideas for a number of more customized cache implementations,
    I've decided, to simply *not* memoize any function depending on an absolute time.
    I think that more or less solves the worst parts of problem 1.

    By chance, it seems like relative time only appears without absolute time in a context where the relative time could be interpreted as an absolute time (ie. propagation of a static hamiltonian), which means we actually just don't cache any times at all... Huh.

    Naw. We do very much desire staticpropagator(τ) to cache.
    If we definitely do not want staticpropagator(t) to cache,
        thing to do is to split one off into a new method.

As it happens, it also solves problem 2 in the short term,
    because, at present, static device parameters are considered fixed.
So, the changing state of the device would only actually impact time-dependent methods.

BUT

If ever we implement a device with "tunable couplings",
    such that time-independent parameters of a device are changed on `Parameters.bind(⋅)`,
    the implementation of `Parameters.bind` should CLEAR the cache:

    Memoization.empty_all_caches!()

Alternatively, selectively clear caches for affected functions via:

    Memoization.empty_cache!(fn)

I don't know if it's possible to selectively clear cached values for specific methods.
If it can be done, it would require obtaining the actual `IdDict`
    being used as a cache for a particular function,
    figuring out exactly how that cache is indexed,
    and manually removing elements matching your targeted method signature.

=#

using LinearAlgebra: I, Diagonal, Hermitian, Eigen, eigen
import ..Bases, ..Operators, ..LinearAlgebraTools, ..Signals

using ..LinearAlgebraTools: List
Evolvable = AbstractVecOrMat{<:Complex{<:AbstractFloat}}

struct Quple
    q1::Int
    q2::Int
    # INNER CONSTRUCTOR: Constrain order so that `Qu...ple(q1,q2) == Qu...ple(q2,q1)`.
    Quple(q1, q2) = q1 > q2 ? new(q2, q1) : new(q1, q2)
end

# IMPLEMENT ITERATION, FOR CONVENIENT UNPACKING
Base.iterate(quple::Quple) = quple.q1, true
Base.iterate(quple::Quple, state) = state ? (quple.q2, false) : nothing

# TODO (mid): Generalize to n qubits (call sort on input arguments) and hopefully subtype Tuple


"""
NOTE: Implements `Parameters` interface.
"""
abstract type Device end




# METHODS NEEDING TO BE IMPLEMENTED
nqubits(::Device)::Int = error("Not Implemented")
nstates(::Device, q::Int)::Int = error("Not Implemented")
ndrives(::Device)::Int = error("Not Implemented")
ngrades(::Device)::Int = error("Not Implemented")

function localloweringoperator(::Device,
    q::Int,
)::AbstractMatrix
    return error("Not Implemented")
end

function qubithamiltonian(::Device,
    ā::List{<:AbstractMatrix},
    q::Int,
)::AbstractMatrix
    return error("Not Implemented")
end

function staticcoupling(::Device,
    ā::List{<:AbstractMatrix},
)::AbstractMatrix
    return error("Not Implemented")
end

function driveoperator(::Device,
    ā::List{<:AbstractMatrix},
    i::Int,
    t::Real,
)::AbstractMatrix
    return error("Not Implemented")
end

function gradeoperator(::Device,
    ā::List{<:AbstractMatrix},
    j::Int,
    t::Real,
)::AbstractMatrix
    # Returns Hermitian Â such that ϕ = ⟨λ|(𝑖Â)|ψ⟩ + h.t.
    return error("Not Implemented")
end

function gradient(::Device,
    τ̄::AbstractVector,
    t̄::AbstractVector,
    ϕ̄::AbstractMatrix,
)::AbstractVector
    return error("Not Implemented")
end







# UTILITIES

function globalize(device::Device, op::AbstractMatrix, q::Int)
    F = eltype(op)
    ops = Matrix{F}[]
    for p in 1:nqubits(device)
        if p == q
            push!(ops, convert(Matrix{F}, op))
            continue
        end

        m = nstates(device, p)
        push!(ops, Matrix{F}(I, m, m))
    end
    return LinearAlgebraTools.kron(ops)
end

function _cd_from_ix(i::Int, m̄::List{<:Integer})
    i = i - 1       # SWITCH TO INDEXING FROM 0
    ī = Vector{Int}(undef, length(m̄))
    for q in eachindex(m̄)
        i, ī[q] = divrem(i, m̄[q])
    end
    return ī
end

function _ix_from_cd(ī::AbstractVector{<:Integer}, m̄::List{<:Integer})
    i = 0
    offset = 1
    for q in eachindex(m̄)
        i += offset * ī[q]
        offset *= m̄[q]
    end
    return i + 1    # SWITCH TO INDEXING FROM 1
end

function project(device::Device, op::AbstractMatrix, m̄1::List{Int})
    N1 = size(op, 1)

    m̄2 = [nstates(device,q) for q in 1:nqubits(device)]
    ix_map = Dict(i1 => _ix_from_cd(_cd_from_ix(i1,m̄1),m̄2) for i1 in 1:N1)

    N2 = nstates(device)
    op2 = zeros(eltype(op), N2, N2)
    for i in 1:N1
        for j in 1:N1
            op2[ix_map[i],ix_map[j]] = op[i,j]
        end
    end
    return op2
end

function project(device::Device, op::AbstractMatrix, m::Int)
    return project(device, op, fill(m, nqubits(device)))
end

function project(device::Device, op::AbstractMatrix)
    # ASSUME `op` HAS UNIFORM NUMBER OF STATES ON EACH QUBIT
    m = round(Int, size(op,1) ^ (1/nqubits(device)))
    return project(device, op, m)
end




@memoize Dict nstates(device::Device) = prod(nstates(device,q) for q in 1:nqubits(device))






# BASIS ROTATIONS

@memoize Dict function diagonalize(::Bases.Dressed, device::Device)
    H0 = operator(Operators.STATIC, device)

    N = size(H0)[1]
    Λ, U = eigen(Hermitian(H0))

    # IMPOSE PERMUTATION
    σ = Vector{Int}(undef,N)
    for i in 1:N
        perm = sortperm(abs.(U[i,:]), rev=true) # STABLE SORT BY "ith" COMPONENT
        perm_ix = 1                             # CAREFULLY HANDLE TIES
        while perm[perm_ix] ∈ σ[1:i-1]
            perm_ix += 1
        end
        σ[i] = perm[perm_ix]
    end
    Λ .= Λ[  σ]
    U .= U[:,σ]

    # IMPOSE PHASE
    for i in 1:N
        U[:,i] .*= U[i,i] < 0 ? -1 : 1          # ASSUMES REAL TYPE
        # U[:,i] .*= exp(-im*angle(U[i,i]))        # ASSUMES COMPLEX TYPE
    end

    # IMPOSE ZEROS
    Λ[abs.(Λ) .< eps(eltype(Λ))] .= zero(eltype(Λ))
    U[abs.(U) .< eps(eltype(U))] .= zero(eltype(U))

    return Eigen(Λ,U)

    # TODO (mid): Each imposition really ought to be a separate function.
    # TODO (mid): Phase imposition should accommodate real or complex H0.
    # TODO (mid): Strongly consider imposing phase on the local bases also.
end

@memoize Dict function diagonalize(basis::Bases.LocalBasis, device::Device)
    ΛU = [diagonalize(basis, device, q) for q in 1:nqubits(device)]
    Λ = LinearAlgebraTools.kron([ΛU[q].values  for q in 1:nqubits(device)])
    U = LinearAlgebraTools.kron([ΛU[q].vectors for q in 1:nqubits(device)])
    return Eigen(Λ, U)
end

@memoize Dict function diagonalize(::Bases.Occupation, device::Device, q::Int)
    a = localloweringoperator(device, q)
    I = one(a)
    return eigen(Hermitian(I))
end

@memoize Dict function diagonalize(::Bases.Coordinate, device::Device, q::Int)
    a = localloweringoperator(device, q)
    Q = (a + a') / eltype(a)(√2)
    return eigen(Hermitian(Q))
end

@memoize Dict function diagonalize(::Bases.Momentum, device::Device, q::Int)
    a = localloweringoperator(device, q)
    P = (a - a') / eltype(a)(√2)
    return eigen(Hermitian(P))
end

@memoize Dict function basisrotation(
    tgt::Bases.BasisType,
    src::Bases.BasisType,
    device::Device,
)
    Λ0, U0 = diagonalize(src, device)
    Λ1, U1 = diagonalize(tgt, device)
    # |ψ'⟩ ≡ U0|ψ⟩ rotates |ψ⟩ OUT of `src` Bases.
    # U1'|ψ'⟩ rotates |ψ'⟩ INTO `tgt` Bases.
    return U1' * U0
end

@memoize Dict function basisrotation(
    tgt::Bases.LocalBasis,
    src::Bases.LocalBasis,
    device::Device,
)
    ū = localbasisrotations(tgt, src, device)
    return LinearAlgebraTools.kron(ū)
end

@memoize Dict function basisrotation(
    tgt::Bases.LocalBasis,
    src::Bases.LocalBasis,
    device::Device,
    q::Int,
)
    Λ0, U0 = diagonalize(src, device, q)
    Λ1, U1 = diagonalize(tgt, device, q)
    # |ψ'⟩ ≡ U0|ψ⟩ rotates |ψ⟩ OUT of `src` Bases.
    # U1'|ψ'⟩ rotates |ψ'⟩ INTO `tgt` Bases.
    return U1' * U0
end

@memoize Dict function localbasisrotations(
    tgt::Bases.LocalBasis,
    src::Bases.LocalBasis,
    device::Device,
)
    return [basisrotation(tgt, src, device, q) for q in 1:nqubits(device)]
end





#= ALGEBRAS =#

@memoize Dict function algebra(
    device::Device,
    basis::Bases.BasisType=Bases.OCCUPATION,
)
    U = basisrotation(basis, Bases.OCCUPATION, device)
    a0 = localloweringoperator(device, 1)   # NOTE: Raises error if device has no qubits.
    F = promote_type(eltype(U), eltype(a0)) # NUMBER TYPE COMPATIBLE WITH ROTATION

    ā = Matrix{F}[]
    for q in 1:nqubits(device)
        a0 = localloweringoperator(device, q)
        aF = convert(Matrix{F}, copy(a0))

        a = globalize(device, aF, q)
        a = LinearAlgebraTools.rotate!(U, a)
        push!(ā, a)
    end
    return ā
end

@memoize Dict function localalgebra(
    device::Device,
    basis::Bases.BasisType=Bases.OCCUPATION,
)
    # DETERMINE THE NUMBER TYPE COMPATIBLE WITH ROTATION
    # NOTE: Raises error if device has no qubits.
    U = basisrotation(basis, Bases.OCCUPATION, device, 1)
    a0 = localloweringoperator(device, 1)
    F = promote_type(eltype(U), eltype(a0))

    ā = Matrix{F}[]
    for q in 1:nqubits(device)
        U = basisrotation(basis, Bases.OCCUPATION, device, q)
        a0 = localloweringoperator(device, q)
        aF = convert(Matrix{F}, copy(a0))

        a = LinearAlgebraTools.rotate!(U, aF)
        push!(ā, a)
    end
    return ā
end


#= HERMITIAN OPERATORS =#

function operator(op::Operators.OperatorType, device::Device)
    return operator(op, device, Bases.OCCUPATION)
end

@memoize Dict function operator(
    op::Operators.Qubit,
    device::Device,
    basis::Bases.BasisType
)
    ā = algebra(device, basis)
    return qubithamiltonian(device, ā, op.q)
end

@memoize Dict function operator(
    op::Operators.Coupling,
    device::Device,
    basis::Bases.BasisType,
)
    ā = algebra(device, basis)
    return staticcoupling(device, ā)
end

function operator(
    op::Operators.Channel,
    device::Device,
    basis::Bases.BasisType,
)
    ā = algebra(device, basis)
    return driveoperator(device, ā, op.i, op.t)
end

function operator(
    op::Operators.Gradient,
    device::Device,
    basis::Bases.BasisType,
)
    ā = algebra(device, basis)
    return gradeoperator(device, ā, op.j, op.t)
end

@memoize Dict function operator(
    op::Operators.Uncoupled,
    device::Device,
    basis::Bases.BasisType,
)
    return sum(operator(Operators.Qubit(q), device, basis) for q in 1:nqubits(device))
end

@memoize Dict function operator(
    op::Operators.Static,
    device::Device,
    basis::Bases.BasisType,
)
    return sum((
        operator(Operators.UNCOUPLED, device, basis),
        operator(Operators.COUPLING,  device, basis),
    ))
end

@memoize Dict function operator(
    op::Operators.Static,
    device::Device,
    ::Bases.Dressed,
)
    Λ, U = diagonalize(Bases.DRESSED, device)
    return Diagonal(Λ)
end

function operator(
    op::Operators.Drive,
    device::Device,
    basis::Bases.BasisType,
)
    return sum((
        operator(Operators.Channel(i, op.t), device, basis)
            for i in 1:ndrives(device)
    ))
end

function operator(
    op::Operators.Hamiltonian,
    device::Device,
    basis::Bases.BasisType,
)
    return sum((
        operator(Operators.STATIC, device, basis),
        operator(Operators.Drive(op.t), device, basis),
    ))
end


function localqubitoperators(device::Device)
    return localqubitoperators(device, Bases.OCCUPATION)
end

@memoize Dict function localqubitoperators(
    device::Device,
    basis::Bases.LocalBasis,
)
    ā = localalgebra(device, basis)
    return [qubithamiltonian(device, ā, q) for q in 1:nqubits(device)]
end




#= PROPAGATORS =#



function propagator(op::Operators.OperatorType, device::Device, τ::Real)
    return propagator(op, device, Bases.OCCUPATION, τ)
end

function propagator(
    op::Operators.OperatorType,
    device::Device,
    basis::Bases.BasisType,
    τ::Real,
)
    H = operator(op, device, basis)
    U = convert(Array{LinearAlgebraTools.cis_type(H)}, copy(H))
    return LinearAlgebraTools.cis!(U, -τ)
end

@memoize Dict function propagator(
    op::Operators.StaticOperator,
    device::Device,
    basis::Bases.BasisType,
    τ::Real,
)
    # NOTE: This is a carbon copy of the above method, except with caching.
    H = operator(op, device, basis)
    U = convert(Array{LinearAlgebraTools.cis_type(H)}, copy(H))
    return LinearAlgebraTools.cis!(U, -τ)
end

@memoize Dict function propagator(
    op::Operators.Uncoupled,
    device::Device,
    basis::Bases.LocalBasis,
    τ::Real,
)
    ū = localqubitpropagators(device, basis, τ)
    return LinearAlgebraTools.kron(ū)
end

@memoize Dict function propagator(
    op::Operators.Qubit,
    device::Device,
    basis::Bases.LocalBasis,
    τ::Real,
)
    ā = localalgebra(device, basis)

    h = qubithamiltonian(device, ā, op.q)
    u = convert(Array{LinearAlgebraTools.cis_type(h)}, copy(h))
    u = LinearAlgebraTools.cis!(u, -τ)
    return globalize(device, u, op.q)
end




function localqubitpropagators(device::Device, τ::Real)
    return localqubitpropagators(device, Bases.OCCUPATION, τ)
end

@memoize Dict function localqubitpropagators(
    device::Device,
    basis::Bases.LocalBasis,
    τ::Real,
)
    h̄ = localqubitoperators(device, basis)
    h = h̄[1]        # NOTE: Raises error if device has no qubits.
    F = LinearAlgebraTools.cis_type(h)

    ū = Matrix{F}[]
    for h in h̄
        u = convert(Matrix{F}, copy(h))
        u = LinearAlgebraTools.cis!(u, -τ)
        push!(ū, u)
    end
    return ū
end




#= MUTATING PROPAGATION =#

function propagate!(op::Operators.OperatorType, device::Device, τ::Real, ψ::Evolvable)
    return propagate!(op, device, Bases.OCCUPATION, τ, ψ)
end

function propagate!(
    op::Operators.OperatorType,
    device::Device,
    basis::Bases.BasisType,
    τ::Real,
    ψ::Evolvable,
)
    U = propagator(op, device, basis, τ)
    return LinearAlgebraTools.rotate!(U, ψ)
end

function propagate!(
    op::Operators.Uncoupled,
    device::Device,
    basis::Bases.LocalBasis,
    τ::Real,
    ψ::Evolvable,
)
    ū = localqubitpropagators(device, basis, τ)
    return LinearAlgebraTools.rotate!(ū, ψ)
end

function propagate!(
    op::Operators.Qubit,
    device::Device,
    basis::Bases.LocalBasis,
    τ::Real,
    ψ::Evolvable,
)
    ā = localalgebra(device, basis)
    h = qubithamiltonian(device, ā, op.q)
    u = convert(Array{LinearAlgebraTools.cis_type(h)}, copy(h))
    u = LinearAlgebraTools.cis!(u, -τ)
    ops = [p == op.q ? u : one(u) for p in 1:nqubits(device)]
    return LinearAlgebraTools.rotate!(ops, ψ)
end



#= PROPAGATORS FOR ARBITRARY TIME (static only) =#


function evolver(op::Operators.OperatorType, device::Device, t::Real)
    return evolver(op, device, Bases.OCCUPATION, t)
end

function evolver(
    op::Operators.OperatorType,
    device::Device,
    basis::Bases.BasisType,
    t::Real,
)
    error("Not implemented for non-static operator.")
end

function evolver(
    op::Operators.StaticOperator,
    device::Device,
    basis::Bases.BasisType,
    t::Real,
)
    H = operator(op, device, basis)
    U = convert(Array{LinearAlgebraTools.cis_type(H)}, copy(H))
    return LinearAlgebraTools.cis!(U, -t)
end

function evolver(
    op::Operators.Uncoupled,
    device::Device,
    basis::Bases.LocalBasis,
    t::Real,
)
    ū = localqubitevolvers(device, basis, t)
    return LinearAlgebraTools.kron(ū)
end

function evolver(
    op::Operators.Qubit,
    device::Device,
    basis::Bases.LocalBasis,
    t::Real,
)
    ā = localalgebra(device, basis)
    h = qubithamiltonian(device, ā, op.q)
    u = convert(Array{LinearAlgebraTools.cis_type(h)}, copy(h))
    u = LinearAlgebraTools.cis!(u, -t)
    return globalize(device, u, op.q)
end



function localqubitevolvers(device::Device, t::Real)
    return localqubitevolvers(device, Bases.OCCUPATION, t)
end

function localqubitevolvers(
    device::Device,
    basis::Bases.LocalBasis,
    t::Real,
)
    h̄ = localqubitoperators(device, basis)
    h = h̄[1]        # NOTE: Raises error if device has no qubits.
    F = LinearAlgebraTools.cis_type(h)

    ū = Matrix{F}[]
    for h in h̄
        u = convert(Matrix{F}, copy(h))
        u = LinearAlgebraTools.cis!(u, -t)
        push!(ū, u)
    end
    return ū
end


#= MUTATING EVOLUTION FOR ARBITRARY TIME (static only) =#

function evolve!(op::Operators.OperatorType, device::Device, t::Real, ψ::Evolvable)
    return evolve!(op, device, Bases.OCCUPATION, t, ψ)
end

function evolve!(op::Operators.OperatorType,
    device::Device,
    basis::Bases.BasisType,
    t::Real,
    ψ::Evolvable,
)
    error("Not implemented for non-static operator.")
end

function evolve!(
    op::Operators.StaticOperator,
    device::Device,
    basis::Bases.BasisType,
    t::Real,
    ψ::Evolvable,
)
    U = evolver(op, device, basis, t)
    return LinearAlgebraTools.rotate!(U, ψ)
end

function evolve!(
    op::Operators.Uncoupled,
    device::Device,
    basis::Bases.LocalBasis,
    t::Real,
    ψ::Evolvable,
)
    ū = localqubitevolvers(device, basis, t)
    return LinearAlgebraTools.rotate!(ū, ψ)
end

function evolve!(
    op::Operators.Qubit,
    device::Device,
    basis::Bases.LocalBasis,
    t::Real,
    ψ::Evolvable,
)
    ā = localalgebra(device, basis)
    h = qubithamiltonian(device, ā, op.q)
    u = convert(Array{LinearAlgebraTools.cis_type(h)}, copy(h))
    u = LinearAlgebraTools.cis!(u, -t)
    ops = [p == op.q ? u : one(u) for p in 1:nqubits(device)]
    return LinearAlgebraTools.rotate!(ops, ψ)
end





#= SCALAR MATRIX OPERATIONS =#

function expectation(op::Operators.OperatorType, device::Device, ψ::AbstractVector)
    return expectation(op, device, Bases.OCCUPATION, ψ)
end

function expectation(
    op::Operators.OperatorType,
    device::Device,
    basis::Bases.BasisType,
    ψ::AbstractVector,
)
    H = operator(op, device, basis)
    return LinearAlgebraTools.expectation(H, ψ)
end

function braket(
    op::Operators.OperatorType,
    device::Device,
    ψ1::AbstractVector,
    ψ2::AbstractVector,
)
    return braket(op, device, Bases.OCCUPATION, ψ1, ψ2)
end

function braket(op::Operators.OperatorType,
    device::Device,
    basis::Bases.BasisType,
    ψ1::AbstractVector,
    ψ2::AbstractVector,
)
    H = operator(op, device, basis)
    return LinearAlgebraTools.braket(ψ1, H, ψ2)
end

#= TODO (mid): Localize expectation and braket, I suppose. =#














abstract type LocallyDrivenDevice <: Device end

# METHODS NEEDING TO BE IMPLEMENTED
drivequbit(::LocallyDrivenDevice, i::Int)::Int = error("Not Implemented")
gradequbit(::LocallyDrivenDevice, j::Int)::Int = error("Not Implemented")

# LOCALIZING DRIVE OPERATORS

function localdriveoperators(device::LocallyDrivenDevice, t::Real)
    return localdriveoperators(device, Basis.OCCUPATION, t)
end

function localdriveoperators(
    device::LocallyDrivenDevice,
    basis::Bases.LocalBasis,
    t::Real,
)
    ā = Devices.localalgebra(device, basis)

    # SINGLE OPERATOR TO FETCH THE CORRECT TYPING
    F = ndrives(device) > 0 ? eltype(Devices.driveoperator(device, ā, 1, t)) : eltype(ā)

    v̄ = [zeros(F, size(ā[q])) for q in 1:nqubits(device)]
    for i in 1:ndrives(device)
        q = drivequbit(device, i)
        v̄[q] .+= Devices.driveoperator(device, ā, i, t)
    end
    return v̄
end

function localdrivepropagators(device::LocallyDrivenDevice, τ::Real, t::Real)
    return localdrivepropagators(device, Bases.OCCUPATION, τ, t)
end

function localdrivepropagators(
    device::LocallyDrivenDevice,
    basis::Bases.LocalBasis,
    τ::Real,
    t::Real,
)
    v̄ = localdriveoperators(device, basis, t)
    v = v̄[1]        # NOTE: Raises error if device has no drives.
    F = LinearAlgebraTools.cis_type(v)

    ū = Matrix{F}[]
    for v in v̄
        u = convert(Matrix{F}, copy(v))
        u = LinearAlgebraTools.cis!(u, -τ)
        push!(ū, u)
    end
    return ū
end

function Devices.propagator(
    op::Operators.Drive,
    device::LocallyDrivenDevice,
    basis::Bases.LocalBasis,
    τ::Real,
)
    ū = localdrivepropagators(device, basis, τ, op.t)
    return LinearAlgebraTools.kron(ū)
end

function Devices.propagator(
    op::Operators.Channel,
    device::LocallyDrivenDevice,
    basis::Bases.LocalBasis,
    τ::Real,
)
    ā = Devices.localalgebra(device, basis)
    v = Devices.driveoperator(device, ā, op.i, op.t)
    u = convert(Array{LinearAlgebraTools.cis_type(v)}, copy(v))
    u = LinearAlgebraTools.cis!(u, -τ)
    q = drivequbit(device, op.i)
    return globalize(device, u, q)
end

function Devices.propagate!(
    op::Operators.Drive,
    device::LocallyDrivenDevice,
    basis::Bases.LocalBasis,
    τ::Real,
    ψ::Evolvable,
)
    ū = localdrivepropagators(device, basis, τ, op.t)
    return LinearAlgebraTools.rotate!(ū, ψ)
end

function Devices.propagate!(
    op::Operators.Channel,
    device::LocallyDrivenDevice,
    basis::Bases.LocalBasis,
    τ::Real,
    ψ::Evolvable,
)
    ā = Devices.localalgebra(device, basis)
    v = Devices.driveoperator(device, ā, op.i, op.t)
    u = convert(Array{LinearAlgebraTools.cis_type(v)}, copy(v))
    u = LinearAlgebraTools.cis!(u, -τ)
    q = drivequbit(device, op.i)
    ops = [p == q ? u : one(u) for p in 1:nqubits(device)]
    return LinearAlgebraTools.rotate!(ops, ψ)
end

# LOCALIZING GRADIENT OPERATORS

# # TODO (mid): Uncomment when we have localized versions of braket and expectation.
# function Devices.braket(
#     op::Operators.Gradient,
#     device::LocallyDrivenDevice,
#     basis::Bases.LocalBasis,
#     ψ1::AbstractVector,
#     ψ2::AbstractVector,
# )
#     ā = Devices.localalgebra(device, basis)
#     A = Devices.gradeoperator(device, ā, op.j, op.t)
#     q = gradequbit(device, op.j)
#     ops = [p == q ? A : one(A) for p in 1:nqubits(device)]
#     return LinearAlgebraTools.braket(ψ1, ops, ψ2)
# end