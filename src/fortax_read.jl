# Fortax.jl — Pure Julia UK tax-benefit microsimulation
# Reader module: schema-driven JSON system reader + CSV price/index loaders

module FortaxRead

using JSON3
using StaticArrays
using ..FortaxTypes

export read_system, write_system, load_index, load_sysindex

# ─── Helpers ──────────────────────────────────────────────────────────

"""Pad or truncate a vector into an SVector of length N, filling with `fill`."""
@inline function _to_svec(::Type{SVector{N,T}}, v::AbstractVector, fill::T=zero(T)) where {N,T}
    buf = MVector{N,T}(ntuple(_ -> fill, Val(N)))
    n = min(length(v), N)
    for i in 1:n
        buf[i] = T(v[i])
    end
    return SVector(buf)
end

"""Get a scalar value from a JSON dict, trying `key` then `England\$key` alias."""
@inline function _jget(d, key::Symbol, default)
    haskey(d, key) && return convert(typeof(default), d[key])
    # alias for ctax ratios: JSON has EnglandRatioA, struct has RatioA
    alias = Symbol("England" * string(key))
    haskey(d, alias) && return convert(typeof(default), d[alias])
    return default
end

@inline function _jget(d, key::Symbol, ::Type{Int})
    haskey(d, key) && return Int(d[key])
    alias = Symbol("England" * string(key))
    haskey(d, alias) && return Int(d[alias])
    return 0
end

@inline function _jget(d, key::Symbol, ::Type{Float64})
    haskey(d, key) && return Float64(d[key])
    alias = Symbol("England" * string(key))
    haskey(d, alias) && return Float64(d[alias])
    return 0.0
end

# ─── Generic schema-driven component reader ──────────────────────────

"""
    _read_component(::Type{T}, d) -> T

Read a component of type `T` from JSON dict `d`, using the schema
returned by `_schema(T)` to determine field names, types, and dimensions.
"""
function _read_component(::Type{T}, d) where T
    schema = _schema(T)
    vals = Any[]
    for f in schema
        key = f.name
        if f.dim > 0
            # Array field → SVector
            raw = if haskey(d, key)
                collect(f.T, d[key])
            else
                f.T[]
            end
            push!(vals, _to_svec(SVector{f.dim, f.T}, raw))
        else
            # Scalar field
            dflt = f.default !== nothing ? f.T(f.default) : zero(f.T)
            push!(vals, _jget(d, key, dflt))
        end
    end
    return T(vals...)
end

# ─── Read a system JSON file ─────────────────────────────────────────

"""
    read_system(filename::AbstractString; prices::Union{Int,Nothing}=nothing) -> TaxSystem

Read a FORTAX system JSON file and return a `TaxSystem`.
Each component is read generically using its schema.
Extra/unknown fields in the JSON are silently ignored.
"""
function read_system(filename::AbstractString; prices::Union{Int,Nothing}=nothing)
    json = JSON3.read(read(filename, String))

    sysname = get(json, :sysname, "")
    sysdesc = get(json, :sysdesc, "")

    # Read each component using the schema
    components = map(SYS_COMPONENTS) do comp
        d = get(json, comp.field, nothing)
        d !== nothing ? _read_component(comp.T, d) : comp.T()
    end

    sys = TaxSystem(sysname, sysdesc, components...)

    # Override prices if specified
    if prices !== nothing
        sys = setfields(sys; extra = setfields(sys.extra; prices = prices))
    end

    return sys
end

# ─── Load price index CSV ────────────────────────────────────────────

"""
    load_index(fname::AbstractString) -> RPIndex

Load a price index from a CSV file. Format: first line = number of records,
then lines of `YYYYMMDD,value`.
"""
function load_index(fname::AbstractString)
    lines = readlines(fname)
    isempty(lines) && error("Empty price index file: $fname")

    ndate = parse(Int, strip(replace(lines[1], "," => "")))

    dates = Int[]
    indices = Float64[]

    for i in 2:length(lines)
        line = strip(lines[i])
        isempty(line) && continue
        parts = split(line, ',')
        length(parts) >= 2 || continue
        push!(dates, parse(Int, strip(parts[1])))
        push!(indices, parse(Float64, strip(parts[2])))
    end

    if length(dates) != ndate
        @warn "Number of RPI records ($(length(dates))) does not equal declared count ($ndate)"
    end

    return RPIndex(length(dates), dates, indices)
end

"""Load the default price index from `res/prices/rpi.csv`."""
function load_index()
    default_path = joinpath(@__DIR__, "..", "res", "prices", "rpi.csv")
    return load_index(default_path)
end

# ─── Load system index ───────────────────────────────────────────────

"""
    load_sysindex(fname::AbstractString) -> SysIndex

Load a system index from a CSV file. Format: lines of `date0,date1,filename`.
"""
function load_sysindex(fname::AbstractString)
    lines = readlines(fname)
    date0 = Int[]
    date1 = Int[]
    fnames = String[]

    for line in lines
        line = strip(line)
        isempty(line) && continue
        startswith(line, '#') && continue
        parts = split(line, ',')
        length(parts) >= 3 || continue
        push!(date0, parse(Int, strip(parts[1])))
        push!(date1, parse(Int, strip(parts[2])))
        push!(fnames, strip(parts[3]))
    end

    return SysIndex(length(date0), date0, date1, fnames)
end

"""Load the default system index."""
function load_sysindex()
    default_path = joinpath(@__DIR__, "..", "res", "systems", "sysindex.csv")
    return load_sysindex(default_path)
end

# ─── Write system to JSON ─────────────────────────────────────────────

"""
    _write_component(comp, schema) -> Dict{Symbol,Any}

Convert a system component struct to a Dict suitable for JSON
serialisation.  Arrays are truncated to their active length via `dimvar`.
"""
function _write_component(comp, schema::Tuple)
    d = Dict{Symbol,Any}()
    for f in schema
        val = getfield(comp, f.name)
        if f.dim > 0
            nval = f.dimvar === :_ ? f.dim : getfield(comp, f.dimvar)
            d[f.name] = collect(val[1:nval])
        else
            d[f.name] = val
        end
    end
    return d
end

"""
    write_system(sys::TaxSystem, fname::AbstractString)

Write a `TaxSystem` to a JSON file, producing output compatible with
`read_system`. Arrays are truncated to their active length (e.g. only
`numbands` elements of `bands` are written). This is the inverse of
`read_system`.
"""
function write_system(sys::TaxSystem, fname::AbstractString)
    root = Dict{Symbol,Any}()
    root[:sysname] = sys.sysname
    root[:sysdesc] = sys.sysdesc

    for comp in SYS_COMPONENTS
        schema = _schema(comp.T)
        root[comp.field] = _write_component(getfield(sys, comp.field), schema)
    end

    open(fname, "w") do io
        JSON3.pretty(io, root)
    end

    nothing
end

end # module FortaxRead
