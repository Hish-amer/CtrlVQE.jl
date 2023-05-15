using Memoization: @memoize
import LinearAlgebra: I, mul!
using ...LinearAlgebraTools: MatrixList
import ...Parameters, ...LinearAlgebraTools, ...Signals, ...Devices

import ...TempArrays: array
const LABEL = Symbol(@__MODULE__)

@memoize Dict function bosonic_annihilator(::Type{F}, m::Int) where {F<:AbstractFloat}
    a = zeros(F, m, m)
    for i ∈ 1:m-1
        a[i,i+1] = √i
    end
    return a
end



abstract type AbstractTransmonDevice{F,FΩ} <: Devices.LocallyDrivenDevice end

# THE INTERFACE TO IMPLEMENT

# Devices.nlevels
# Devices.nqubits
resonancefrequency(::AbstractTransmonDevice, q::Int)::Real = error("Not Implemented")
anharmonicity(::AbstractTransmonDevice, q::Int)::Real = error("Not Implemented")

ncouplings(::AbstractTransmonDevice)::Int = error("Not Implemented")
couplingpair(::AbstractTransmonDevice, k::Int)::Devices.Quple = error("Not Implemented")
couplingstrength(::AbstractTransmonDevice, k::Int)::Real = error("Not Implemented")

# Devices.ndrives
# Devices.drivequbit
drivefrequency(::AbstractTransmonDevice, i::Int)::Real = error("Not Implemented")
drivesignal(::AbstractTransmonDevice, i::Int)::AbstractSignal = error("Not Implemented")

bindfrequencies(::AbstractTransmonDevice, ν̄::AbstractVector) = error("Not Implemented")


# THE INTERFACE ALREADY IMPLEMENTED

function Devices.ngrades(device::AbstractTransmonDevice)
    return 2 * Devices.ndrives(device)
end

function Devices.gradequbit(device::AbstractTransmonDevice, j::Int)
    return Devices.drivequbit(device, ((j-1) >> 1) + 1)
end

Devices.eltype_localloweringoperator(::AbstractTransmonDevice{F,FΩ}) where {F,FΩ} = F
function Devices.localloweringoperator(
    device::AbstractTransmonDevice{F,FΩ},
    q::Int,
) where {F,FΩ}
    return bosonic_annihilator(F, Devices.nlevels(device))
end

Devices.eltype_qubithamiltonian(::AbstractTransmonDevice{F,FΩ}) where {F,FΩ} = F
function Devices.qubithamiltonian(
    device::AbstractTransmonDevice,
    ā::MatrixList,
    q::Int;
    result=nothing,
)
    a = @view(ā[:,:,q])
    Im = Matrix(I, size(a))     # UNAVOIDABLE ALLOCATION?

    result === nothing && (result = Matrix{eltype(a)}(undef, size(a)))
    result .= 0
    result .-= (anharmonicity(device,q)/2)  .* Im       #       - δ/2    I
    result = LinearAlgebraTools.rotate!(a', result)     #       - δ/2   a'a
    result .+= resonancefrequency(device,q) .* Im       # ω     - δ/2   a'a
    result = LinearAlgebraTools.rotate!(a', result)     # ω a'a - δ/2 a'a'aa
    return result
end

Devices.eltype_staticcoupling(::AbstractTransmonDevice{F,FΩ}) where {F,FΩ} = F
function Devices.staticcoupling(
    device::AbstractTransmonDevice,
    ā::MatrixList{F};
    result=nothing,
) where {F}
    d = size(ā,1)
    result === nothing && (result = Matrix{F}(undef, d, d))
    aTa = array(F, size(result), LABEL)

    result .= 0
    for pq in 1:ncouplings(device)
        g = couplingstrength(device, pq)
        p, q = couplingpair(device, pq)

        aTa = mul!(aTa, (@view(ā[:,:,p]))', @view(ā[:,:,q]))
        result .+= g .* aTa
        result .+= g .* aTa'
    end
    return result
end

Devices.eltype_driveoperator(::AbstractTransmonDevice{F,FΩ}) where {F,FΩ} = Complex{F}
function Devices.driveoperator(
    device::AbstractTransmonDevice,
    ā::MatrixList,
    i::Int,
    t::Real;
    result=nothing,
)
    a = @view(ā[:,:,Devices.drivequbit(device, i)])
    e = exp(im * drivefrequency(device, i) * t)
    Ω = drivesignal(device, i)(t)

    if result === nothing
        F = promote_type(eltype(a), eltype(e))  # Ω is no more complex than e.
        result = Matrix{F}(undef, size(a))
    end
    result .= 0

    result .+= (real(Ω) * e ) .* a
    result .+= (real(Ω) * e') .* a'

    if Ω isa Complex
        result .+= (imag(Ω) * im *e ) .* a
        result .+= (imag(Ω) * im'*e') .* a'
    end

    return result
end

Devices.eltype_gradeoperator(::AbstractTransmonDevice{F,FΩ}) where {F,FΩ} = Complex{F}
function Devices.gradeoperator(
    device::AbstractTransmonDevice,
    ā::MatrixList,
    j::Int,
    t::Real;
    result=nothing,
)
    i = ((j-1) >> 1) + 1
    a = @view(ā[:,:,Devices.drivequbit(device, i)])
    e = exp(im * drivefrequency(device, i) * t)

    if result === nothing
        F = promote_type(eltype(a), eltype(e))
        result = Matrix{F}(undef, size(a))
    end
    result .= 0

    phase = Bool(j & 1) ? 1 : im    # Odd j -> "real" gradient operator; even j  -> "imag"
    result .+= (phase * e ) .* a
    result .+= (phase'* e') .* a'
    return result
end

function Devices.gradient(
    device::AbstractTransmonDevice{F,FΩ},
    τ̄::AbstractVector,
    t̄::AbstractVector,
    ϕ̄::AbstractMatrix;
    result=nothing,
) where {F,FΩ}
    L = Parameters.count(device)
    nD = Devices.ndrives(device)
    isnothing(result) && return Devices.gradient(
        device, τ̄, t̄, ϕ̄;
        result=Vector{F}(undef, L),
    )

    gradient_for_signals!(@view(result[1:L-nD]), device, τ̄, t̄, ϕ̄)
    gradient_for_frequencies!(@view(result[1+L-nD:L]), device, τ̄, t̄, ϕ̄)

    return result
end

function gradient_for_signals!(
    result::AbstractVector{F},
    device::AbstractTransmonDevice{F,FΩ},
    τ̄::AbstractVector,
    t̄::AbstractVector,
    ϕ̄::AbstractMatrix,
) where {F,FΩ}
    # CALCULATE GRADIENT FOR SIGNAL PARAMETERS
    modulation = array(FΩ, size(t̄), LABEL)

    offset = 0
    for i in 1:Devices.ndrives(device)
        Ω = drivesignal(device, i)
        j = 2i - 1

        L = Parameters.count(Ω)

        modulation .= ϕ̄[:,j]
        (FΩ <: Complex) && (modulation .-= im .* ϕ̄[:,j+1])
        #= NOTE: This is bit obfuscated.
        The integrate_partial function below yields the real part of ∂⋅modulation.
        We want ∂⋅ϕα + ∂⋅ϕβ, for complex signals.
        So we set modulation = ϕα - 𝑖 ϕβ.
        =#

        Signals.integrate_partials(
            Ω, τ̄, t̄, modulation;
            result=@view(result[1+offset:L+offset]),
        )
        offset += L
    end

    return result
end

function gradient_for_frequencies!(
    result::AbstractVector{F},
    device::AbstractTransmonDevice{F,FΩ},
    τ̄::AbstractVector,
    t̄::AbstractVector,
    ϕ̄::AbstractMatrix,
) where {F,FΩ}
    # TEMPORARY VARIABLES NEEDED IN GRADIENT INTEGRALS
    modulation = array(FΩ, size(t̄), LABEL)

    # CALCULATE GRADIENT FOR FREQUENCY PARAMETERS
    for i in 1:Devices.ndrives(device)
        Ω = drivesignal(device, i)
        j = 2i - 1

        modulation .= t̄ .* ϕ̄[:,j+1]
        (FΩ <: Complex) && (modulation .+= im .* t̄ .* ϕ̄[:,j])
        result[i] = Signals.integrate_signal(Ω, τ̄, t̄, modulation)
    end

    return result
end

function Parameters.count(device::AbstractTransmonDevice)
    cnt = Devices.ndrives(device)           # NOTE: There are `ndrives` frequencies.
    for i in 1:Devices.ndrives(device)
        cnt += Parameters.count(drivesignal(device, i))
    end
    return cnt
end

function Parameters.names(device::AbstractTransmonDevice)
    names = []

    # STRING TOGETHER PARAMETER NAMES FOR EACH SIGNAL Ω̄[i]
    annotate(name,i) = "Ω$i(q$(device.q̄[i])):$name"
    for i in 1:Devices.ndrives(device)
        Ω = drivesignal(device, i)
        append!(names, (annotate(name,i) for name in Parameters.names(Ω)))
    end

    # TACK ON PARAMETER NAMES FOR EACH ν̄[i]
    append!(names, ("ν$i" for i in 1:Devices.ndrives(device)))
    return names
end

function Parameters.values(device::AbstractTransmonDevice{F,FΩ}) where {F,FΩ}
    values = F[]

    # STRING TOGETHER PARAMETERS FOR EACH SIGNAL Ω̄[i]
    for i in 1:Devices.ndrives(device)
        Ω = drivesignal(device, i)
        append!(values, Parameters.values(Ω))
    end

    # TACK ON PARAMETERS FOR EACH ν̄[i]
    append!(values, (drivefrequency(device, i) for i in 1:Devices.ndrives(device)))
    return values
end

function Parameters.bind(device::AbstractTransmonDevice, x̄::AbstractVector{F}) where {F}
    offset = 0

    # BIND PARAMETERS FOR EACH SIGNAL Ω̄[i]
    for i in 1:Devices.ndrives(device)
        Ω = drivesignal(device, i)
        L = Parameters.count(Ω)
        Parameters.bind(Ω, x̄[offset+1:offset+L])
        offset += L
    end

    # BIND PARAMETERS FOR EACH ν̄[i]
    bindfrequencies(device, x̄[offset+1:end])
end







struct TransmonDevice{F,FΩ} <: AbstractTransmonDevice{F,FΩ}
    # QUBIT LISTS
    ω̄::Vector{F}
    δ̄::Vector{F}
    # COUPLING LISTS
    ḡ::Vector{F}
    quples::Vector{Devices.Quple}
    # DRIVE LISTS
    q̄::Vector{Int}
    ν̄::Vector{F}
    Ω̄::Vector{Signals.AbstractSignal{F,FΩ}}
    # OTHER PARAMETERS
    m::Int

    function TransmonDevice(
        ω̄::AbstractVector{<:Real},
        δ̄::AbstractVector{<:Real},
        ḡ::AbstractVector{<:Real},
        quples::AbstractVector{Devices.Quple},
        q̄::AbstractVector{Int},
        ν̄::AbstractVector{<:AbstractFloat},
        Ω̄::AbstractVector{<:Signals.AbstractSignal{F,FΩ}},
        m::Int,
    ) where {F,FΩ}
        # VALIDATE PARALLEL LISTS ARE CONSISTENT SIZE
        @assert length(ω̄) == length(δ̄) ≥ 1              # NUMBER OF QUBITS
        @assert length(ḡ) == length(quples)             # NUMBER OF COUPLINGS
        @assert length(q̄) == length(ν̄) == length(Ω̄)     # NUMBER OF DRIVES

        # VALIDATE QUBIT INDICES
        for (p,q) in quples
            @assert 1 <= p <= length(ω̄)
            @assert 1 <= q <= length(ω̄)
        end
        for q in q̄
            @assert 1 <= q <= length(ω̄)
        end

        # VALIDATE THAT THE HILBERT SPACE HAS SOME VOLUME...
        @assert m ≥ 2

        # STANDARDIZE TYPING
        return new{F,FΩ}(
            convert(Vector{F}, ω̄),
            convert(Vector{F}, δ̄),
            convert(Vector{F}, ḡ),
            quples,
            q̄,
            convert(Vector{F}, ν̄),
            [Ω for Ω in Ω̄],
            m,
        )
    end
end

Devices.nlevels(device::TransmonDevice) = device.m

Devices.nqubits(device::TransmonDevice) = length(device.ω̄)
resonancefrequency(device::TransmonDevice, q::Int) = device.ω̄[q]
anharmonicity(device::TransmonDevice, q::Int) = device.δ̄[q]

ncouplings(device::TransmonDevice) = length(device.quples)
couplingpair(device::TransmonDevice, k::Int) = device.quples[k]
couplingstrength(device::TransmonDevice, k::Int) = device.ḡ[k]

Devices.ndrives(device::TransmonDevice) = length(device.q̄)
Devices.drivequbit(device::TransmonDevice, i::Int) = device.q̄[i]
drivefrequency(device::TransmonDevice, i::Int) = device.ν̄[i]
drivesignal(device::TransmonDevice, i::Int) = device.Ω̄[i]

bindfrequencies(device::TransmonDevice, ν̄::AbstractVector) = (device.ν̄ .= ν̄)


#= TODO (low): Other types

LegacyTransmonDevice: assume Ω(t) is real, no analytical gradient for ν, half as many grade operators.
FixedFrequencyTransmonDevice: ν is tuple and not included in parameters.
LinearTransmonDevice: quples and ḡ replaced by n-length tuple ḡ, efficient static propagate.
TransmonDeviceSansRWA: implicitly one channel per qubit, different drive
a mix of the three I guess...

=#